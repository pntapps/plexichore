using Microsoft.Extensions.Logging;
using PlexiChore.Engine.Protocol;

namespace PlexiChore.Engine.Streaming;

/// Windows display scale (DPI) of the tablet's virtual monitor: `requested.scalePercent` (0 = auto from HELLO densityDpi),
/// applied right after attach (extend + primary) and live on SETTINGS without re-attaching. Reported in CONFIG.
internal sealed partial class Session
{
    private ConfigMessage? _lastConfig;
    private int _scaleApplied;              // percent in effect on _scaledVm, 0 = unknown / unsupported
    private VirtualMonitor? _scaledVm;      // reference identity: a re-attach yields a new instance → re-apply
    private int _scaledRequest = -1;

    /// Tablet pixels per virtual-monitor pixel (> 1 when the resolution scale is below 100%); the tablet fits the frame.
    private double PixelRatio(VirtualMonitor vm)
    {
        int tw = Math.Max(_hello.WidthPx, _hello.HeightPx), th = Math.Min(_hello.WidthPx, _hello.HeightPx);
        int vw = Math.Max(vm.DesktopBounds.Width, vm.DesktopBounds.Height), vh = Math.Min(vm.DesktopBounds.Width, vm.DesktopBounds.Height);
        if (tw <= 0 || th <= 0 || vw <= 0 || vh <= 0) return 1.0;
        return Math.Max(1.0, Math.Min((double)tw / vw, (double)th / vh));
    }

    /// Applies the requested scale to the current virtual monitor unless it is already applied. Never throws (except
    /// session cancellation); failures leave the scale as Windows had it and report 0.
    private async Task EnsureScaleAsync(IVirtualDisplayProvider vdp, RequestedSettings req)
    {
        var vm = _vm;
        if (vm == null) return;
        if (ReferenceEquals(vm, _scaledVm) && req.ScalePercent == _scaledRequest) return;
        int target = DisplayScale.Resolve(req.ScalePercent, _hello.DensityDpi, PixelRatio(vm), Math.Min(_hello.WidthPx, _hello.HeightPx));
        int applied = 0;
        try
        {
            applied = await vdp.SetScaleAsync(vm, target, _hello.DensityDpi, _cts.Token).WaitAsync(TimeSpan.FromSeconds(8), _cts.Token);
            _log.LogInformation("Display scale {Dev}: requested {Req} (densityDpi {Dpi}) -> target {Target}% -> applied {Applied}%",
                vm.DeviceName, req.ScalePercent == 0 ? "auto" : req.ScalePercent + "%", _hello.DensityDpi, target, applied);
        }
        catch (Exception ex) when (ex is not OperationCanceledException || !_cts.IsCancellationRequested)
        {
            _log.LogWarning("Display scale for {Dev} failed: {Msg}", vm.DeviceName, ex.Message);
        }
        _scaleApplied = applied;
        _scaledVm = vm;
        _scaledRequest = req.ScalePercent;
    }

    /// SETTINGS that only change scalePercent: re-apply on the attached monitor and resend CONFIG, keep the pipeline.
    /// (The DPI change may make desktop duplication report ACCESS_LOST once; the capture recreates it as usual.)
    private async Task ApplyScaleLiveAsync()
    {
        await _reconfigLock.WaitAsync().ConfigureAwait(false);
        try
        {
            if (_cts.IsCancellationRequested) return;
            var vdp = _host.VirtualDisplays;
            var cfg = _lastConfig;
            if (_vm == null || vdp == null || cfg == null || cfg.Mode == "mirror" || !_streamActive) return; // mirror: n/a
            var req = _requested.Clone();
            await EnsureScaleAsync(vdp, req);
            cfg.ScalePercent = _scaleApplied;
            _sender.EnqueueControl(Wire.FrameJson(MessageType.Config, cfg));
            _pipeline?.RequestKeyframe();
            if (Info != null)
            {
                Info = Info with { ScalePercent = _scaleApplied, ScaleAuto = req.ScalePercent == 0 };
                _host.OnSessionUpdated(this, Info);
            }
        }
        catch (Exception ex) when (!_cts.IsCancellationRequested)
        {
            _log.LogWarning(ex, "Live display scale change failed");
        }
        catch (Exception) { }
        finally { _reconfigLock.Release(); }
    }
}
