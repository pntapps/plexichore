using System.Drawing;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using PlexiChore.App.Services;
using PlexiChore.Engine;

namespace PlexiChore.App.VirtualDisplay;

/// IVirtualDisplayProvider backed by the signed open-source Virtual Display Driver (IddCx, MIT).
///
/// Strategy: the driver keeps ONE virtual monitor plugged in permanently (monitors/count = 1) with a compact list of
/// tablet resolutions (read only at device start). Attaching = pick the best available mode, then mode-set + position
/// + attach it to the desktop with ChangeDisplaySettingsEx (no admin needed). Detaching = remove it from the desktop.
/// If the exact tablet size is missing the closest mode is used (Engine scales); adding a mode needs an elevated
/// device restart (VddInstaller.RepairAsync). The control pipe is never used for reloads (they crash the driver host).
public sealed class VirtualDisplayDriverProvider : IVirtualDisplayProvider, IDisposable
{
    private readonly ILogger<VirtualDisplayDriverProvider> _log;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly HashSet<string> _attachedByUs = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _stateFile = Path.Combine(AppPaths.LocalDir, "vdd-state.json");
    private readonly Func<string> _settingsPath;
    /// Pre-"primary" layout (see PrimaryRestoreRecord). Roaming dir = %APPDATA%\PlexiChore.
    private readonly string _restoreFile = Path.Combine(AppPaths.RoamingDir, "primary-restore.json");
    private volatile VddDeviceStatus _status = new(VddState.Unknown, null, null, 0, null);
    private Timer? _poll;
    /// Set while a virtual monitor is left on the desktop because it is the PC's only display (headless PC);
    /// the poll takes it off again once a real monitor shows up.
    private volatile bool _keptAsOnlyDisplay;

    public VirtualDisplayDriverProvider(ILogger<VirtualDisplayDriverProvider> log, Func<string>? settingsPath = null)
    {
        _log = log;
        _settingsPath = settingsPath ?? VddSettingsFile.ResolvePath;
        LoadState();
    }

    /// False when no real (non-VDD) monitor is attached to the desktop: the tablet then becomes the PC's monitor.
    public bool HasPhysicalMonitor
    {
        get
        {
            try { return AnyPhysicalAttached(excludeGdi: null); }
            catch (Exception ex) { _log.LogDebug(ex, "Physical monitor check failed"); return true; }
        }
    }

    private static bool AnyPhysicalAttached(string? excludeGdi)
    {
        var vddNames = VddGdiNames();
        if (excludeGdi != null) vddNames.Add(excludeGdi);
        return AttachedLayout(d => !vddNames.Contains(d.GdiName)).Count > 0;
    }

    /// True while the virtual monitor is (or may still be, after a crash) the Windows primary display.
    public bool HasPendingPrimaryRestore => File.Exists(_restoreFile);

    public static readonly TimeSpan AppearTimeout = TimeSpan.FromSeconds(8);
    public static readonly TimeSpan ApplyTimeout = TimeSpan.FromSeconds(4);

    public bool IsAvailable => _status.State == VddState.Ready;
    public VddDeviceStatus Status => _status;
    public string? LastError { get; private set; }
    public IReadOnlyCollection<string> ActiveMonitors { get { lock (_attachedByUs) return _attachedByUs.ToList(); } }

    public event EventHandler? StatusChanged;

    internal static bool IsVddIdentity(string? s) =>
        !string.IsNullOrEmpty(s) &&
        (s.Contains("MttVDD", StringComparison.OrdinalIgnoreCase) ||
         s.Contains("MTT1337", StringComparison.OrdinalIgnoreCase) ||
         s.Contains("Virtual Display Driver", StringComparison.OrdinalIgnoreCase) ||
         s.Contains("VDD by MTT", StringComparison.OrdinalIgnoreCase));

    /// Set when the last attach could not get the tablet's exact size (UI offers "Add this tablet's resolution").
    public ModeFallback? LastModeFallback { get; private set; }

    public sealed record ModeFallback(int RequestedWidth, int RequestedHeight, DisplayMode Used);

    public void ClearModeFallback() => LastModeFallback = null;

    /// Return true while a tablet session is using the virtual monitor; stray monitors are only detached when false.
    public Func<bool>? HasActiveSessions { get; set; }

    public void StartMonitoring()
    {
        _poll ??= new Timer(async _ => await PollAsync(), null, TimeSpan.Zero, TimeSpan.FromSeconds(15));
    }

