using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace PlexiChore.Engine.Streaming;

/// A display mode of a physical monitor (pixels, refresh rate).
public readonly record struct MonitorMode(int Width, int Height, int Hz)
{
    public double Aspect => Height > 0 ? (double)Width / Height : 0;
    public override string ToString() => $"{Width}x{Height}@{Hz}";
}

/// Pure mode choice for "mirror: match the tablet's shape" (unit-tested).
public static class MirrorAspectPlanner
{
    /// Relative aspect difference that still counts as "the same shape" (1680x1050 vs 2560x1600 = 0).
    public const double Tolerance = 0.02;
    /// Modes narrower than this are not worth it (text gets too big on the PC monitor).
    public const int MinWidth = 1024;

    public static bool SameShape(double a, double b) => a > 0 && b > 0 && Math.Abs(a - b) / b <= Tolerance;

    /// The mode to switch to, or null when the monitor already has the tablet's shape or offers no such mode.
    /// Picks the largest mode with the tablet's aspect that is not bigger than the current one (the current mode is
    /// normally the panel's native size; bigger modes are GPU super-resolution), and keeps the current refresh rate
    /// when that mode offers it, else the highest rate not above it.
    public static MonitorMode? Pick(IEnumerable<MonitorMode> modes, MonitorMode current, double tabletAspect)
    {
        if (tabletAspect < 1) tabletAspect = 1 / tabletAspect; // the PC desktop is landscape
        if (current.Width <= 0 || current.Height <= 0 || SameShape(current.Aspect, tabletAspect)) return null;
        var fits = modes.Where(m => m.Width >= MinWidth && m.Height > 0 && m.Width <= current.Width && m.Height <= current.Height
                                    && SameShape(m.Aspect, tabletAspect)).ToList();
        if (fits.Count == 0) return null;
        var size = fits.OrderByDescending(m => (long)m.Width * m.Height)
                       .ThenBy(m => Math.Abs(m.Aspect - tabletAspect)).First();
        var rates = fits.Where(m => m.Width == size.Width && m.Height == size.Height).Select(m => m.Hz).Distinct().ToList();
        int hz = rates.Contains(current.Hz) ? current.Hz
            : rates.Where(r => r <= current.Hz).DefaultIfEmpty(rates.Max()).Max();
        return size with { Hz = hz };
    }
}

/// Switches a physical monitor to the tablet's aspect ratio while it is mirrored, and back afterwards.
/// Ref-counted per monitor (two tablets mirroring the same monitor share one switch) with the same grace period as
/// virtual monitors, so a quick reconnect does not flip the resolution twice. The change is dynamic (not written to
/// Windows' saved layout, so a reboot also undoes it); the original mode is also kept in <see cref="_stateFile"/> so a
/// crash is undone at the next start (<see cref="RestorePending"/>).
internal sealed class MirrorAspectSwitcher
{
    private sealed class Entry
    {
        public required string Device;
        public required MonitorMode Original;
        public required MonitorMode Applied;
        public readonly HashSet<Guid> Holders = new();
        public CancellationTokenSource? Linger;
    }

    private sealed record StateRecord(string Device, int Width, int Height, int Hz);

    private readonly ILogger _log;
    private readonly object _lock = new();
    private readonly Dictionary<string, Entry> _entries = new(StringComparer.OrdinalIgnoreCase);
    private string? _stateFile;

    public MirrorAspectSwitcher(ILogger log) { _log = log; }

    /// Where the original modes are recorded (null = no crash record).
    public void SetStateFile(string? path) { lock (_lock) _stateFile = path; }

    /// Puts back modes recorded by a previous run that ended without restoring them (crash / kill).
    public void RestorePending()
    {
        List<StateRecord>? pending;
        lock (_lock)
        {
            if (_entries.Count > 0) return; // we are switching right now; the record is ours
            pending = LoadState();
        }
        if (pending == null || pending.Count == 0) return;
        foreach (var r in pending)
        {
            var current = Native.Current(r.Device);
            var original = new MonitorMode(r.Width, r.Height, r.Hz);
            if (current is { } c && c.Width == original.Width && c.Height == original.Height) continue;
            var rc = Native.Apply(r.Device, original);
            _log.LogInformation("Mirror aspect: restored {Dev} to {Mode} left over from the last run (result {Rc})", r.Device, original, rc);
        }
        lock (_lock) SaveState();
    }

