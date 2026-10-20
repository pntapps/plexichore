using System.Diagnostics;
using System.Drawing;
using Microsoft.Extensions.Logging;
using PlexiChore.Engine.Capture;
using PlexiChore.Engine.Codecs;
using PlexiChore.Engine.Native;

namespace PlexiChore.Engine.Streaming;

internal sealed record PipelineConfig(
    string DeviceName,
    int BoxWidth, int BoxHeight,   // encoded frame must fit inside this box (aspect preserved, never upscaled)
    int Fps,
    int BitrateKbps,
    string Quality,
    string Codec,                  // "h264" | "mjpeg"
    bool AllowHardware,
    bool AllowH264,
    TimeSpan WaitForOutput,
    bool ArrowWhenHidden = false,
    uint H264Profile = 100,        // eAVEncH264VProfile: 100 High, 77 Main, 66 Baseline (from the tablet's decoder caps)
    int InitialLevel = 0,          // adaptive encode-size level to start at (same session only), 0 = full size
    int TabletRefreshHz = 60);     // tablet panel refresh (HELLO refreshHz): steady fallback cadences divide it

/// Fps = frame cadence the pipeline emits now (lower than the configured fps in the steady fallback); NewStream = a new
/// encoder instance (codec-config + IDR follow), false for a cadence-only change.
internal sealed record PipelineInfo(int Width, int Height, string Codec, string EncoderName, bool IsHardware, Rectangle DesktopBounds, string DeviceName,
    int Fps = 0, bool NewStream = true);

/// Capture -> cursor composite -> GPU scale/convert -> encode, on one dedicated thread.
///
/// The converter + encoder form a "stage" that can be replaced while the pipeline runs (encode-size change, fresh
/// encoder instance): the new stage is built on a worker thread against the same D3D device, duplication and cursor
/// shaders, the old one keeps encoding meanwhile, and the switch happens between two frames (new CONFIG, then
/// codec-config + IDR from the new encoder). The tablet sees one IDR instead of a ~2 s rebuild.
internal sealed class StreamPipeline : IDisposable
{
    private static readonly long KeepAliveTicks = Stopwatch.Frequency / 2;            // >= 1 frame / 500 ms
    // Over TCP nothing is lost silently (backpressure drops request an IDR explicitly), so periodic IDRs only cost
    // bandwidth bursts (a 2560x1600 IDR is 5-10x a P-frame and stalls adb tunnels); keep a slow safety net.
    private static readonly long PeriodicIdrTicks = Stopwatch.Frequency * 30;

    /// Encode-size ladder relative to the target box: 2560x1600 -> 1920x1200 -> 1600x1000.
    private static readonly double[] Ladder = { 1.0, 0.75, 0.625 };

    private static readonly bool NoAdapt = Environment.GetEnvironmentVariable("PLEXI_NOADAPT") != null;
    private static readonly bool ForceSteady = Environment.GetEnvironmentVariable("PLEXI_FORCE_STEADY") != null;

    private readonly PipelineConfig _cfg;
    private readonly ILogger _log;
    private readonly EncodedOutput _onEncoded;
    private readonly TaskCompletionSource<PipelineInfo> _ready = new(TaskCreationOptions.RunContinuationsAsynchronously);
    private readonly Thread _thread;
    private volatile bool _stop;
    private volatile bool _keyframeRequested = true;
    private volatile string? _asyncEncoderError;

    private sealed class Stage(VideoConverter conv, IVideoEncoder enc, int level, int gen) : IDisposable
    {
        public readonly VideoConverter Conv = conv;
        public readonly IVideoEncoder Enc = enc;
        public readonly int Level = level, Gen = gen;
        public void Dispose()
        {
            try { Enc.Dispose(); } catch { }
            try { Conv.Dispose(); } catch { }
        }
    }

    private readonly object _emitLock = new();
    private int _gen;                   // generation whose encoder output is forwarded (under _emitLock)
    private Stage? _stage;
    private Task<Stage>? _building;
    private string _buildWhy = "";
    private readonly List<Task> _retiring = new();