    private async Task PollAsync()
    {
        var before = _status;
        var now = await RefreshAsync();
        if (_keptAsOnlyDisplay && HasPhysicalMonitor)
        {
            _log.LogInformation("A physical monitor is attached now");
            _keptAsOnlyDisplay = false;
            await DetachStrayAsync();
            return;
        }
        // Safety net: no tablet is connected, a real monitor is there, but a virtual monitor is still on the desktop
        // (e.g. an earlier detach was refused) — the user would see a missing desktop/taskbar. Take it off.
        if (now.MonitorPresent && HasActiveSessions?.Invoke() != true && VirtualOnDesktopBesidePhysical())
        {
            _log.LogInformation("Virtual monitor is on the desktop without a tablet session");
            await DetachStrayAsync();
            return;
        }
        // The monitor (re)arrived — device restart, driver recovery, Windows update… Windows auto-extends onto it;
        // take it off the desktop again unless a tablet is using it.
        if (before.MonitorPresent || !now.MonitorPresent || before.State == VddState.Unknown) return;
        _log.LogInformation("Virtual monitor arrived");
        await DetachStrayAsync();
    }

    private static bool VirtualOnDesktopBesidePhysical()
    {
        try
        {
            var vddNames = VddGdiNames();
            var attached = Displays.Enumerate().Where(d => d.AttachedToDesktop).ToList();
            return attached.Any(d => vddNames.Contains(d.GdiName)) && attached.Any(d => !vddNames.Contains(d.GdiName));
        }
        catch { return false; }
    }

    /// Detaches VDD monitors that are on the desktop although no tablet session uses them (no-op otherwise).
    public async Task DetachStrayAsync()
    {
        if (HasActiveSessions?.Invoke() == true) return;
        lock (_attachedByUs) if (_attachedByUs.Count > 0) return;
        if (!await _gate.WaitAsync(0)) return; // an attach/detach is running
        try
        {
            foreach (var d in FindVddDisplays().Where(d => d.AttachedToDesktop))
            {
                if (!AnyPhysicalAttached(d.GdiName))
                {
                    _log.LogInformation("Keeping virtual monitor {Gdi} on the desktop: no physical monitor is attached", d.GdiName);
                    _keptAsOnlyDisplay = true;
                    continue;
                }
                _log.LogInformation("Detaching unused virtual monitor {Gdi}", d.GdiName);
                await DetachCoreAsync(d.GdiName);
            }
        }
        catch (Exception ex) { _log.LogWarning(ex, "Stray detach failed"); }
        finally { _gate.Release(); }
    }

