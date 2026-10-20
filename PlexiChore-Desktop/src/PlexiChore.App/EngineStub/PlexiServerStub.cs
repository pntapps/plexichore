#if ENGINE_STUB
// Design-time stand-in for PlexiChore.Engine's PlexiServer. Only compiled with -p:UseEngineStub=true.
// Set PLEXICHORE_DEMO=1 to get a fake connected session + periodic stats (useful for UI screenshots).
using Microsoft.Extensions.Logging;

namespace PlexiChore.Engine;

public sealed class PlexiServer : IPlexiServer
{
    private readonly List<SessionInfo> _sessions = new();
    private Timer? _timer;

    public PlexiServer(IVirtualDisplayProvider? virtualDisplays, ILogger? logger = null) { }

    public bool IsRunning { get; private set; }
    public IReadOnlyList<SessionInfo> Sessions => _sessions;
    public event EventHandler<SessionInfo>? SessionStarted;
    public event EventHandler<SessionInfo>? SessionEnded;
    public event EventHandler<SessionStats>? StatsUpdated;
    public event EventHandler<PairingRequest>? PairingRequested;

    public Task StartAsync(ServerOptions options, CancellationToken ct = default)
    {
        IsRunning = true;
        if (Environment.GetEnvironmentVariable("PLEXICHORE_DEMO") == "1")
        {
            var s = new SessionInfo(Guid.NewGuid(), "demo", "Galaxy Tab S8", "SM-X700", true, "extend", 2560, 1600, 60, "h264");
            _sessions.Add(s);
            SessionStarted?.Invoke(this, s);
            var rnd = new Random();
            _timer = new Timer(_ => StatsUpdated?.Invoke(this, new SessionStats(s.SessionId, 59 + rnd.NextDouble(), 4 + rnd.NextDouble(), 18000 + rnd.Next(2000), 3 + rnd.NextDouble() * 2)), null, 500, 1000);
            if (Environment.GetEnvironmentVariable("PLEXICHORE_DEMO_PAIR") == "1")
                PairingRequested?.Invoke(this, new PairingRequest { DeviceId = "demo2", DeviceName = "Pixel Tablet", Code = "4821", Respond = _ => { } });
        }
        return Task.CompletedTask;
    }

    public Task StopAsync()
    {
        IsRunning = false;
        _timer?.Dispose();
        foreach (var s in _sessions.ToList()) { _sessions.Remove(s); SessionEnded?.Invoke(this, s); }
        return Task.CompletedTask;
    }

    public void Disconnect(Guid sessionId)
    {
        var s = _sessions.FirstOrDefault(x => x.SessionId == sessionId);
        if (s != null) { _sessions.Remove(s); SessionEnded?.Invoke(this, s); }
    }

    public ValueTask DisposeAsync() => new(StopAsync());
}
#endif
