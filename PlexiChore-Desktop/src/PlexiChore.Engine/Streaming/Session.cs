using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using PlexiChore.Engine.Capture;
using PlexiChore.Engine.Input;
using PlexiChore.Engine.Protocol;

namespace PlexiChore.Engine.Streaming;

internal interface ISessionHost
{
    ServerOptions Options { get; }
    IVirtualDisplayProvider? VirtualDisplays { get; }
    bool IsTrusted(string deviceId);
    void MarkTrusted(string deviceId);
    void OnSessionStarted(Session s, SessionInfo info);
    void OnSessionUpdated(Session s, SessionInfo info);
    void OnSessionEnded(Session s, SessionInfo info);
    void OnStats(SessionStats stats);
    void OnPairing(PairingRequest req);
}

/// One connected tablet: handshake, pairing, receive loop, keep-alive, stream (re)configuration, input.
internal sealed partial class Session
{
    private static readonly TimeSpan HelloTimeout = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan PairingTimeout = TimeSpan.FromMinutes(2);
    private const long DeadAfterMs = 5000;

    private readonly Socket _socket;
    private readonly ISessionHost _host;
    private readonly ILogger _log;
    private readonly CancellationTokenSource _cts;
    private readonly SemaphoreSlim _reconfigLock = new(1, 1);
    private NetworkStream _stream = null!;
    private SessionSender _sender = null!;
    private InputInjector? _injector;
    private HelloMessage _hello = new();
    private RequestedSettings _requested = new();
    private volatile StreamPipeline? _pipeline;
    private VirtualMonitor? _vm;
    private (int w, int h, int fps, string pos, bool primary) _vmKey;
    private volatile bool _approved;
    private volatile bool _streamActive;
    private bool _startedRaised;
    private bool _disallowHw, _forceMjpeg, _extendBroken;
    private int _pipelineFailures;
    // adaptive encode-size level of the last pipeline of THIS session (a new session always starts at full size)
    private (string dev, int w, int h, int fps, int level, long tick) _levelHint;
    private long _lastRxMs = Environment.TickCount64;
    private double _rttMs;
    private string _endReason = "closed";

    public Guid Id { get; } = Guid.NewGuid();
    public bool IsUsb { get; }
    public string Remote { get; }
    public SessionInfo? Info { get; private set; }

    public Session(Socket socket, ISessionHost host, ILogger log, CancellationToken serverCt)
    {
        _socket = socket; _host = host; _log = log;
        _cts = CancellationTokenSource.CreateLinkedTokenSource(serverCt);
        var ep = socket.RemoteEndPoint as IPEndPoint;
        var addr = ep?.Address ?? IPAddress.None;
        if (addr.IsIPv4MappedToIPv6) addr = addr.MapToIPv4();
        IsUsb = IPAddress.IsLoopback(addr);
        Remote = ep?.ToString() ?? "?";
    }

    private static long NowMicros() => Stopwatch.GetTimestamp() * 1_000_000 / Stopwatch.Frequency;