    // stats (read by session ~1/s)
    private long _framesEncoded;
    private long _encodeTicksTotal;
    private long _lastIdrTick;
    private long _dbgCompose, _dbgConvert, _dbgEncode, _dbgN, _dbgPtr, _dbgLast, _dbgMaxGap, _dbgDesk;
    private long _encLatencyUs;
    private int _goodWindows, _windows, _limitedRun, _calmRun, _sinceSwitch, _lowRun, _steadyWindows;
    private long _dbgShort;
    /// Steady fallback cadence (0 = off: frames go out at the configured fps as content changes).
    private volatile int _steadyFps;

    private int CurrentFps => _steadyFps > 0 ? _steadyFps : Math.Max(1, _cfg.Fps);

    /// Even cadence the tablet panel shows without judder (every frame on screen for the same number of vsyncs):
    /// refresh / k for the smallest k the sustained rate can hold, e.g. 120 Hz -> 40 fps, 60 Hz -> 30 fps.
    private int SteadyFpsFor(double sustained)
    {
        int hz = _cfg.TabletRefreshHz >= 30 ? _cfg.TabletRefreshHz : 60;
        for (int k = 2; k <= 6; k++)
            if (hz / (double)k <= sustained * 0.95 && hz / k < _cfg.Fps) return hz / k;
        return 0;
    }

    /// Consecutive slow encoder instances per encode size. The NVIDIA MFT (seen on a GT 710) randomly starts some
    /// instances in a serialized mode (one frame in flight, ~2x per-frame time); a fresh instance is usually fine, so
    /// up to 3 fresh instances are tried. Reset once an instance runs well.
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<(int, int, int), int> SlowInstances = new();

    private static bool RetryEncoder(int w, int h, int fps) => SlowInstances.AddOrUpdate((w, h, fps), 1, (_, v) => v + 1) <= 3;
    private static void EncoderHealthy(int w, int h, int fps) => SlowInstances.TryRemove((w, h, fps), out _);

    /// Average hardware-encoder latency (input -> bitstream) of the last stats window, 0 when unknown.
    public double EncoderLatencyMs => Interlocked.Read(ref _encLatencyUs) / 1000.0;

    /// Current adaptive encode-size level (0 = full size); the session hands it to a rebuilt pipeline.
    public int Level => _stage?.Level ?? _cfg.InitialLevel;

    public PipelineConfig Config => _cfg;
    public Task<PipelineInfo> Ready => _ready.Task;
    /// Raised (on the pipeline thread) when the pipeline ended by itself: "resize", "error:<msg>", "encoder:<msg>".
    public event Action<string>? Ended;
    /// Raised on the pipeline thread right after the encode size changed seamlessly (before the new encoder's first
    /// output): the session must send a new CONFIG and restart its video queue at the next IDR.
    public event Action<PipelineInfo>? Resized;
    public Rectangle CurrentBounds { get; private set; }

    public StreamPipeline(PipelineConfig cfg, ILogger log, EncodedOutput onEncoded)
    {
        _cfg = cfg; _log = log; _onEncoded = onEncoded;
        _thread = new Thread(Run) { IsBackground = true, Name = "PlexiChore capture/encode", Priority = ThreadPriority.AboveNormal };
    }

    public void Start() => _thread.Start();

    public void RequestKeyframe() => _keyframeRequested = true;

    public (long frames, long encodeTicks) TakeStats()
    {
        return (Interlocked.Exchange(ref _framesEncoded, 0), Interlocked.Exchange(ref _encodeTicksTotal, 0));
    }

    public static (int w, int h) FitSize(int srcW, int srcH, int boxW, int boxH)
    {
        double s = Math.Min(1.0, Math.Min((double)boxW / srcW, (double)boxH / srcH));
        int w = Math.Max(2, (int)Math.Floor(srcW * s) & ~1);
        int h = Math.Max(2, (int)Math.Floor(srcH * s) & ~1);
        return (w, h);
    }