    /// Switches <paramref name="device"/> to the tablet's shape for <paramref name="holder"/>. Returns true when the
    /// monitor's mode is now different from before the call (the caller re-reads the desktop bounds).
    public async Task<bool> AcquireAsync(Guid holder, string device, double tabletAspect, CancellationToken ct)
    {
        // a holder mirrors one monitor at a time
        foreach (var other in HeldBy(holder).Where(d => !string.Equals(d, device, StringComparison.OrdinalIgnoreCase)))
            await ReleaseOneAsync(holder, other, TimeSpan.Zero).ConfigureAwait(false);

        lock (_lock)
        {
            if (_entries.TryGetValue(device, out var e) && SameShapeMode(e.Applied, tabletAspect))
            {
                e.Linger?.Cancel(); e.Linger = null;
                e.Holders.Add(holder);
                return false; // already switched (other tablet, or reconnect within the grace period)
            }
            if (e != null && e.Holders.Any(h => h != holder))
            {
                _log.LogInformation("Mirror aspect: {Dev} is already switched to {Mode} for another tablet; leaving it", device, e.Applied);
                e.Holders.Add(holder);
                return false;
            }
        }
        // a lingering switch for another tablet shape: put the original back before picking again
        Entry? stale;
        lock (_lock) { _entries.Remove(device, out stale); stale?.Linger?.Cancel(); }
        if (stale != null) RestoreEntry(stale);

        var current = Native.Current(device);
        if (current == null) return false;
        var pick = MirrorAspectPlanner.Pick(Native.Modes(device), current.Value, tabletAspect);
        if (pick == null)
        {
            _log.LogInformation("Mirror aspect: {Dev} {Cur} already has the tablet's shape ({Aspect:0.000}) or offers no such mode; unchanged",
                device, current.Value, tabletAspect);
            return false;
        }

        var entry = new Entry { Device = device, Original = current.Value, Applied = pick.Value };
        entry.Holders.Add(holder);
        lock (_lock) { _entries[device] = entry; SaveState(); } // record first: a crash during the switch is undone too
        int rc = Native.Apply(device, pick.Value);
        if (rc != 0)
        {
            _log.LogWarning("Mirror aspect: switching {Dev} to {Mode} failed (ChangeDisplaySettingsEx {Rc}); unchanged", device, pick.Value, rc);
            lock (_lock) { _entries.Remove(device); SaveState(); }
            return false;
        }
        _log.LogInformation("Mirror aspect: {Dev} {From} -> {To} (tablet aspect {Aspect:0.000})", device, current.Value, pick.Value, tabletAspect);
        await WaitForModeAsync(device, pick.Value, ct).ConfigureAwait(false);
        return true;
    }

    /// Drops <paramref name="holder"/>'s claims; a monitor nobody holds goes back to its original mode after
    /// <paramref name="linger"/>.
    public async Task ReleaseAsync(Guid holder, TimeSpan linger)
    {
        foreach (var d in HeldBy(holder)) await ReleaseOneAsync(holder, d, linger).ConfigureAwait(false);
    }

    /// Restores every monitor now (server stop).
    public void RestoreAll()
    {
        List<Entry> all;
        lock (_lock) { all = _entries.Values.ToList(); _entries.Clear(); }
        foreach (var e in all) { e.Linger?.Cancel(); RestoreEntry(e); }
        lock (_lock) SaveState();
    }

    private List<string> HeldBy(Guid holder)
    {
        lock (_lock) return _entries.Values.Where(e => e.Holders.Contains(holder)).Select(e => e.Device).ToList();
    }

    private static bool SameShapeMode(MonitorMode m, double aspect) =>
        MirrorAspectPlanner.SameShape(m.Aspect, aspect < 1 ? 1 / aspect : aspect);

    private Task ReleaseOneAsync(Guid holder, string device, TimeSpan linger)
    {
        Entry? e;
        lock (_lock)
        {
            if (!_entries.TryGetValue(device, out e) || !e.Holders.Remove(holder) || e.Holders.Count > 0) return Task.CompletedTask;
            if (linger > TimeSpan.Zero)
            {
                var cts = new CancellationTokenSource();
                e.Linger = cts;
                _log.LogInformation("Mirror aspect: keeping {Dev} at {Mode} for {S:F0} s (fast reconnect)", device, e.Applied, linger.TotalSeconds);
                _ = LingerThenRestoreAsync(e, linger, cts.Token);
                return Task.CompletedTask;
            }
            _entries.Remove(device);
        }
        RestoreEntry(e);
        lock (_lock) SaveState();
        return Task.CompletedTask;
    }