    public async Task<VddDeviceStatus> RefreshAsync()
    {
        try
        {
            var s = await VddDeviceDetector.DetectAsync();
            if (s.State == VddState.Ready) s = s.WithMonitor(await Task.Run(() => VddMonitorPresent(s.InstanceId)));
            var changed = s != _status;
            _status = s;
            if (changed)
            {
                if (s.State == VddState.NeedsRepair) _log.LogWarning("VDD adapter {Id} is running but has no virtual monitor", s.InstanceId);
                StatusChanged?.Invoke(this, EventArgs.Empty);
            }
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "VDD detection failed");
        }
        return _status;
    }

    /// True if the VDD adapter has a connected monitor: a GDI child monitor of a VDD source, or an available
    /// DisplayConfig target on the VDD adapter (adapter path contains the instance id, e.g. ROOT#DISPLAY#0000).
    public static bool VddMonitorPresent(string? instanceId)
    {
        try
        {
            if (FindVddDisplays().Any(d => d.MonitorId.Length > 0)) return true;
            var inst = string.IsNullOrEmpty(instanceId) ? null : instanceId.Replace('\\', '#');
            return Displays.QueryAvailableTargets().Any(t =>
                IsVddIdentity(t.MonitorPath) || IsVddIdentity(t.MonitorName) || IsVddIdentity(t.AdapterPath) ||
                (inst != null && t.AdapterPath.Contains(inst, StringComparison.OrdinalIgnoreCase)));
        }
        catch { return false; }
    }

    /// Current VDD sources. Prefers DisplayConfig adapter paths (reliable for IddCx), falls back to GDI strings.
    public static List<DisplayInfo> FindVddDisplays()
    {
        var all = Displays.Enumerate();
        Dictionary<string, (string AdapterPath, string MonitorPath, string MonitorName)> active;
        try { active = Displays.QueryActiveSources(); } catch { active = new(); }
        return all.Where(d =>
                d.LooksLikeVdd ||
                (active.TryGetValue(d.GdiName, out var a) &&
                 (IsVddIdentity(a.AdapterPath) || IsVddIdentity(a.MonitorPath) || IsVddIdentity(a.MonitorName))))
            .ToList();
    }

    private static DisplayInfo? PickVddSource(List<DisplayInfo> vdd) =>
        vdd.FirstOrDefault(d => d.AttachedToDesktop && d.MonitorId.Length > 0)
        ?? vdd.FirstOrDefault(d => d.MonitorId.Length > 0)
        ?? vdd.FirstOrDefault();

    public Task<VirtualMonitor?> AttachAsync(int width, int height, int refreshHz, string position, CancellationToken ct = default) =>
        AttachCoreAsync(width, height, refreshHz, position, makePrimary: false, ct);

    /// "primary" mode: attach beside the current primary on <paramref name="position"/>, then make the virtual monitor
    /// the primary display (all monitors shifted so it sits at 0,0). The original layout is persisted first and put back
    /// by DetachAsync / DetachAllOwnedAsync (also after a crash, at the next start).
    public Task<VirtualMonitor?> AttachAsync(int width, int height, int refreshHz, string position, bool makePrimary, CancellationToken ct = default) =>
        AttachCoreAsync(width, height, refreshHz, position, makePrimary, ct);

    private async Task<VirtualMonitor?> AttachCoreAsync(int width, int height, int refreshHz, string position, bool makePrimary, CancellationToken ct)
    {
        await _gate.WaitAsync(ct);
        try
        {
            LastError = null;
            if (!IsAvailable) await RefreshAsync();
            if (!IsAvailable)
            {
                LastError = _status.State == VddState.NotInstalled
                    ? "Virtual Display Driver is not installed."
                    : _status.Detail ?? "Virtual Display Driver is not ready.";
                _log.LogWarning("Attach refused: {Err}", LastError);
                return null;
            }

            var (w, h) = DisplayLayout.Sanitize(width, height);
            var hz = Math.Clamp(refreshHz <= 0 ? 60 : refreshHz, 24, 240);
            _log.LogInformation("Attach requested {W}x{H}@{Hz} {Pos}{Primary}", w, h, hz, position, makePrimary ? " as PRIMARY" : "");

            // 1) find the (permanently connected) virtual monitor. Its mode list is fixed at device start: we never
            //    edit vdd_settings.xml or ask the driver to reload here (pipe reload commands crash the driver host).
            var vdd = PickVddSource(FindVddDisplays())
                      ?? await WaitForAsync(() => PickVddSource(FindVddDisplays()), AppearTimeout, ct);
            if (vdd == null)
            {
                LastError = "The virtual monitor did not appear. Open Extended display and click Repair (admin).";
                _log.LogWarning(LastError);
                return null;
            }

            // 2) choose the best available mode (Engine scales the stream if it is not exact)
            var modes = Displays.GetModes(vdd.GdiName);
            var (ow, oh, swapped) = DisplayLayout.OrientForModes(modes, w, h);
            if (swapped)
            {
                _log.LogInformation("Portrait {W}x{H} requested but the driver has no portrait modes; using landscape. " +
                                    "Add the tablet's portrait resolution ({W}x{H}) on the Extended display page to get a portrait monitor.", w, h, w, h);
                (w, h) = (ow, oh);
            }
            var mode = DisplayLayout.ChooseMode(modes, w, h, hz) ?? new DisplayMode(w, h, hz);
            if (mode.Width != w || mode.Height != h)
            {
                _log.LogInformation("Exact mode {W}x{H} is not in the driver's mode list ({N} modes); using {M}. " +
                                    "Use \"Add this tablet's resolution\" on the Extended display page to add it.", w, h, modes.Count, mode);
                LastModeFallback = new ModeFallback(w, h, mode);
            }
            else LastModeFallback = null;

            // 2b) primary mode: persist the user's layout BEFORE touching anything (crash safety)
            if (makePrimary && !SaveRestoreRecord(vdd.GdiName))
            {
                LastError = "Could not save the current display layout; refusing to change the primary display.";
                _log.LogWarning(LastError);
                return null;
            }

            // 3) position relative to the primary monitor and apply
            var bounds = await ApplyAsync(vdd.GdiName, mode, position, ct);
            if (bounds == null)
            {
                // Some systems need the topology switched to "extend" first (e.g. if the user set "PC screen only").
                _log.LogInformation("Attach via CDS failed, trying SetDisplayConfig(EXTEND)");
                Displays.ExtendTopology();
                await Task.Delay(1500, ct);
                vdd = PickVddSource(FindVddDisplays()) ?? vdd;
                bounds = await ApplyAsync(vdd.GdiName, mode, position, ct);
            }
            if (bounds == null)
            {
                LastError ??= "Windows refused to enable the virtual monitor.";
                if (makePrimary) PrimaryRestoreRecord.Delete(_restoreFile); // nothing was changed that needs undoing
                return null;
            }

            lock (_attachedByUs) _attachedByUs.Add(vdd.GdiName);
            SaveState();

            // 4) primary mode: shift every monitor so the virtual one is at 0,0 and flag it primary
            if (makePrimary)
            {
                // not cancellable midway: a half-applied primary switch must always be undone by us
                var primaryBounds = await MakePrimaryAsync(vdd.GdiName);
                if (ct.IsCancellationRequested)
                {
                    await DetachCoreAsync(vdd.GdiName);
                    ct.ThrowIfCancellationRequested();
                }
                if (primaryBounds == null)
                {
                    LastError ??= "Windows refused to make the virtual monitor the primary display.";
                    _log.LogWarning("Primary switch failed; restoring the original layout and detaching");
                    await DetachCoreAsync(vdd.GdiName);
                    return null;
                }
                bounds = primaryBounds;
            }
            StatusChanged?.Invoke(this, EventArgs.Empty);
            _log.LogInformation("Virtual monitor {Name} attached at {Bounds}", vdd.GdiName, bounds);
            return new VirtualMonitor(vdd.GdiName, bounds.Value);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            LastError = ex.Message;
            _log.LogError(ex, "AttachAsync failed");
            return null;
        }
        finally { _gate.Release(); }
    }

    private async Task<Rectangle?> ApplyAsync(string gdi, DisplayMode mode, string position, CancellationToken ct)
    {
        var displays = Displays.Enumerate();
        var primary = displays.FirstOrDefault(d => d.IsPrimary && d.AttachedToDesktop)?.Bounds
                      ?? displays.FirstOrDefault(d => d.AttachedToDesktop && d.GdiName != gdi)?.Bounds
                      ?? new Rectangle(0, 0, 1920, 1080);
        var others = displays.Where(d => d.AttachedToDesktop && !string.Equals(d.GdiName, gdi, StringComparison.OrdinalIgnoreCase))
            .Select(d => d.Bounds).Where(b => !b.IsEmpty).ToList();
        // the only display (headless PC) sits at the desktop origin
        var pos = others.Count == 0 ? Point.Empty : DisplayLayout.ComputePosition(primary, others, mode.Width, mode.Height, position);

        var r = Displays.StageModeAndPosition(gdi, mode, pos);
        if (r != DisplayNative.DISP_CHANGE_SUCCESSFUL && mode.Hz > 0)
            r = Displays.StageModeAndPosition(gdi, mode with { Hz = 0 }, pos);
        if (r != DisplayNative.DISP_CHANGE_SUCCESSFUL)
        {
            LastError = $"ChangeDisplaySettingsEx failed ({DescribeDispChange(r)}).";
            _log.LogWarning("Stage {Gdi} {Mode} at {Pos}: {R}", gdi, mode, pos, r);
            return null;
        }
        var a = Displays.ApplyStaged();
        if (a != DisplayNative.DISP_CHANGE_SUCCESSFUL)
        {
            LastError = $"Applying display settings failed ({DescribeDispChange(a)}).";
            _log.LogWarning("Apply: {R}", a);
            return null;
        }
        var expected = new Size(mode.Width, mode.Height);
        var bounds = await WaitForAsync(() =>
        {
            var d = Displays.Enumerate().FirstOrDefault(x => string.Equals(x.GdiName, gdi, StringComparison.OrdinalIgnoreCase));
            return d is { AttachedToDesktop: true } && !d.Bounds.IsEmpty && d.Bounds.Size == expected ? (Rectangle?)d.Bounds : null;
        }, ApplyTimeout, ct);
        // Accept whatever Windows ended up with if it is attached (e.g. a slightly different mode).
        return bounds ?? Displays.Enumerate().FirstOrDefault(x => x.GdiName == gdi && x.AttachedToDesktop && !x.Bounds.IsEmpty)?.Bounds;
    }

    public async Task DetachAsync(VirtualMonitor monitor)
    {
        await _gate.WaitAsync();
        try { await DetachCoreAsync(monitor.DeviceName); }
        finally { _gate.Release(); }
    }

    public static readonly TimeSpan ScaleSettleTimeout = TimeSpan.FromSeconds(3);

    /// Display scale last applied per virtual monitor GDI name (for the Display page).
    public IReadOnlyDictionary<string, int> AppliedScales { get { lock (_scales) return new Dictionary<string, int>(_scales); } }
    private readonly Dictionary<string, int> _scales = new(StringComparer.OrdinalIgnoreCase);

    /// Sets the Windows display scale of the VIRTUAL monitor (never a physical one: the GDI name must be a VDD source
    /// that is attached to the desktop). Uses DisplayConfig GET/SET_DPI_SCALE on the source's adapter+id, clamps to the
    /// monitor's allowed range, then waits until Windows reports the new value. Returns the scale in effect, 0 on failure.
    public async Task<int> SetScaleAsync(VirtualMonitor monitor, int scalePercent, int tabletDensityDpi, CancellationToken ct = default)
    {
        await _gate.WaitAsync(ct);
        try
        {
            var gdi = monitor.DeviceName;
            if (!FindVddDisplays().Any(d => d.AttachedToDesktop && string.Equals(d.GdiName, gdi, StringComparison.OrdinalIgnoreCase)))
            {
                _log.LogWarning("Display scale: {Gdi} is not an attached virtual monitor; not touching it", gdi);
                return 0;
            }
            if (!Displays.TryFindActiveSource(gdi, out var adapter, out var source))
            {
                _log.LogWarning("Display scale: no active DisplayConfig source for {Gdi}", gdi);
                return 0;
            }
            // the source can need a moment after an attach / primary switch before GET_DPI_SCALE answers
            var range = Displays.GetDpiScale(adapter, source)
                        ?? await WaitForAsync(() => Displays.GetDpiScale(adapter, source), TimeSpan.FromSeconds(2), ct);
            if (range == null)
            {
                _log.LogWarning("Display scale: GET_DPI_SCALE failed for {Gdi}", gdi);
                return 0;
            }
            var r = range.Value;
            int wanted = scalePercent > 0 ? scalePercent : DisplayScale.Auto(tabletDensityDpi);
            int target = DisplayScale.ClampToRange(wanted, r);
            _log.LogInformation("Display scale {Gdi}: now {Cur}% (recommended {Rec}%, allowed {Min}-{Max}%), wanted {Want}% -> {Target}%",
                gdi, r.Current, r.Recommended, r.Min, r.Max, wanted, target);
            if (target != r.Current)
            {
                var rel = DisplayScale.ToRelative(target, r.Recommended);
                if (rel == null) return Remember(gdi, r.Current);
                var err = Displays.SetDpiScaleRelative(adapter, source, rel.Value);
                if (err != 0)
                {
                    _log.LogWarning("Display scale: SET_DPI_SCALE {Rel} on {Gdi} failed ({Err})", rel.Value, gdi, err);
                    return Remember(gdi, r.Current);
                }
            }
            // wait until both DisplayConfig and the monitor's effective DPI reflect it (apps re-layout on WM_DPICHANGED)
            var bounds = Displays.GetCurrentBounds(gdi) ?? monitor.DesktopBounds;
            var settled = await WaitForAsync(() =>
            {
                var now = Displays.GetDpiScale(adapter, source);
                if (now?.Current != target) return null;
                var eff = Displays.EffectiveScalePercent(bounds);
                return eff == 0 || eff == target ? (int?)target : null;
            }, ScaleSettleTimeout, ct);
            var final = settled ?? Displays.GetDpiScale(adapter, source)?.Current ?? 0;
            if (settled == null) _log.LogInformation("Display scale {Gdi}: settled check timed out, reporting {Final}%", gdi, final);
            return Remember(gdi, final);
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "SetScaleAsync failed");
            return 0;
        }
        finally { _gate.Release(); }
    }

    private int Remember(string gdi, int percent)
    {
        lock (_scales) { if (percent > 0) _scales[gdi] = percent; else _scales.Remove(gdi); }
        StatusChanged?.Invoke(this, EventArgs.Empty);
        return percent;
    }

    private async Task DetachCoreAsync(string gdi)
    {
        try
        {
            var record = PrimaryRestoreRecord.Load(_restoreFile);
            if (!AnyPhysicalAttached(gdi))
            {
                // headless PC: taking the only display away would leave Windows with no desktop at all. Keep it; the
                // poll detaches it once a real monitor is plugged in. Keep the restore record too: a monitor that only
                // went to sleep comes back, and then its original layout must be put back.
                _log.LogInformation("Keeping virtual monitor {Gdi} attached: it is the only display", gdi);
                _keptAsOnlyDisplay = true;
                return;
            }
            _log.LogInformation("Detaching virtual monitor {Gdi}", gdi);
            // Primary mode: put the original primary + positions back in the SAME batch as the detach, so Windows never
            // has to pick a primary itself.
            if (record != null) StageRestore(record, excludeGdi: gdi);
            var r = Displays.StageDetach(gdi);
            if (r == DisplayNative.DISP_CHANGE_SUCCESSFUL || record != null)
            {
                var a = Displays.ApplyStaged();
                if (a != DisplayNative.DISP_CHANGE_SUCCESSFUL) _log.LogWarning("Detach apply: {R}", DescribeDispChange(a));
            }
            if (r != DisplayNative.DISP_CHANGE_SUCCESSFUL) _log.LogWarning("Detach stage failed: {R}", r);
            await WaitForAsync(() =>
            {
                var d = Displays.Enumerate().FirstOrDefault(x => x.GdiName == gdi);
                return d == null || !d.AttachedToDesktop ? (object)true : null;
            }, ApplyTimeout, CancellationToken.None);
            if (record != null) await FinishRestoreAsync(record);
            await EnsureVirtualOffAsync(gdi, record?.OriginalPrimary?.GdiName);
        }
        catch (Exception ex) { _log.LogWarning(ex, "Detach failed"); }
        finally
        {
            lock (_attachedByUs) _attachedByUs.Remove(gdi);
            SaveState();
            StatusChanged?.Invoke(this, EventArgs.Empty);
        }
    }

    /// Verifies a detach actually took effect. If the virtual monitor is still on the desktop, or a virtual monitor is
    /// still the primary display, the staged (registry) path was refused — Windows' saved layout can be inconsistent
    /// after a headless primary session, and then every staged change fails with DISP_CHANGE_FAILED. Fall back to
    /// immediate changes: a physical monitor (the original primary if known) becomes primary, the virtual one is
    /// removed, and the result is saved as Windows' layout so later staged changes work again.
    private async Task EnsureVirtualOffAsync(string gdi, string? preferredPrimary)
    {
        var vddNames = VddGdiNames();
        vddNames.Add(gdi);
        var displays = Displays.Enumerate();
        bool stillAttached = displays.Any(d => d.AttachedToDesktop && string.Equals(d.GdiName, gdi, StringComparison.OrdinalIgnoreCase));
        bool virtualPrimary = displays.Any(d => d.AttachedToDesktop && d.IsPrimary && vddNames.Contains(d.GdiName));
        if (!stillAttached && !virtualPrimary) return;
        var physical = displays.Where(d => d.AttachedToDesktop && !d.Bounds.IsEmpty && !vddNames.Contains(d.GdiName)).ToList();
        if (physical.Count == 0) return; // headless: the virtual monitor has to stay

        _log.LogWarning("Virtual monitor {Gdi} is still {State} after detaching; applying the fallback", gdi,
            virtualPrimary ? "the primary display" : "on the desktop");
        if (virtualPrimary)
        {
            var target = physical.FirstOrDefault(d => string.Equals(d.GdiName, preferredPrimary, StringComparison.OrdinalIgnoreCase))
                         ?? physical.OrderBy(d => Math.Abs((long)d.Bounds.X) + Math.Abs((long)d.Bounds.Y)).First();
            var r = Displays.SetPrimaryNow(target.GdiName);
            _log.LogInformation("Fallback: {Gdi} primary: {R}", target.GdiName, DescribeDispChange(r));
        }
        foreach (var v in Displays.Enumerate().Where(d => d.AttachedToDesktop && vddNames.Contains(d.GdiName)))
        {
            var r = Displays.DetachNow(v.GdiName);
            _log.LogInformation("Fallback: detach {Gdi}: {R}", v.GdiName, DescribeDispChange(r));
        }
        var done = await WaitForAsync(() =>
        {
            var now = Displays.Enumerate();
            return now.Any(d => d.AttachedToDesktop && vddNames.Contains(d.GdiName)) ||
                   !now.Any(d => d.AttachedToDesktop && d.IsPrimary) ? null : (object)true;
        }, ApplyTimeout, CancellationToken.None);
        var s = Displays.SaveActiveConfig();
        var primary = Displays.Enumerate().FirstOrDefault(d => d.IsPrimary && d.AttachedToDesktop);
        _log.Log(done != null ? LogLevel.Information : LogLevel.Warning,
            "Fallback {Result}: primary {P}, layout saved: {S}", done != null ? "done" : "incomplete", primary?.GdiName ?? "?", s);
    }

    /// Detaches virtual monitors this app attached (used at startup after a crash, and at exit). Also undoes a
    /// "primary" switch left behind by a crash (restore record in %APPDATA%\PlexiChore).
    public async Task DetachAllOwnedAsync()
    {
        List<string> owned;
        lock (_attachedByUs) owned = _attachedByUs.ToList();
        var pendingRestore = HasPendingPrimaryRestore;
        if (owned.Count == 0 && !pendingRestore) return;
        await _gate.WaitAsync();
        try
        {
            var vdd = FindVddDisplays();
            foreach (var g in owned)
                if (vdd.Any(v => v.GdiName == g && v.AttachedToDesktop)) await DetachCoreAsync(g);
                else lock (_attachedByUs) _attachedByUs.Remove(g);
            SaveState();

            var record = PrimaryRestoreRecord.Load(_restoreFile);
            if (record != null)
            {
                _log.LogInformation("Pending primary-display restore found (from {When:u})", record.CreatedUtc);
                var stillAttached = FindVddDisplays().FirstOrDefault(v => v.AttachedToDesktop &&
                    string.Equals(v.GdiName, record.VirtualGdiName, StringComparison.OrdinalIgnoreCase));
                if (stillAttached != null) await DetachCoreAsync(stillAttached.GdiName); // restores in the same batch
                else await FinishRestoreAsync(record);                                    // VM already gone
            }
            else if (pendingRestore) PrimaryRestoreRecord.Delete(_restoreFile); // unreadable record
        }
        finally { _gate.Release(); }
    }

    // ---------------- primary mode ----------------

    private static List<MonitorPlacement> AttachedLayout(Func<DisplayInfo, bool>? filter = null) =>
        Displays.Enumerate().Where(d => d.AttachedToDesktop && !d.Bounds.IsEmpty && (filter == null || filter(d)))
            .Select(MonitorPlacement.From).ToList();

    private static HashSet<string> VddGdiNames() =>
        FindVddDisplays().Select(d => d.GdiName).ToHashSet(StringComparer.OrdinalIgnoreCase);

    /// Persists the current (pre-switch) layout of the physical monitors. Keeps an existing record: that one holds the
    /// true original (e.g. a crash happened and recovery has not run yet).
    private bool SaveRestoreRecord(string vddGdi)
    {
        try
        {
            if (PrimaryRestoreRecord.Load(_restoreFile) is { } existing)
            {
                _log.LogInformation("Keeping existing primary restore record from {When:u}", existing.CreatedUtc);
                return true;
            }
            var vddNames = VddGdiNames();
            vddNames.Add(vddGdi);
            var physical = AttachedLayout(d => !vddNames.Contains(d.GdiName));
            if (physical.Count == 0)
            {
                // headless PC: the virtual monitor will be the only display, so there is no layout to put back
                _log.LogInformation("No physical monitor attached; primary mode needs no restore record");
                return true;
            }
            if (!physical.Any(p => p.IsPrimary))
            {
                // primary is currently a virtual monitor (unexpected): treat the physical one closest to 0,0 as original
                var best = physical.OrderBy(p => Math.Abs((long)p.X) + Math.Abs((long)p.Y)).First();
                physical = physical.Select(p => p == best ? p with { IsPrimary = true } : p).ToList();
            }
            var record = new PrimaryRestoreRecord(PrimaryRestoreRecord.CurrentVersion, DateTime.UtcNow, vddGdi, physical);
            record.Save(_restoreFile);
            _log.LogInformation("Saved primary restore record: primary {P}, {N} monitor(s)", record.OriginalPrimary!.GdiName, physical.Count);
            return true;
        }
        catch (Exception ex)
        {
            _log.LogWarning(ex, "Could not save primary restore record");
            return false;
        }
    }

    /// Makes <paramref name="gdi"/> the primary display: every attached monitor is shifted by the same offset so it
    /// lands at (0,0) (relative arrangement preserved), staged with CDS_SET_PRIMARY on the new primary, then applied.
    /// Returns the virtual monitor's bounds after the switch (0,0,w,h) or null.
    private async Task<Rectangle?> MakePrimaryAsync(string gdi)
    {
        var layout = AttachedLayout();
        if (!layout.Any(m => string.Equals(m.GdiName, gdi, StringComparison.OrdinalIgnoreCase))) return null;
        var plan = PrimaryLayout.ShiftToPrimary(layout, gdi);
        _log.LogInformation("Primary switch plan: {Plan}", string.Join(", ", plan.Select(p => $"{p.GdiName}@{p.X},{p.Y}{(p.IsPrimary ? "*" : "")}")));

        // new primary first, then the others (all CDS_NORESET; one apply at the end)
        foreach (var p in plan.OrderByDescending(p => p.IsPrimary))
        {
            var r = Displays.StagePosition(p.GdiName, p.Location, p.IsPrimary);
            if (r != DisplayNative.DISP_CHANGE_SUCCESSFUL)
            {
                LastError = $"Staging {p.GdiName} for primary switch failed ({DescribeDispChange(r)}).";
                _log.LogWarning(LastError);
                return null;
            }
        }
        var a = Displays.ApplyStaged();
        if (a != DisplayNative.DISP_CHANGE_SUCCESSFUL)
        {
            LastError = $"Applying the primary switch failed ({DescribeDispChange(a)}).";
            _log.LogWarning(LastError);
            return null;
        }
        // all desktop coordinates moved: re-query instead of trusting the plan
        return await WaitForAsync(() =>
        {
            var d = Displays.Enumerate().FirstOrDefault(x => string.Equals(x.GdiName, gdi, StringComparison.OrdinalIgnoreCase));
            return d is { AttachedToDesktop: true, IsPrimary: true } && d.Bounds.Location == Point.Empty ? (Rectangle?)d.Bounds : null;
        }, ApplyTimeout, CancellationToken.None);
    }

    /// Stages (CDS_NORESET) the original positions + primary flag for the physical monitors. Caller applies.
    private bool StageRestore(PrimaryRestoreRecord record, string? excludeGdi)
    {
        var vddNames = VddGdiNames();
        if (excludeGdi != null) vddNames.Add(excludeGdi);
        var physical = AttachedLayout(d => !vddNames.Contains(d.GdiName));
        var plan = PrimaryLayout.PlanRestore(record, physical);
        if (plan == null)
        {
            _log.LogWarning("Original primary {P} is no longer attached; letting Windows choose", record.OriginalPrimary?.GdiName);
            return false;
        }
        _log.LogInformation("Restoring layout: {Plan}", string.Join(", ", plan.Select(p => $"{p.GdiName}@{p.X},{p.Y}{(p.IsPrimary ? "*" : "")}")));
        var ok = true;
        foreach (var p in plan.OrderByDescending(p => p.IsPrimary))
        {
            var r = Displays.StagePosition(p.GdiName, p.Location, p.IsPrimary);
            if (r != DisplayNative.DISP_CHANGE_SUCCESSFUL) { ok = false; _log.LogWarning("Stage restore {Gdi}: {R}", p.GdiName, DescribeDispChange(r)); }
        }
        return ok;
    }

    /// After the virtual monitor is gone: verify the original layout is back; if Windows re-arranged things (or the
    /// combined apply was refused) apply the restore on its own once more. Then drop the record.
    private async Task FinishRestoreAsync(PrimaryRestoreRecord record)
    {
        try
        {
            var vddNames = VddGdiNames();
            var physical = AttachedLayout(d => !vddNames.Contains(d.GdiName));
            var plan = PrimaryLayout.PlanRestore(record, physical);
            if (plan != null && !PrimaryLayout.IsSatisfied(plan, physical))
            {
                _log.LogInformation("Original layout not in place yet; re-applying restore");
                if (StageRestore(record, excludeGdi: null))
                {
                    var a = Displays.ApplyStaged();
                    if (a != DisplayNative.DISP_CHANGE_SUCCESSFUL) _log.LogWarning("Restore apply: {R}", DescribeDispChange(a));
                    await WaitForAsync(() =>
                    {
                        var now = AttachedLayout(d => !vddNames.Contains(d.GdiName));
                        return PrimaryLayout.IsSatisfied(plan, now) ? (object)true : null;
                    }, ApplyTimeout, CancellationToken.None);
                }
            }
            var primary = Displays.Enumerate().FirstOrDefault(d => d.IsPrimary && d.AttachedToDesktop);
            _log.LogInformation("Primary display after restore: {P}", primary?.GdiName ?? "?");
        }
        catch (Exception ex) { _log.LogWarning(ex, "Primary restore failed"); }
        finally { PrimaryRestoreRecord.Delete(_restoreFile); }
    }

    /// After a fresh install Windows auto-extends onto the new monitor; take it off the desktop until a tablet needs it.
    public async Task DetachAllVddAsync()
    {
        await _gate.WaitAsync();
        try
        {
            foreach (var d in FindVddDisplays().Where(d => d.AttachedToDesktop)) await DetachCoreAsync(d.GdiName);
        }
        finally { _gate.Release(); }
    }

    private static async Task<T?> WaitForAsync<T>(Func<T?> probe, TimeSpan timeout, CancellationToken ct) where T : class
    {
        var until = DateTime.UtcNow + timeout;
        while (true)
        {
            var v = probe();
            if (v != null) return v;
            if (DateTime.UtcNow > until) return null;
            await Task.Delay(250, ct);
        }
    }

    private static async Task<T?> WaitForAsync<T>(Func<T?> probe, TimeSpan timeout, CancellationToken ct, int _ = 0) where T : struct
    {
        var until = DateTime.UtcNow + timeout;
        while (true)
        {
            var v = probe();
            if (v != null) return v;
            if (DateTime.UtcNow > until) return null;
            await Task.Delay(250, ct);
        }
    }

    internal static string DescribeDispChange(int r) => r switch
    {
        0 => "ok",
        1 => "restart required",
        -1 => "the display driver failed the mode",
        -2 => "mode not supported",
        -3 => "unable to write registry",
        -4 => "bad flags",
        -5 => "bad parameters",
        -6 => "bad dual-view",
        _ => $"code {r}",
    };

    private sealed record State(List<string> Attached);

    private void LoadState()
    {
        try
        {
            if (!File.Exists(_stateFile)) return;
            var s = JsonSerializer.Deserialize<State>(File.ReadAllText(_stateFile));
            if (s?.Attached != null) lock (_attachedByUs) foreach (var a in s.Attached) _attachedByUs.Add(a);
        }
        catch { }
    }

    private void SaveState()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_stateFile)!);
            List<string> list;
            lock (_attachedByUs) list = _attachedByUs.ToList();
            File.WriteAllText(_stateFile, JsonSerializer.Serialize(new State(list)));
        }
        catch { }
    }

    public void Dispose()
    {
        _poll?.Dispose();
        _gate.Dispose();
    }
}