    /// Encode size for a ladder level on a capture of srcW x srcH.
    private (int w, int h) SizeFor(int srcW, int srcH, int level)
    {
        var (w, h) = FitSize(srcW, srcH, _cfg.BoxWidth, _cfg.BoxHeight);
        double s = Ladder[Math.Clamp(level, 0, Ladder.Length - 1)];
        if (s < 1.0) (w, h) = FitSize(srcW, srcH, (int)(w * s), (int)(h * s));
        if (int.TryParse(Environment.GetEnvironmentVariable("PLEXI_MAXW"), out var maxW) && w > maxW) (w, h) = FitSize(srcW, srcH, maxW, maxW);
        return (w, h);
    }

    private void Emit(int gen, long pts, byte flags, ReadOnlySpan<byte> data)
    {
        lock (_emitLock)
        {
            if (gen != _gen) return; // output of a retired encoder
            if ((flags & Protocol.VideoFlags.Keyframe) != 0) Interlocked.Exchange(ref _lastIdrTick, Stopwatch.GetTimestamp());
            if ((flags & Protocol.VideoFlags.CodecConfig) == 0) Interlocked.Increment(ref _framesEncoded);
            _onEncoded(pts, flags, data);
        }
    }

    private Stage CreateStage(DesktopCapture cap, int level, int gen)
    {
        var (w, h) = SizeFor(cap.Width, cap.Height, level);
        IVideoEncoder? enc = null;
        void Out(long pts, byte flags, ReadOnlySpan<byte> data) => Emit(gen, pts, flags, data);
        if (_cfg.Codec == "h264" && _cfg.AllowH264)
        {
            var h264 = MfH264Encoder.TryCreate(_log, cap.Device, cap.Context, w, h, _cfg.Fps, _cfg.BitrateKbps, _cfg.Quality,
                _cfg.AllowHardware, allowSoftware: true, Out, _cfg.H264Profile);
            if (h264 != null) h264.Error += m => { if (Volatile.Read(ref _gen) == gen) _asyncEncoderError = m; };
            enc = h264;
            if (enc == null) _log.LogWarning("No usable H.264 encoder; falling back to MJPEG");
        }
        enc ??= new MjpegEncoder(cap.Device, cap.Context, w, h, _cfg.Quality, Out);
        try
        {
            var conv = new VideoConverter(cap.Device, cap.Context, cap.Width, cap.Height, w, h, enc.InputFormat, enc.InputRingSize, _cfg.Fps);
            return new Stage(conv, enc, level, gen);
        }
        catch { enc.Dispose(); throw; }
    }

    private PipelineInfo InfoFor(DesktopCapture cap, Stage s) =>
        new(s.Conv.OutWidth, s.Conv.OutHeight, s.Enc.Codec, s.Enc.Name, s.Enc.IsHardware, cap.DesktopBounds, cap.DeviceName, CurrentFps);

    /// Cadence-only change (steady fallback on/off): same encoder and stream, the tablet re-times its frame pacer.
    private void SetCadence(DesktopCapture cap, int steadyFps, string why)
    {
        _steadyFps = steadyFps;
        _steadyWindows = 0; _lowRun = 0; _sinceSwitch = 0;
        var info = InfoFor(cap, _stage!) with { NewStream = false };
        lock (_emitLock) { try { Resized?.Invoke(info); } catch (Exception ex) { _log.LogDebug("Resized handler: {Msg}", ex.Message); } }
        _log.LogInformation("Frame cadence now {Fps} fps ({Why})", CurrentFps, why);
    }

    /// Builds a new stage in the background; the loop switches to it once ready.
    private void StartBuild(DesktopCapture cap, int level, string why)
    {
        if (_building != null || _stop) return;
        int gen = Interlocked.Increment(ref _nextGen); // unique per build: outputs of other generations are dropped
        _buildWhy = why;
        _building = Task.Run(() => CreateStage(cap, level, gen));
    }
    private int _nextGen = 1;