    public async Task RunAsync()
    {
        var ct = _cts.Token;
        _socket.NoDelay = true;
        _socket.SendBufferSize = 192 * 1024; // ~3 frames at 20 Mbps: congestion shows up in our queue (drops stale frames), not as kernel lag
        _stream = new NetworkStream(_socket, ownsSocket: true);
        _sender = new SessionSender(_stream) { KeyframeNeeded = () => _pipeline?.RequestKeyframe() };
        var sendTask = _sender.RunAsync(ct);
        Task? recvTask = null, keepAlive = null;
        try
        {
            // ---- HELLO ----
            var first = await Wire.ReadAsync(_stream, ct).WaitAsync(HelloTimeout, ct);
            if (first == null || first.Value.Type != MessageType.Hello)
            {
                _endReason = "no HELLO";
                await ByeAsync("expected HELLO");
                return;
            }
            _hello = JsonSerializer.Deserialize<HelloMessage>(first.Value.Payload, Wire.Json) ?? new HelloMessage();
            _hello.Requested ??= new RequestedSettings();
            _hello.Requested.Sanitize();
            _requested = _hello.Requested;
            if (string.IsNullOrWhiteSpace(_hello.DeviceId)) _hello.DeviceId = "unknown-" + Remote;
            _log.LogInformation("HELLO from {Name} ({Model}) {W}x{H} via {Transport} {Remote}: mode={Mode} codec={Codec} fps={Fps} {Kbps}kbps",
                _hello.DeviceName, _hello.Model, _hello.WidthPx, _hello.HeightPx, IsUsb ? "USB" : "Wi-Fi", Remote,
                _requested.Mode, _requested.Codec, _requested.Fps, _requested.BitrateKbps);

            _lastRxMs = Environment.TickCount64;
            // USB = adb reverse: over the cable or over wireless debugging? (asked in parallel with the pipeline start)
            var resolver = _host.Options.LoopbackLinkResolver;
            _linkTask = !IsUsb ? Task.FromResult<string?>(NetworkLink()) : resolver == null ? Task.FromResult<string?>(null)
                : Task.Run(async () => { try { return await resolver(_hello.Model, ct); } catch { return null; } });
            recvTask = ReceiveLoopAsync(ct);
            keepAlive = KeepAliveLoopAsync(ct);

            // ---- pairing ----
            var opts = _host.Options;
            if (!IsUsb && opts.RequireApprovalForWifi && !_host.IsTrusted(_hello.DeviceId))
            {
                string code = RandomNumberGenerator.GetInt32(0, 10000).ToString("D4");
                var tcs = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                _sender.EnqueueControl(Wire.FrameJson(MessageType.Pairing, new PairingMessage { Status = "waiting", Code = code }));
                _host.OnPairing(new PairingRequest
                {
                    DeviceId = _hello.DeviceId, DeviceName = _hello.DeviceName, Code = code,
                    Respond = ok => tcs.TrySetResult(ok),
                });
                var winner = await Task.WhenAny(tcs.Task, recvTask, Task.Delay(PairingTimeout, ct));
                bool ok = winner == tcs.Task && tcs.Task.Result;
                if (!ok)
                {
                    _endReason = "pairing rejected";
                    if (winner != recvTask)
                    {
                        _sender.EnqueueControl(Wire.FrameJson(MessageType.Pairing, new PairingMessage { Status = "rejected", Code = code }));
                        await ByeAsync("pairing rejected");
                    }
                    return;
                }
                _host.MarkTrusted(_hello.DeviceId);
                _sender.EnqueueControl(Wire.FrameJson(MessageType.Pairing, new PairingMessage { Status = "approved", Code = code }));
            }

            _injector = new InputInjector(_log);
            _approved = true;
            await ReconfigureAsync("hello");

            var done = await Task.WhenAny(recvTask, sendTask, keepAlive);
            if (done.IsFaulted) _log.LogDebug("session loop ended: {Msg}", done.Exception?.GetBaseException().Message);
        }
        catch (OperationCanceledException) { }
        catch (TimeoutException) { _endReason = "HELLO timeout"; }
        catch (Exception ex) when (ex is IOException or SocketException or ObjectDisposedException)
        {
            _log.LogDebug("session I/O ended: {Msg}", ex.Message);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "Session {Id} failed", Id);
            _endReason = "error: " + ex.Message;
        }
        finally
        {
            _cts.Cancel();
            await CleanupAsync();
        }
    }

    private async Task CleanupAsync()
    {
        bool locked = await _reconfigLock.WaitAsync(TimeSpan.FromSeconds(30));
        try { _pipeline?.Stop(); } catch { }
        if (locked) _reconfigLock.Release();
        _pipeline = null;
        _injector?.Dispose();
        await DetachVmAsync(VirtualDisplayLeases.LingerFor(_endReason)); // grace period for a fast reconnect
        try { _stream?.Dispose(); } catch { }
        _log.LogInformation("Session {Name} ({Remote}) ended: {Reason}", _hello.DeviceName, Remote, _endReason);
        if (_startedRaised && Info != null) _host.OnSessionEnded(this, Info);
    }

    private async Task ByeAsync(string reason)
    {
        try
        {
            _sender.EnqueueControl(Wire.FrameText(MessageType.Bye, reason));
            await _sender.FlushControlAsync(TimeSpan.FromMilliseconds(500));
        }
        catch { }
    }

    /// Host-initiated disconnect.
    public async Task DisconnectAsync(string reason)
    {
        _endReason = reason;
        await ByeAsync(reason);
        _cts.Cancel();
    }

    private async Task ReceiveLoopAsync(CancellationToken ct)
    {
        await Task.Yield();
        while (!ct.IsCancellationRequested)
        {
            var m = await Wire.ReadAsync(_stream, ct).ConfigureAwait(false);
            if (m == null) { _endReason = "connection closed by tablet"; return; }
            _lastRxMs = Environment.TickCount64;
            var (type, payload) = m.Value;
            switch (type)
            {
                case MessageType.Ping:
                    _sender.EnqueueControl(Wire.Frame(MessageType.Pong, payload));
                    break;
                case MessageType.Pong:
                    if (payload.Length == 8)
                    {
                        long sent = (long)BinaryPrimitives.ReadUInt64BigEndian(payload);
                        long rtt = NowMicros() - sent;
                        if (rtt >= 0 && rtt < 60_000_000) _rttMs = rtt / 1000.0;
                    }
                    break;
                case MessageType.Input:
                    if (_approved) _injector?.Post(PointerSample.Parse(payload));
                    break;
                case MessageType.Key:
                    if (_approved)
                    {
                        try
                        {
                            var k = JsonSerializer.Deserialize<KeyMessage>(payload, Wire.Json);
                            if (k != null) _injector?.Post(k);
                        }
                        catch (JsonException) { }
                    }
                    break;
                case MessageType.RequestKeyframe:
                    _pipeline?.RequestKeyframe();
                    break;
                case MessageType.Settings:
                    if (!_approved) break;
                    try
                    {
                        var merged = _requested.Merge(payload);
                        merged.Sanitize();
                        bool scaleOnly = DisplayScale.IsScaleOnlyChange(_requested, merged);
                        _requested = merged;
                        _log.LogInformation("SETTINGS {Json}", Encoding.UTF8.GetString(payload));
                        _ = scaleOnly ? ApplyScaleLiveAsync() : ReconfigureAsync("settings");
                    }
                    catch (JsonException ex) { _log.LogWarning("Bad SETTINGS: {Msg}", ex.Message); }
                    break;
                case MessageType.Bye:
                    _endReason = "tablet said BYE: " + Encoding.UTF8.GetString(payload);
                    return;
                case MessageType.Hello:
                    break; // duplicate HELLO ignored
            }
        }
    }

    private async Task KeepAliveLoopAsync(CancellationToken ct)
    {
        var sw = Stopwatch.StartNew();
        while (!ct.IsCancellationRequested)
        {
            long before = Environment.TickCount64;
            await Task.Delay(1000, ct).ConfigureAwait(false);
            // If this process itself stalled (paging, driver load under loader lock), do not blame the tablet.
            if (Environment.TickCount64 - before > 2500) _lastRxMs = Environment.TickCount64;
            var ping = new byte[8];
            BinaryPrimitives.WriteUInt64BigEndian(ping, (ulong)NowMicros());
            _sender.EnqueueControl(Wire.Frame(MessageType.Ping, ping));

            if (Environment.TickCount64 - _lastRxMs > DeadAfterMs)
            {
                _endReason = "timeout (no message for 5 s)";
                _cts.Cancel();
                return;
            }

            double elapsed = sw.Elapsed.TotalSeconds;
            sw.Restart();
            var p = _pipeline;
            long bytes = _sender.TakeBytesSent();
            if (p != null && _approved && _streamActive)
            {
                var (frames, encTicks) = p.TakeStats();
                double fps = frames / elapsed;
                double encMs = p.EncoderLatencyMs > 0 ? p.EncoderLatencyMs // capture -> bitstream, hardware encoder
                    : frames > 0 ? encTicks * 1000.0 / Stopwatch.Frequency / frames : 0;
                int kbps = (int)(bytes * 8 / 1000 / elapsed);
                _sender.EnqueueControl(Wire.FrameJson(MessageType.Stats, new StatsMessage
                {
                    CaptureFps = Math.Round(fps, 1), EncodeMs = Math.Round(encMs, 2), BitrateKbps = kbps,
                }));
                _host.OnStats(new SessionStats(Id, fps, encMs, kbps, _rttMs));
            }
        }
    }

    private void OnEncoded(long pts, byte flags, ReadOnlySpan<byte> data)
    {
        _sender.EnqueueVideo(Wire.VideoFrame(pts, flags, data), flags);
    }

    private void OnPipelineEnded(StreamPipeline p, string reason)
    {
        if (_cts.IsCancellationRequested || !ReferenceEquals(p, _pipeline)) return;
        _log.LogWarning("Pipeline ended: {Reason}", reason);
        if (reason.StartsWith("encoder:") || reason.StartsWith("error:"))
        {
            _pipelineFailures++;
            if (_pipelineFailures == 1) _disallowHw = true;
            else if (_pipelineFailures == 2) _forceMjpeg = true;
            if (_pipelineFailures > 6) { _ = DisconnectAsync("streaming failed: " + reason); return; }
        }
        _ = Task.Run(async () =>
        {
            await Task.Delay(reason == "resize" ? 300 : 1000);
            await ReconfigureAsync(reason);
        });
    }

    /// Same session rebuilding the pipeline for the same output/box shortly after (settings change, error retry):
    /// keep the adaptive encode-size level instead of rediscovering it. New sessions always start at full size.
    private int LevelHint(string dev, int w, int h, int fps)
    {
        var hnt = _levelHint;
        bool same = hnt.dev == dev && hnt.w == w && hnt.h == h && hnt.fps == fps && Environment.TickCount64 - hnt.tick < 30_000;
        if (same && hnt.level > 0) _log.LogInformation("Keeping the reduced encode size of this session (level {Level}) for the new pipeline", hnt.level);
        return same ? hnt.level : 0;
    }

    private void RememberLevel(StreamPipeline p) =>
        _levelHint = (p.Config.DeviceName, p.Config.BoxWidth, p.Config.BoxHeight, p.Config.Fps, p.Level, Environment.TickCount64);

    /// The pipeline changed its encode size without restarting: new CONFIG (same mode / monitor), then the new
    /// encoder's codec-config + IDR. Tablets with an adaptive decoder keep their decoder; others rebuild it.
    private void OnPipelineResized(StreamPipeline p, PipelineInfo info)
    {
        if (_cts.IsCancellationRequested || !ReferenceEquals(p, _pipeline)) return;
        var cfg = _lastConfig;
        if (cfg == null) return;
        cfg.Width = info.Width;
        cfg.Height = info.Height;
        cfg.Encoder = info.EncoderName;
        if (info.Fps > 0) cfg.Fps = info.Fps; // steady fallback cadence: the tablet re-times its frame pacer
        // a new encoder: queued frames of the old size are obsolete; restart at its IDR (cadence-only: keep the stream)
        if (info.NewStream) _sender.ResetVideo(true);
        _sender.EnqueueControl(Wire.FrameJson(MessageType.Config, cfg));
        _log.LogInformation("CONFIG -> {Name}: {Codec} {W}x{H}@{Fps} {Mode} from {Dev} {Bounds} encoder={Enc} (adaptive)",
            _hello.DeviceName, info.Codec, info.Width, info.Height, cfg.Fps, cfg.Mode, info.DeviceName, info.DesktopBounds, info.EncoderName);
        if (Info != null)
        {
            var updated = Info with { Width = info.Width, Height = info.Height };
            Info = updated;
            _ = Task.Run(() => { try { _host.OnSessionUpdated(this, updated); } catch { } });
        }
    }

    private Task<string?> _linkTask = Task.FromResult<string?>(null);

    /// Non-loopback session: "usb-tether" when the PC side of the connection is a USB network adapter (the tablet's
    /// USB tethering: "Remote NDIS based Internet Sharing Device" / NCM), else "wifi" (any LAN).
    private string NetworkLink()
    {
        try
        {
            var local = (_socket.LocalEndPoint as IPEndPoint)?.Address;
            if (local == null) return "wifi";
            if (local.IsIPv4MappedToIPv6) local = local.MapToIPv4();
            foreach (var nic in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
            {
                if (!nic.GetIPProperties().UnicastAddresses.Any(a => a.Address.Equals(local))) continue;
                var d = (nic.Description + " " + nic.Name).ToUpperInvariant();
                return d.Contains("NDIS") || d.Contains("NCM") || d.Contains("ANDROID") || d.Contains("USB") ? "usb-tether" : "wifi";
            }
        }
        catch { }
        return "wifi";
    }

    /// The physical link for CONFIG; waits at most 400 ms for the adb query (it normally finishes while the pipeline starts).
    private async Task<string?> LinkAsync()
    {
        var t = _linkTask;
        if (!t.IsCompleted) await Task.WhenAny(t, Task.Delay(400));
        var link = t.IsCompletedSuccessfully ? t.Result : null;
        if (link != null && link != _loggedLink) { _loggedLink = link; _log.LogInformation("Session link: {Link}", link); }
        return link;
    }
    private string? _loggedLink;

    private static int Even(double v) => Math.Max(2, (int)Math.Round(v) & ~1);

    /// Tablet-sized box (landscape, or portrait when the tablet is held portrait), clamped to what its decoder handles.
    private (int w, int h) TabletBox(double scale, bool portrait = false)
    {
        int tw = _hello.WidthPx > 0 ? _hello.WidthPx : 1920, th = _hello.HeightPx > 0 ? _hello.HeightPx : 1080;
        int longPx = Math.Max(tw, th), shortPx = Math.Min(tw, th);
        double w = (portrait ? shortPx : longPx) * scale, h = (portrait ? longPx : shortPx) * scale;
        int maxW = _hello.MaxDecodeWidth > 0 ? _hello.MaxDecodeWidth : 3840, maxH = _hello.MaxDecodeHeight > 0 ? _hello.MaxDecodeHeight : 2160;
        // decoders usually accept the rotated limits too; compare on long/short edges
        int longMax = Math.Max(maxW, maxH), shortMax = Math.Min(maxW, maxH);
        double f = Math.Min(1.0, Math.Min(longMax / Math.Max(w, h), shortMax / Math.Min(w, h)));
        return (Even(w * f), Even(h * f));
    }

    /// Applies the tablet's reported decode modes (additive HELLO field): never send a size/fps pair the decoder
    /// cannot handle. Keeps the size and lowers the frame rate when that suffices (sharp text matters more on a
    /// monitor), otherwise shrinks to the largest supported mode. Tablets without decodeModes: unchanged.
    private (int w, int h, int fps) ClampToDecoder((int w, int h) box, int fps)
    {
        var modes = _hello.DecodeModes?.Where(m => m.Width > 0 && m.Height > 0 && m.MaxFps > 0).ToList();
        if (modes == null || modes.Count == 0) return (box.w, box.h, fps);
        int bl = Math.Max(box.w, box.h), bs = Math.Min(box.w, box.h);
        static (int l, int s) Edges(DecodeModeDto m) => (Math.Max(m.Width, m.Height), Math.Min(m.Width, m.Height));
        var covering = modes.Where(m => Edges(m).l >= bl && Edges(m).s >= bs).ToList();
        if (covering.Count > 0)
        {
            int maxFps = covering.Max(m => m.MaxFps);
            return (box.w, box.h, Math.Min(fps, Math.Max(maxFps, 30)));
        }
        // the box is bigger than every supported mode: use the largest mode that still reaches 30 fps
        var best = modes.Where(m => m.MaxFps >= 30).OrderByDescending(m => (long)m.Width * m.Height).FirstOrDefault()
                   ?? modes.OrderByDescending(m => (long)m.Width * m.Height).First();
        var (ml, ms) = Edges(best);
        double f = Math.Min(1.0, Math.Min((double)ml / bl, (double)ms / bs));
        _log.LogInformation("Tablet decoder cannot take {W}x{H}; limiting to {MW}x{MH}@{Fps}", box.w, box.h, best.Width, best.Height, best.MaxFps);
        return (Even(box.w * f), Even(box.h * f), Math.Min(fps, Math.Max(best.MaxFps, 30)));
    }

    /// H.264 profile for this tablet's decoder: High unless it only reports Main / Baseline (eAVEncH264VProfile values).
    private uint H264ProfileForTablet()
    {
        var p = _hello.H264Profiles;
        if (p == null || p.Count == 0 || p.Any(x => string.Equals(x, "high", StringComparison.OrdinalIgnoreCase))) return 100;
        if (p.Any(x => string.Equals(x, "main", StringComparison.OrdinalIgnoreCase))) return 77;
        return 66;
    }

    private async Task DetachVmAsync(TimeSpan linger = default)
    {
        var vm = _vm;
        _vm = null;
        if (vm == null || _host.VirtualDisplays == null) return;
        try
        {
            var detach = _host.VirtualDisplays is VirtualDisplayLeases leases ? leases.ReleaseAsync(vm, linger) : _host.VirtualDisplays.DetachAsync(vm);
            await detach.WaitAsync(TimeSpan.FromSeconds(10));
        }
        catch (Exception ex) { _log.LogWarning("Virtual display detach failed: {Msg}", ex.Message); }
    }

    public async Task ReconfigureAsync(string why)
    {
        await _reconfigLock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_cts.IsCancellationRequested) return;
            var old = _pipeline;
            _pipeline = null;
            _streamActive = false;
            _sender.ResetVideo(false);
            old?.Stop();
            if (old != null) RememberLevel(old);

            var req = _requested.Clone();
            var vdp = _host.VirtualDisplays;
            // "primary" = extend + the virtual monitor becomes the Windows primary display (provider restores on detach)
            string mode = req.Mode is "extend" or "primary" && !_extendBroken ? req.Mode : "mirror";
            bool virtualMode = mode != "mirror";
            string? deviceName = null;
            int boxW = 0, boxH = 0;
            int fps = req.Fps;
            bool portrait = req.Orientation == "portrait";

            if (virtualMode)
            {
                bool available = false;
                try { available = vdp?.IsAvailable == true; } catch { }
                if (available)
                {
                    bool makePrimary = mode == "primary";
                    var (vw, vh, vfps) = ClampToDecoder(TabletBox(req.ResolutionScale, portrait), req.Fps);
                    fps = vfps;
                    var key = (vw, vh, vfps, req.Position, makePrimary);
                    if (_vm != null && _vmKey != key) await DetachVmAsync();
                    if (_vm == null)
                    {
                        try
                        {
                            // primary switches can take longer (two display-config applies + settle)
                            var attach = makePrimary
                                ? vdp!.AttachAsync(vw, vh, vfps, req.Position, makePrimary: true, _cts.Token)
                                : vdp!.AttachAsync(vw, vh, vfps, req.Position, _cts.Token);
                            _vm = await attach.WaitAsync(TimeSpan.FromSeconds(makePrimary ? 30 : 20), _cts.Token);
                            _vmKey = key;
                            if (_vm != null) _log.LogInformation("Virtual display attached ({Mode}): {Dev} {Bounds}", mode, _vm.DeviceName, _vm.DesktopBounds);
                        }
                        catch (Exception ex) when (ex is not OperationCanceledException || !_cts.IsCancellationRequested)
                        {
                            _log.LogWarning("Virtual display attach failed: {Msg}", ex.Message);
                            _vm = null;
                        }
                    }
                    if (_vm != null)
                    {
                        deviceName = _vm.DeviceName; boxW = vw; boxH = vh;
                        // Portrait requested but the driver only had landscape modes (or vice versa): fit the
                        // stream to what was attached instead of squeezing it into the other orientation.
                        var b = _vm.DesktopBounds;
                        if (b.Width > 0 && b.Height > 0 && (b.Width > b.Height) != (vw > vh))
                        {
                            _log.LogInformation("Virtual monitor is {W}x{H}, not {Orient}; streaming it as is", b.Width, b.Height, portrait ? "portrait" : "landscape");
                            (boxW, boxH, fps) = ClampToDecoder(TabletBox(req.ResolutionScale, portrait: b.Height > b.Width), req.Fps);
                        }
                    }
                    if (_vm != null) await EnsureScaleAsync(vdp!, req); // display scale (DPI) of the virtual monitor, before capture starts
                }
                if (deviceName == null)
                {
                    _log.LogInformation("{Mode} mode unavailable, using mirror", mode);
                    mode = "mirror";
                }
            }

            var monitors = Monitors.Enumerate();
            if (mode == "mirror")
            {
                await DetachVmAsync();
                monitors = Monitors.Enumerate();
                var m = monitors.ElementAtOrDefault(req.MonitorIndex) ?? monitors.FirstOrDefault()
                        ?? throw new InvalidOperationException("No display outputs found");
                deviceName = m.DeviceName;
                (boxW, boxH, fps) = ClampToDecoder(TabletBox(req.ResolutionScale), req.Fps); // mirror: the PC desktop is landscape
            }

            bool tabletH264 = _hello.Codecs == null || _hello.Codecs.Count == 0 || _hello.Codecs.Any(c => string.Equals(c, "h264", StringComparison.OrdinalIgnoreCase));
            string codec = req.Codec == "mjpeg" || _forceMjpeg || !tabletH264 ? "mjpeg" : "h264";
            var cfg = new PipelineConfig(deviceName!, boxW, boxH, fps, req.BitrateKbps, req.Quality ?? "balanced", codec,
                _host.Options.PreferHardwareEncoder && !_disallowHw, AllowH264: true,
                WaitForOutput: mode != "mirror" ? TimeSpan.FromSeconds(10) : TimeSpan.FromSeconds(2),
                ArrowWhenHidden: req.TouchMode == "mouse", H264Profile: H264ProfileForTablet(), InitialLevel: LevelHint(deviceName!, boxW, boxH, fps),
                TabletRefreshHz: _hello.RefreshHz);

            var p = new StreamPipeline(cfg, _log, OnEncoded);
            p.Ended += reason => OnPipelineEnded(p, reason);
            p.Resized += info => OnPipelineResized(p, info);
            _pipeline = p;
            p.Start();
            PipelineInfo info;
            try
            {
                info = await p.Ready.WaitAsync(TimeSpan.FromSeconds(60), _cts.Token);
            }
            catch (Exception ex) when (!_cts.IsCancellationRequested)
            {
                _pipeline = null;
                p.Stop();
                _log.LogWarning("Stream start failed ({Mode}): {Msg}", mode, ex.Message);
                if (mode != "mirror") _extendBroken = true; // retry as mirror (DetachVmAsync restores the primary)
                if (++_pipelineFailures > 6) { _ = DisconnectAsync("cannot start capture: " + ex.Message); return; }
                _ = Task.Run(async () => { await Task.Delay(1000); await ReconfigureAsync("retry"); });
                return;
            }

            _sender.IsMjpeg = info.Codec == "mjpeg";
            var config = new ConfigMessage
            {
                Codec = info.Codec, Width = info.Width, Height = info.Height, Fps = fps, BitrateKbps = req.BitrateKbps,
                Mode = mode, HostName = _host.Options.HostName, HostOs = "windows",
                Monitors = monitors.Select(m => new MonitorInfoDto
                {
                    Index = m.Index, Name = m.IsPrimary ? "Primary" : m.DeviceName.TrimStart('\\', '.'),
                    Width = m.Bounds.Width, Height = m.Bounds.Height,
                }).ToList(),
                VirtualDisplayAvailable = SafeAvailable(vdp),
                Encoder = info.EncoderName,
                ScalePercent = mode != "mirror" ? _scaleApplied : 0,
                Link = await LinkAsync(),
            };
            _lastConfig = config;
            _sender.EnqueueControl(Wire.FrameJson(MessageType.Config, config));
            _sender.ResetVideo(true);
            _streamActive = true;
            p.RequestKeyframe();
            _injector?.SetTarget(() => p.CurrentBounds, req.TouchMode);
            _log.LogInformation("CONFIG -> {Name}: {Codec} {W}x{H}@{Fps} {Mode} from {Dev} {Bounds} encoder={Enc} ({Why})",
                _hello.DeviceName, info.Codec, info.Width, info.Height, fps, mode, info.DeviceName, info.DesktopBounds, info.EncoderName, why);

            Info = new SessionInfo(Id, _hello.DeviceId, _hello.DeviceName, _hello.Model, IsUsb, mode, info.Width, info.Height, fps, info.Codec)
                { ScalePercent = config.ScalePercent, ScaleAuto = req.ScalePercent == 0 };
            if (!_startedRaised) { _startedRaised = true; _host.OnSessionStarted(this, Info); }
            else _host.OnSessionUpdated(this, Info);
        }
        catch (Exception ex) when (!_cts.IsCancellationRequested)
        {
            _log.LogError(ex, "Reconfigure failed");
            _ = DisconnectAsync("configuration failed: " + ex.Message);
        }
        catch (Exception) { try { _pipeline?.Stop(); } catch { } _pipeline = null; }
        finally
        {
            _reconfigLock.Release();
        }
    }

    private static bool SafeAvailable(IVirtualDisplayProvider? p)
    {
        try { return p?.IsAvailable == true; } catch { return false; }
    }
}
