namespace PlexiChore.App.Services;

/// Per-user single instance: a named mutex owns the instance; later launches signal a named event so the running
/// instance brings its window to the front, then exit.
public sealed class SingleInstance : IDisposable
{
    private const string MutexName = @"Local\PlexiChore.Desktop.SingleInstance";
    private const string EventName = @"Local\PlexiChore.Desktop.Activate";

    private readonly Mutex _mutex;
    private readonly EventWaitHandle _event;
    private readonly RegisteredWaitHandle? _wait;

    private SingleInstance(Mutex m, EventWaitHandle e, Action onActivate)
    {
        _mutex = m;
        _event = e;
        _wait = ThreadPool.RegisterWaitForSingleObject(_event, (_, _) => onActivate(), null, Timeout.Infinite, executeOnlyOnce: false);
    }

    /// Returns null if another instance is already running (and has been asked to show itself).
    public static SingleInstance? TryAcquire(Action onActivate)
    {
        var m = new Mutex(initiallyOwned: true, MutexName, out var createdNew);
        if (!createdNew)
        {
            // An abandoned mutex (crashed instance) is acquirable.
            try
            {
                if (!m.WaitOne(0))
                {
                    m.Dispose();
                    try
                    {
                        using var ev = EventWaitHandle.OpenExisting(EventName);
                        ev.Set();
                    }
                    catch { }
                    return null;
                }
            }
            catch (AbandonedMutexException) { }
        }
        var e = new EventWaitHandle(false, EventResetMode.AutoReset, EventName);
        return new SingleInstance(m, e, onActivate);
    }

    public void Dispose()
    {
        _wait?.Unregister(null);
        _event.Dispose();
        try { _mutex.ReleaseMutex(); } catch { }
        _mutex.Dispose();
    }
}
