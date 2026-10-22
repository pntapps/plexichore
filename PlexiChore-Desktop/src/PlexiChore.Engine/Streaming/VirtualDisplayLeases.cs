using Microsoft.Extensions.Logging;

namespace PlexiChore.Engine.Streaming;

/// Reference-counted, lingering virtual monitors on top of the App's provider (the provider itself is unchanged).
///
/// * Two sessions asking for the same monitor (tablet reconnecting while the old session is still being torn down)
///   share it instead of the old session's cleanup detaching the monitor the new session just got
///   (that race made a reconnect fail with DXGI_ERROR_MODE_CHANGE_IN_PROGRESS and fall back to mirror).
/// * A session that ends unexpectedly (Wi-Fi drop, app switch, timeout) keeps the monitor attached for a short grace
///   period, so the reconnect skips the multi-second attach / mode change and windows stay where they were.
internal sealed class VirtualDisplayLeases : IVirtualDisplayProvider
{
    private sealed class Entry
    {
        public required (int w, int h, int hz, string pos, bool primary) Key;
        public required Task<VirtualMonitor?> Attach;
        public int Refs;
        public CancellationTokenSource? Linger;
    }

    private readonly IVirtualDisplayProvider _inner;
    private readonly ILogger _log;
    private readonly object _lock = new();
    private readonly List<Entry> _entries = new();

    public VirtualDisplayLeases(IVirtualDisplayProvider inner, ILogger log) { _inner = inner; _log = log; }

    public bool IsAvailable => _inner.IsAvailable;

    public bool HasPhysicalMonitor => _inner.HasPhysicalMonitor;

    public Task<VirtualMonitor?> AttachAsync(int width, int height, int refreshHz, string position, CancellationToken ct = default) =>
        AttachAsync(width, height, refreshHz, position, false, ct);

    public async Task<VirtualMonitor?> AttachAsync(int width, int height, int refreshHz, string position, bool makePrimary, CancellationToken ct = default)
    {
        var key = (width, height, refreshHz, position ?? "", makePrimary);
        Entry? reuse = null;
        List<Entry> stale = new();
        lock (_lock)
        {
            foreach (var e in _entries)
            {
                if (e.Key == key && (!e.Attach.IsCompleted || e.Attach is { IsCompletedSuccessfully: true, Result: not null }))
                {
                    reuse = e;
                    break;
                }
            }
            if (reuse != null)
            {
                reuse.Refs++;
                reuse.Linger?.Cancel();
                reuse.Linger = null;
            }
            else
            {
                // a lingering monitor with other parameters is in the way (e.g. new resolution / position)
                stale.AddRange(_entries.Where(e => e.Refs == 0));
                foreach (var e in stale) { e.Linger?.Cancel(); _entries.Remove(e); }
            }
        }
        if (reuse != null)
        {
            var vm = await reuse.Attach.ConfigureAwait(false);
            if (vm != null && StillPresent(vm))
            {
                _log.LogInformation("Virtual display reused (attached already): {Dev} {Bounds}", vm.DeviceName, vm.DesktopBounds);
                return vm;
            }
            // it vanished meanwhile (driver restart, user changed the display layout): forget it and attach anew
            lock (_lock) { reuse.Refs--; if (reuse.Refs <= 0) _entries.Remove(reuse); }
        }
        foreach (var e in stale) await DetachEntryAsync(e).ConfigureAwait(false);

        var entry = new Entry
        {
            Key = key, Refs = 1,
            Attach = makePrimary ? _inner.AttachAsync(width, height, refreshHz, position ?? "", true, ct)
                                 : _inner.AttachAsync(width, height, refreshHz, position ?? "", ct),
        };
        lock (_lock) _entries.Add(entry);
        try
        {
            var vm = await entry.Attach.ConfigureAwait(false);
            if (vm == null) lock (_lock) _entries.Remove(entry);
            return vm;
        }
        catch
        {
            lock (_lock) _entries.Remove(entry);
            throw;
        }
    }