    private void TrySwitch(DesktopCapture cap)
    {
        var b = _building;
        if (b == null || !b.IsCompleted) return;
        _building = null;
        if (!b.IsCompletedSuccessfully)
        {
            _log.LogWarning("Could not build the new encoder ({Why}): {Msg}; keeping the current one", _buildWhy, b.Exception?.GetBaseException().Message);
            _sinceSwitch = 0;
            return;
        }
        var next = b.Result;
        if (_stop) { next.Dispose(); return; }
        var old = _stage;
        var sw = Stopwatch.StartNew();
        var info = InfoFor(cap, next);
        lock (_emitLock)
        {
            _gen = next.Gen;
            _stage = next;
            _asyncEncoderError = null;
            try { Resized?.Invoke(info); } catch (Exception ex) { _log.LogDebug("Resized handler: {Msg}", ex.Message); }
        }
        _keyframeRequested = true;
        _sinceSwitch = 0; _limitedRun = 0; _calmRun = 0; _goodWindows = 0;
        if (old != null) _retiring.Add(Task.Run(old.Dispose));
        _retiring.RemoveAll(t => t.IsCompleted);
        _log.LogInformation("Encode size now {W}x{H} ({Why}); switched in {Ms} ms without restarting capture",
            info.Width, info.Height, _buildWhy, sw.ElapsedMilliseconds);
    }