    private async Task LingerThenRestoreAsync(Entry e, TimeSpan linger, CancellationToken ct)
    {
        try { await Task.Delay(linger, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }
        lock (_lock)
        {
            if (e.Holders.Count > 0 || e.Linger?.Token != ct || !_entries.TryGetValue(e.Device, out var cur) || cur != e) return;
            _entries.Remove(e.Device);
        }
        RestoreEntry(e);
        lock (_lock) SaveState();
    }

    private void RestoreEntry(Entry e)
    {
        var current = Native.Current(e.Device);
        if (current is { } c && (c.Width != e.Applied.Width || c.Height != e.Applied.Height))
        {
            // somebody (the user, Windows) changed it meanwhile: theirs wins
            _log.LogInformation("Mirror aspect: {Dev} is now {Cur}, not {Applied}; not restoring", e.Device, c, e.Applied);
            return;
        }
        int rc = Native.Apply(e.Device, e.Original);
        if (rc != 0)
        {
            rc = Native.ResetToSaved(e.Device); // Windows' saved mode = the original (we never write it)
            _log.LogWarning("Mirror aspect: restoring {Dev} to {Mode} failed; reset to the saved mode (result {Rc})", e.Device, e.Original, rc);
        }
        else _log.LogInformation("Mirror aspect: {Dev} restored to {Mode}", e.Device, e.Original);
    }

    private static async Task WaitForModeAsync(string device, MonitorMode mode, CancellationToken ct)
    {
        // the monitor re-syncs; DXGI reports the new size shortly after ChangeDisplaySettingsEx returns
        for (int i = 0; i < 30; i++)
        {
            try
            {
                var b = Capture.Monitors.Enumerate().FirstOrDefault(m => string.Equals(m.DeviceName, device, StringComparison.OrdinalIgnoreCase))?.Bounds;
                if (b is { } r && r.Width == mode.Width && r.Height == mode.Height) return;
            }
            catch { }
            await Task.Delay(100, ct).ConfigureAwait(false);
        }
    }

    // ---- crash record (call under _lock) ----
    private List<StateRecord>? LoadState()
    {
        try
        {
            return _stateFile != null && File.Exists(_stateFile)
                ? JsonSerializer.Deserialize<List<StateRecord>>(File.ReadAllText(_stateFile)) : null;
        }
        catch { return null; }
    }

    private void SaveState()
    {
        if (_stateFile == null) return;
        try
        {
            if (_entries.Count == 0) { if (File.Exists(_stateFile)) File.Delete(_stateFile); return; }
            Directory.CreateDirectory(Path.GetDirectoryName(_stateFile)!);
            var tmp = _stateFile + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(_entries.Values.Select(e =>
                new StateRecord(e.Device, e.Original.Width, e.Original.Height, e.Original.Hz)).ToList()));
            File.Move(tmp, _stateFile, overwrite: true);
        }
        catch (Exception ex) { _log.LogDebug("mirror aspect state: {Msg}", ex.Message); }
    }

    private static class Native
    {
        private const int ENUM_CURRENT_SETTINGS = -1;
        private const uint DM_BITSPERPEL = 0x00040000, DM_PELSWIDTH = 0x00080000, DM_PELSHEIGHT = 0x00100000, DM_DISPLAYFREQUENCY = 0x00400000;

        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct DEVMODE
        {
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
            public ushort dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra;
            public uint dmFields;
            public int dmPositionX, dmPositionY;
            public uint dmDisplayOrientation, dmDisplayFixedOutput;
            public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
            public ushort dmLogPixels;
            public uint dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
            public uint dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;

            public static DEVMODE Create() => new() { dmDeviceName = "", dmFormName = "", dmSize = (ushort)Marshal.SizeOf<DEVMODE>() };
        }

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "EnumDisplaySettingsExW")]
        private static extern bool EnumDisplaySettingsEx(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode, uint dwFlags);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
        private static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

        [DllImport("user32.dll", CharSet = CharSet.Unicode, EntryPoint = "ChangeDisplaySettingsExW")]
        private static extern int ChangeDisplaySettingsExNull(string lpszDeviceName, IntPtr lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

        public static MonitorMode? Current(string device)
        {
            var dm = DEVMODE.Create();
            if (!EnumDisplaySettingsEx(device, ENUM_CURRENT_SETTINGS, ref dm, 0) || dm.dmPelsWidth == 0) return null;
            return new MonitorMode((int)dm.dmPelsWidth, (int)dm.dmPelsHeight, (int)dm.dmDisplayFrequency);
        }

        public static List<MonitorMode> Modes(string device)
        {
            var set = new HashSet<MonitorMode>();
            for (int i = 0; i < 4000; i++)
            {
                var dm = DEVMODE.Create();
                if (!EnumDisplaySettingsEx(device, i, ref dm, 0)) break;
                if (dm.dmBitsPerPel is 0 or 32 && dm.dmDisplayOrientation == 0)
                    set.Add(new MonitorMode((int)dm.dmPelsWidth, (int)dm.dmPelsHeight, (int)dm.dmDisplayFrequency));
            }
            return set.ToList();
        }

        /// Dynamic mode change (no CDS_UPDATEREGISTRY): Windows' saved mode stays the user's own.
        public static int Apply(string device, MonitorMode mode)
        {
            var dm = DEVMODE.Create();
            dm.dmDeviceName = device;
            dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT | DM_BITSPERPEL;
            dm.dmPelsWidth = (uint)mode.Width;
            dm.dmPelsHeight = (uint)mode.Height;
            dm.dmBitsPerPel = 32;
            if (mode.Hz > 1) { dm.dmFields |= DM_DISPLAYFREQUENCY; dm.dmDisplayFrequency = (uint)mode.Hz; }
            return ChangeDisplaySettingsEx(device, ref dm, IntPtr.Zero, 0, IntPtr.Zero);
        }

        /// Back to the mode in Windows' saved settings.
        public static int ResetToSaved(string device) => ChangeDisplaySettingsExNull(device, IntPtr.Zero, IntPtr.Zero, 0, IntPtr.Zero);
    }
}