    /// Plain detach = release without grace period.
    public Task DetachAsync(VirtualMonitor monitor) => ReleaseAsync(monitor, TimeSpan.Zero);

    /// Drops one reference; the monitor is detached when nobody uses it any more, after <paramref name="linger"/>.
    public async Task ReleaseAsync(VirtualMonitor monitor, TimeSpan linger)
    {
        Entry? e;
        lock (_lock)
        {
            e = _entries.FirstOrDefault(x => x.Attach.IsCompletedSuccessfully && ReferenceEquals(x.Attach.Result, monitor));
            if (e == null) { }
            else if (--e.Refs > 0) return;
            else if (linger > TimeSpan.Zero)
            {
                var cts = new CancellationTokenSource();
                e.Linger = cts;
                _log.LogInformation("Virtual display {Dev} kept attached for {S:F0} s (fast reconnect)", monitor.DeviceName, linger.TotalSeconds);
                _ = LingerThenDetachAsync(e, linger, cts.Token);
                return;
            }
            else _entries.Remove(e);
        }
        if (e == null) { await _inner.DetachAsync(monitor).ConfigureAwait(false); return; } // not ours (should not happen)
        await DetachEntryAsync(e).ConfigureAwait(false);
    }

    private async Task LingerThenDetachAsync(Entry e, TimeSpan linger, CancellationToken ct)
    {
        try { await Task.Delay(linger, ct).ConfigureAwait(false); }
        catch (OperationCanceledException) { return; }
        lock (_lock)
        {
            if (e.Refs > 0 || e.Linger?.Token != ct) return;
            _entries.Remove(e);
        }
        _log.LogInformation("Grace period over, detaching virtual display");
        await DetachEntryAsync(e).ConfigureAwait(false);
    }

    private async Task DetachEntryAsync(Entry e)
    {
        try
        {
            var vm = await e.Attach.ConfigureAwait(false);
            if (vm != null) await _inner.DetachAsync(vm).WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false);
        }
        catch (Exception ex) { _log.LogWarning("Virtual display detach failed: {Msg}", ex.Message); }
    }

    /// Detaches everything now (server stop).
    public async Task DetachAllAsync()
    {
        List<Entry> all;
        lock (_lock) { all = _entries.ToList(); _entries.Clear(); }
        foreach (var e in all) { e.Linger?.Cancel(); await DetachEntryAsync(e).ConfigureAwait(false); }
    }

    public Task<int> SetScaleAsync(VirtualMonitor monitor, int scalePercent, int tabletDensityDpi, CancellationToken ct = default) =>
        _inner.SetScaleAsync(monitor, scalePercent, tabletDensityDpi, ct);

    private static bool StillPresent(VirtualMonitor vm)
    {
        try
        {
            return Capture.Monitors.Enumerate().Any(m => string.Equals(m.DeviceName, vm.DeviceName, StringComparison.OrdinalIgnoreCase)
                                                         && m.Bounds == vm.DesktopBounds);
        }
        catch { return true; }
    }

    /// Grace period for a session that ended with <paramref name="reason"/>.
    public static TimeSpan LingerFor(string reason)
    {
        if (reason.Contains("user disconnected", StringComparison.OrdinalIgnoreCase) ||
            reason.Contains("host stopping", StringComparison.OrdinalIgnoreCase) ||
            reason.Contains("by host", StringComparison.OrdinalIgnoreCase) ||
            reason.Contains("pairing", StringComparison.OrdinalIgnoreCase))
            return TimeSpan.Zero;                       // deliberate: give the windows back right away
        if (reason.Contains("switching host", StringComparison.OrdinalIgnoreCase))
            return TimeSpan.FromSeconds(8);             // the tablet reconnects immediately
        return TimeSpan.FromSeconds(10);                // lost connection / app in background: likely back soon
    }
}