    private void Run()
    {
        NativeMethods.SetThreadDpiAwarenessContext(NativeMethods.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        NativeMethods.timeBeginPeriod(1);
        DesktopCapture? cap = null;
        string endReason = "stopped";
        try
        {
            var initSw = Stopwatch.StartNew();
            cap = DesktopCapture.Create(_cfg.DeviceName, _log, _cfg.WaitForOutput);
            CurrentBounds = cap.DesktopBounds;
            cap.DrawArrowWhenHidden = _cfg.ArrowWhenHidden;
            _log.LogDebug("pipeline: capture ready after {Ms} ms", initSw.ElapsedMilliseconds);
            int gen = Interlocked.Increment(ref _nextGen);
            lock (_emitLock) _gen = gen;
            _stage = CreateStage(cap, Math.Clamp(_cfg.InitialLevel, 0, Ladder.Length - 1), gen);
            _log.LogDebug("pipeline: encoder ready after {Ms} ms", initSw.ElapsedMilliseconds);
            _ready.TrySetResult(InfoFor(cap, _stage));
            endReason = Loop(cap);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Pipeline failed");
            endReason = (_stage == null ? "init:" : "error:") + ex.Message;
            _ready.TrySetException(ex);
        }
        finally
        {
            lock (_emitLock) _gen = -1;
            try { _stage?.Dispose(); } catch (Exception ex) { _log.LogDebug("encoder dispose: {Msg}", ex.Message); }
            try { _building?.Wait(5000); if (_building?.IsCompletedSuccessfully == true) _building.Result.Dispose(); } catch { }
            try { Task.WaitAll(_retiring.ToArray(), 5000); } catch { }
            cap?.Dispose(); // returns the D3D device to the pool once every user of it is gone
            NativeMethods.timeEndPeriod(1);
        }
        if (!_stop) Ended?.Invoke(endReason);
    }

    private string Loop(DesktopCapture cap)
    {
        long freq = Stopwatch.Frequency;
        long interval = freq / Math.Max(1, _cfg.Fps);
        long start = Stopwatch.GetTimestamp();
        long lastEncode = start - interval;
        _lastIdrTick = start;
        bool dirty = true;
        // The NVIDIA MFT releases frame N only when frame N+1 is submitted (or ~100-500 ms later). So after the last
        // real change we submit ONE repeat frame at the next slot: the final cursor position / content then reaches the
        // tablet one frame later instead of at the next keep-alive (cursor "catching up" after it stops).
        bool pushPending = false;
        using var gpuTimer = GpuTimer.Enabled ? new GpuTimer(cap.Device, cap.Context) : null;
        // the repeat goes out 2 frame slots after the frame it releases: content updating at ~60 Hz (video, scrolling)
        // delivers its next real frame before that, so repeats never steal encoder time from real frames
        long pushGap = interval * 2;

        while (!_stop)
        {
            if (_asyncEncoderError != null) return "encoder:" + _asyncEncoderError;
            TrySwitch(cap);
            interval = freq / CurrentFps;
            pushGap = interval * 2;
            bool steady = _steadyFps > 0;
            var stage = _stage!;
            var conv = stage.Conv;
            var enc = stage.Enc;
            long now = Stopwatch.GetTimestamp();
            long since = now - lastEncode;
            long waitTicks = (dirty || _keyframeRequested) ? interval - since
                : pushPending ? pushGap - since
                : Math.Min(KeepAliveTicks - since, freq / 10);
            int timeoutMs = (int)Math.Max(0, waitTicks * 1000 / freq);
            if (_building != null) timeoutMs = Math.Min(timeoutMs, 5); // pick the new stage up promptly

            var r = cap.Acquire(timeoutMs);
            if (cap.SizeChanged) return "resize";
            if (r is AcquireResult.NewFrame or AcquireResult.PointerOnly) dirty = true;
            if (r == AcquireResult.NewFrame) _dbgDesk++;
            CurrentBounds = cap.DesktopBounds;
            if (!cap.HasFrame) continue;

            now = Stopwatch.GetTimestamp();
            since = now - lastEncode;
            // steady fallback: frames leave on a fixed clock (tolerance 0.6 ms instead of 10 %)
            bool due = ((dirty || _keyframeRequested) && since >= interval - (steady ? interval / 40 : interval / 10))
                       || (pushPending && !dirty && since >= pushGap - pushGap / 10);
            bool keepAlive = since >= KeepAliveTicks;
            if (!due && !keepAlive) continue;

            bool wasPush = pushPending && !dirty && !_keyframeRequested;
            if (enc is MfH264Encoder tagged) tagged.NextFrameTag = dirty || _keyframeRequested ? (char)82 : wasPush ? (char)80 : (char)75;
            bool forceIdr = _keyframeRequested || now - Interlocked.Read(ref _lastIdrTick) >= PeriodicIdrTicks;
            _keyframeRequested = false;
            if (forceIdr) Interlocked.Exchange(ref _lastIdrTick, now); // avoid re-forcing every frame until it arrives

            long t0 = Stopwatch.GetTimestamp();
            bool gpuTiming = gpuTimer?.Begin() == true;
            var composed = cap.Compose();
            if (composed == null) continue;
            long t1 = Stopwatch.GetTimestamp();
            var converted = conv.Convert(composed);
            if (gpuTiming) gpuTimer!.End();
            long t2 = Stopwatch.GetTimestamp();
            enc.Encode(converted, (now - start) * 10_000_000 / freq, forceIdr);
            long t3 = Stopwatch.GetTimestamp();
            if (t3 - t2 > freq / 4)
            {
                // a single submit blocking > 250 ms: the GPU / driver stalled (seen under heavy memory pressure while
                // Windows re-laid out the desktop for primary mode). Say so, and resync the tablet with an IDR.
                var mem = NativeMethods.MemoryLoad();
                _log.LogWarning("Encoder submit blocked {Ms} ms (memory load {Load}%, {Avail} MB free)", (t3 - t2) * 1000 / freq, mem.load, mem.availMb);
                _keyframeRequested = true;
            }
            Interlocked.Add(ref _encodeTicksTotal, t3 - t0);
            _dbgCompose += t1 - t0; _dbgConvert += t2 - t1; _dbgEncode += t3 - t2; _dbgN++;
            if (now - lastEncode > _dbgMaxGap && now - lastEncode < freq / 4) _dbgMaxGap = now - lastEncode;
            if (now - lastEncode < freq / Math.Max(1, _cfg.Fps) * 5 / 4) _dbgShort++; // the source asks for the full rate
            if (r == AcquireResult.PointerOnly) _dbgPtr++;
            if (t3 - _dbgLast > freq)
            {
                StatsWindow(cap, stage, gpuTimer, (t3 - _dbgLast) / (double)freq);
                _dbgLast = t3; _dbgCompose = _dbgConvert = _dbgEncode = 0; _dbgN = 0; _dbgPtr = 0; _dbgMaxGap = 0; _dbgDesk = 0; _dbgShort = 0;
            }

            // a real change was just encoded -> one repeat if nothing new follows. (Never ~3 ms after: pushing that early
            // isolated frame often tipped the NVIDIA MFT into its slow serialized mode.)
            // steady: the next slot is exactly one interval after this one (no drift from late acquires)
            lastEncode = steady && now - lastEncode < interval * 2 ? lastEncode + interval : now;
            pushPending = (dirty || forceIdr) && !wasPush && enc.IsHardware;
            dirty = false;
        }
        return "stopped";
    }

    /// Once per second: perf log line + adaptive encode-size decisions.
    private void StatsWindow(DesktopCapture cap, Stage stage, GpuTimer? gpuTimer, double seconds)
    {
        double f = 1000.0 / Stopwatch.Frequency, n = Math.Max(1, _dbgN);
        double fpsNow = _dbgN / seconds;
        var hw = stage.Enc as MfH264Encoder;
        var es = hw?.TakeEncoderStats();
        var conv = stage.Conv;
        _log.LogDebug("perf: {Fps:F1} fps (desk {Desk}, ptrOnly {Ptr}, max gap {Gap:F1} ms) compose {C:F2} convert {V:F2} submit {E:F2} ms | encoder wait {W:F2} latency {L:F2} max {M:F2} busy {B} qvs {Q} real {R} | {OW}x{OH}",
            fpsNow, _dbgDesk, _dbgPtr, _dbgMaxGap * f, _dbgCompose * f / n, _dbgConvert * f / n, _dbgEncode * f / n,
            es?.waitMs ?? 0, es?.latMs ?? 0, es?.latMaxMs ?? 0, es?.busy ?? 0, hw?.QualityVsSpeed, es?.outs ?? 0, conv.OutWidth, conv.OutHeight);
        if (es is { } s0 && s0.outs > 0) Interlocked.Exchange(ref _encLatencyUs, (long)(s0.latMs * 1000));
        if (gpuTimer is { Samples: > 0 }) { _log.LogDebug("gpu: cursor+convert {Ms:F2} ms (n={N})", gpuTimer.SumMs / gpuTimer.Samples, gpuTimer.Samples); gpuTimer.SumMs = 0; gpuTimer.Samples = 0; }

        if (hw == null || !hw.IsHardware || NoAdapt || es is not { } st) return;
        if (_windows++ == 0) return; // start-up window
        _sinceSwitch++;
        double budget = 1000.0 / _cfg.Fps;
        int fps = _cfg.Fps;
        // Real content updates (video, animation, scrolling), not just the pointer: only these may lower the size.
        bool motion = _dbgDesk >= fps * 0.5;
        bool backpressure = st.busy > 0 || st.waitMs > budget * 0.3 || st.latMs > budget * 1.35;
        bool limited = motion && fpsNow < fps * 0.92 && backpressure;
        _limitedRun = limited ? _limitedRun + 1 : 0;
        _calmRun = _dbgDesk <= fps * 0.2 ? _calmRun + 1 : 0;
        if (!backpressure && fpsNow > fps * 0.93 && ++_goodWindows == 3) EncoderHealthy(conv.OutWidth, conv.OutHeight, fps);
        // a 60 Hz-ish source (>= 30 % of frame intervals near 1/fps) that we cannot deliver at full rate; a 24/30 fps
        // video never counts (its intervals are all long), so it keeps its own even cadence
        double shortFrac = _dbgN > 0 ? _dbgShort / (double)_dbgN : 0;
        _lowRun = motion && fpsNow < fps * 0.85 && shortFrac >= 0.3 ? _lowRun + 1 : 0;
        if (ForceSteady && motion) _lowRun = Math.Max(_lowRun, 4); // diagnostics: PLEXI_FORCE_STEADY=1 exercises the fallback
        if (_building != null || _sinceSwitch < 3) return;

        if (_steadyFps > 0)
        {
            _steadyWindows++;
            if (_calmRun >= 3)
            {
                SetCadence(cap, 0, "content calm");
                if (stage.Level > 0) { _log.LogInformation("Content calm again: back to full encode size"); StartBuild(cap, 0, "content calm"); }
            }
            // headroom probe every ~10 s: the source still offers ~60 and the encoder idles -> try the full rate again
            else if (!ForceSteady && _steadyWindows >= 10 && _dbgDesk >= fps * 0.95 && st.waitMs < budget * 0.15 && st.busy == 0)
                SetCadence(cap, 0, "headroom probe");
            return;
        }

        // NVIDIA "serialized" mode: slow although only the pointer moves (seen at start-up and also after running well for a while)
        // -> a fresh instance at the same size (seamless now; at most 3 in a row per size until one runs well again)
        bool pointerSlow = !motion && _dbgPtr * 2 > _dbgN && fpsNow < fps * 0.9 && (st.busy > 0 || st.latMs > budget * 1.25 || st.waitMs > budget * 0.6);
        if (pointerSlow && RetryEncoder(conv.OutWidth, conv.OutHeight, fps))
        {
            _log.LogWarning("Encoder slow at {W}x{H} ({Lat:F1} ms/frame, {Fps:F0} fps) with pointer-only updates; starting a fresh encoder instance", conv.OutWidth, conv.OutHeight, st.latMs, fpsNow);
            StartBuild(cap, stage.Level, "fresh encoder instance");
            return;
        }
        if (limited && _limitedRun >= 2 && hw.SpeedUp())
        {
            _log.LogInformation("Encoder too slow ({Lat:F1} ms/frame, wait {Wait:F1} ms, {Fps:F0} fps): switched to the fastest preset", st.latMs, st.waitMs, fpsNow);
            _limitedRun = 0;
            return;
        }
        if (_limitedRun >= 3 && stage.Level + 1 < Ladder.Length)
        {
            var (nw, nh) = SizeFor(cap.Width, cap.Height, stage.Level + 1);
            _log.LogInformation("Full-motion content: encoder keeps only {Fps:F0} fps at {W}x{H} (wait {Wait:F1} ms, latency {Lat:F1} ms); encoding at {NW}x{NH} until the motion stops",
                fpsNow, conv.OutWidth, conv.OutHeight, st.waitMs, st.latMs, nw, nh);
            StartBuild(cap, stage.Level + 1, "full-motion content");
            return;
        }
        // Still well below the full rate (desktop composition itself is the limit on a weak GPU, or the smallest size is
        // reached): an even cadence beats a higher but jittery one - e.g. 40 fps on a 120 Hz tablet is exactly 3 vsyncs
        // per frame, while 44-52 fps alternates 2 and 3 vsyncs (visible judder).
        if (_lowRun >= 4 && (!backpressure || stage.Level + 1 >= Ladder.Length) && (ForceSteady ? 40 : SteadyFpsFor(fpsNow)) is int sf and > 0)
        {
            _log.LogInformation("Full-motion content held at only {Fps:F0} fps (desk {Desk}); switching to a steady {Steady} fps cadence (tablet {Hz} Hz) until the motion stops",
                fpsNow, _dbgDesk, sf, _cfg.TabletRefreshHz);
            SetCadence(cap, sf, "steady fallback");
            return;
        }
        if (stage.Level > 0 && _calmRun >= 3)
        {
            // a size that was too slow for motion a moment ago is still fine for a calm desktop; if motion comes back
            // the ladder steps down again (one IDR each way)
            _log.LogInformation("Content calm again: back to full encode size");
            StartBuild(cap, 0, "content calm");
        }
    }

    public void Stop()
    {
        _stop = true;
        if (_thread.IsAlive && Thread.CurrentThread != _thread) _thread.Join(5000);
        _ready.TrySetCanceled();
    }

    public void Dispose() => Stop();
}
