using Microsoft.Extensions.Logging;
using PlexiChore.Engine.Codecs;
using Vortice.Direct3D;
using Vortice.Direct3D11;

namespace PlexiChore.Engine.Streaming;

internal static class EngineWarmup
{
    /// Pages in the GPU driver / DXGI / MF encoder DLLs at server start so the first tablet connection starts fast.
    public static void Run(ILogger log)
    {
        try
        {
            var sw = System.Diagnostics.Stopwatch.StartNew();
            Capture.Monitors.Enumerate();
            D3D11.D3D11CreateDevice(null, DriverType.Hardware, DeviceCreationFlags.BgraSupport | DeviceCreationFlags.VideoSupport,
                new[] { FeatureLevel.Level_11_1, FeatureLevel.Level_11_0, FeatureLevel.Level_10_0 }, out ID3D11Device dev, out ID3D11DeviceContext ctx).CheckError();
            using (var mt = dev.QueryInterface<ID3D11Multithread>()) mt.SetMultithreadProtected(true);
            long devMs = sw.ElapsedMilliseconds;
            // A real (tiny) hardware encoder session: loads and initialises the vendor encoder MFT once.
            using (var enc = MfH264Encoder.TryCreate(log, dev, ctx, 640, 360, 30, 2000, "performance", allowHardware: true, allowSoftware: false,
                       (_, _, _) => { }))
            { }
            try { Capture.GpuCursor.Precompile(out _); } catch (Exception ex) { log.LogDebug("cursor shaders: {Msg}", ex.Message); }
            Capture.DevicePool.Park(dev, ctx); // the first pipeline on this adapter reuses it
            long encMs = sw.ElapsedMilliseconds;
            DryRun(log);
            log.LogDebug("Warm-up done in {Ms} ms (device {Dev} ms, encoder {Enc} ms)", sw.ElapsedMilliseconds, devMs, encMs);
        }
        catch (Exception ex) { log.LogDebug("Warm-up failed: {Msg}", ex.Message); }
    }

    /// Runs the real capture -> cursor -> convert -> encode path for a moment on the primary display (tiny output,
    /// discarded) so JIT, D3D/MFT first-use costs and shader creation are paid at start-up, not by the first tablet
    /// (cold, the first session's first frame otherwise took ~2 s longer).
    private static void DryRun(ILogger log)
    {
        try
        {
            var primary = Capture.Monitors.Enumerate().FirstOrDefault();
            if (primary == null) return;
            var quiet = Microsoft.Extensions.Logging.Abstractions.NullLogger.Instance;
            var cfg = new PipelineConfig(primary.DeviceName, 640, 360, 30, 1000, "performance", "h264", AllowHardware: true, AllowH264: true,
                WaitForOutput: TimeSpan.FromSeconds(2));
            using var p = new StreamPipeline(cfg, quiet, (_, _, _) => { });
            p.Start();
            if (!p.Ready.Wait(TimeSpan.FromSeconds(5))) return;
            Thread.Sleep(400);
            p.RequestKeyframe();
            Thread.Sleep(300);
        }
        catch (Exception ex) { log.LogDebug("Warm-up dry run: {Msg}", ex.GetBaseException().Message); }
    }
}
