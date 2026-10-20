using System.Diagnostics;
using Microsoft.Extensions.Logging;
using PlexiChore.Engine.Capture;
using PlexiChore.Engine.Codecs;
using PlexiChore.Engine.Native;
using PlexiChore.Engine.Streaming;

namespace PlexiChore.Engine.Diagnostics;

/// Offline encoder sweep (tools\EngineHost --encbench): captures a monitor (run a full-motion animation on it, e.g.
/// `Bench anim --seconds 300`), scales to each size, encodes with each tuning at a paced frame rate and prints the
/// achieved output rate, output-interval jitter, submit cost, GPU convert time and frame sizes. No tablet needed.
public static class EncoderProbe
{
    public static int Run(string[] args, ILogger log)
    {
        string? dev = null;
        string sizes = "2560x1600,1920x1200,1600x1000";
        string tunings = "";
        int fps = 60, seconds = 5, kbps = 20000;
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--dev": dev = args[++i]; break;
                case "--sizes": sizes = args[++i]; break;
                case "--tunings": tunings = args[++i]; break;
                case "--fps": fps = int.Parse(args[++i]); break;
                case "--seconds": seconds = int.Parse(args[++i]); break;
                case "--kbps": kbps = int.Parse(args[++i]); break;
            }
        }
        NativeMethods.SetThreadDpiAwarenessContext(NativeMethods.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        NativeMethods.timeBeginPeriod(1);
        Vortice.MediaFoundation.MediaFactory.MFStartup(true).CheckError();
        dev ??= Monitors.Enumerate().First().DeviceName;
        using var cap = DesktopCapture.Create(dev, log, TimeSpan.FromSeconds(2));
        Console.WriteLine($"capture {dev} {cap.Width}x{cap.Height} on {cap.AdapterName}");
        var tuneList = tunings.Split(';').Select(s => s.Trim() == "default" ? "" : s.Trim()).ToList();
        foreach (var size in sizes.Split(',', StringSplitOptions.RemoveEmptyEntries))
        {
            var wh = size.Split('x');
            int w = int.Parse(wh[0]), h = int.Parse(wh[1]);
            foreach (var spec in tuneList)
            {
                MfH264Encoder.Tuning = MfH264Encoder.EncoderTuning.Parse(spec);
                try { RunOne(cap, log, w, h, fps, seconds, kbps, spec); }
                catch (Exception ex) { Console.WriteLine($"{w}x{h} [{spec}] failed: {ex.Message} 0x{ex.HResult:X8}"); }
            }
        }
        NativeMethods.timeEndPeriod(1);
        return 0;
    }

    private static void RunOne(DesktopCapture cap, ILogger log, int w, int h, int fps, int seconds, int kbps, string spec)
    {
        var outTicks = new List<long>(fps * seconds + 64);
        long bytes = 0, idrBytes = 0, idrs = 0, maxFrame = 0;
        var lk = new object();
        void OnOut(long pts, byte flags, ReadOnlySpan<byte> data)
        {
            if ((flags & Protocol.VideoFlags.CodecConfig) != 0) return;
            lock (lk)
            {
                outTicks.Add(Stopwatch.GetTimestamp());
                bytes += data.Length;
                if (data.Length > maxFrame) maxFrame = data.Length;
                if ((flags & Protocol.VideoFlags.Keyframe) != 0) { idrs++; idrBytes += data.Length; }
            }
        }
        var swc = Stopwatch.StartNew();
        using var enc = MfH264Encoder.TryCreate(log, cap.Device, cap.Context, w, h, fps, kbps, "balanced", allowHardware: true, allowSoftware: false, OnOut)
                        ?? throw new InvalidOperationException("no hardware encoder");
        long createMs = swc.ElapsedMilliseconds;
        using var conv = new VideoConverter(cap.Device, cap.Context, cap.Width, cap.Height, w, h, enc.InputFormat, enc.InputRingSize, fps);
        using var gpu = new GpuTimer(cap.Device, cap.Context);
        long freq = Stopwatch.Frequency, interval = freq / fps;
        long start = Stopwatch.GetTimestamp(), next = start, end = start + freq * seconds;
        long submitTicks = 0; int n = 0, newFrames = 0;
        double gpuSum = 0; int gpuN = 0;
        enc.TakeEncoderStats();
        while (Stopwatch.GetTimestamp() < end)
        {
            long now = Stopwatch.GetTimestamp();
            int wait = (int)Math.Max(0, (next - now) * 1000 / freq);
            var r = cap.Acquire(wait);
            if (r == AcquireResult.NewFrame) newFrames++;
            if (Stopwatch.GetTimestamp() < next - freq / 2000) continue;
            if (!cap.HasFrame) { next += interval; continue; }
            next += interval;
            if (Stopwatch.GetTimestamp() - next > interval * 2) next = Stopwatch.GetTimestamp() + interval; // fell behind: no burst
            bool timing = gpu.Begin();
            var composed = cap.Compose();
            if (composed == null) continue;
            var nv12 = conv.Convert(composed);
            if (timing) gpu.End();
            long t0 = Stopwatch.GetTimestamp();
            enc.Encode(nv12, (t0 - start) * 10_000_000 / freq, n == 0);
            submitTicks += Stopwatch.GetTimestamp() - t0;
            n++;
            if (gpu.Samples > 0) { gpuSum += gpu.SumMs; gpuN += gpu.Samples; gpu.SumMs = 0; gpu.Samples = 0; }
        }
        Thread.Sleep(200);
        var st = enc.TakeEncoderStats();
        List<double> iv;
        lock (lk) iv = outTicks.Zip(outTicks.Skip(1), (a, b) => (b - a) * 1000.0 / freq).OrderBy(x => x).ToList();
        double P(double q) => iv.Count == 0 ? 0 : iv[Math.Min(iv.Count - 1, (int)(q * iv.Count))];
        double outFps = outTicks.Count > 1 ? (outTicks.Count - 1) * (double)freq / (outTicks[^1] - outTicks[0]) : 0;
        Console.WriteLine($"{w}x{h} [{(spec.Length == 0 ? "default" : spec)}] create {createMs} ms | in {n / (double)seconds:F1} fps (desk {newFrames / (double)seconds:F0}) " +
                          $"out {outFps:F1} fps | iv p50 {P(.5):F1} p95 {P(.95):F1} p99 {P(.99):F1} max {(iv.Count > 0 ? iv[^1] : 0):F1} ms | " +
                          $"submit {submitTicks * 1000.0 / freq / Math.Max(1, n):F2} ms lat {st.latMs:F1} busy {st.busy} | gpu conv {(gpuN > 0 ? gpuSum / gpuN : 0):F2} ms | " +
                          $"avg {bytes / Math.Max(1, outTicks.Count) / 1024.0:F0} KB max {maxFrame / 1024.0:F0} KB idr {(idrs > 0 ? idrBytes / idrs / 1024.0 : 0):F0} KB");
    }
}

