using Microsoft.Extensions.Logging;
using PlexiChore.Engine;

namespace PlexiChore.App.Services;

public enum ServerState { Stopped, Starting, Running, Paused, Error }

/// Owns the Engine's IPlexiServer: start/stop/pause, option rebuilds from settings, and deferred restarts
/// (option changes are applied when no tablet is connected so a live session is never cut).
public sealed class ServerHost : IAsyncDisposable
{
    private readonly SettingsService _settings;
    private readonly IVirtualDisplayProvider? _vdd;
    private readonly ILogger _engineLog;
    private readonly ILogger<ServerHost> _log;
    private readonly SemaphoreSlim _gate = new(1, 1);
    private IPlexiServer? _server;
    private bool _restartPending;

    public ServerHost(SettingsService settings, IVirtualDisplayProvider? vdd, ILoggerFactory lf)
    {
        _settings = settings;
        _vdd = vdd;
        _engineLog = lf.CreateLogger("PlexiChore.Engine");
        _log = lf.CreateLogger<ServerHost>();
    }

    /// Set by the App (AdbManager): tells USB sessions whether adb reverse runs over the cable or wireless debugging.
    public Func<string?, CancellationToken, Task<string?>>? LoopbackLinkResolver { get; set; }

    public ServerState State { get; private set; } = ServerState.Stopped;
    public string? LastError { get; private set; }
    public IReadOnlyList<SessionInfo> Sessions => _server?.Sessions ?? Array.Empty<SessionInfo>();

    public event EventHandler? StateChanged;
    public event EventHandler<SessionInfo>? SessionStarted;
    public event EventHandler<SessionInfo>? SessionEnded;
    /// Stream parameters of a live session changed (SETTINGS, fallback, display scale).
    public event EventHandler<SessionInfo>? SessionUpdated;
    public event EventHandler<SessionStats>? StatsUpdated;
    public event EventHandler<PairingRequest>? PairingRequested;

    public ServerOptions BuildOptions()
    {
        var s = _settings.Current;
        return new ServerOptions
        {
            HostId = s.HostId,
            HostName = Environment.MachineName,
            RequireApprovalForWifi = s.RequireApprovalForWifi,
            TrustedDeviceIds = s.TrustedDevices.Select(d => d.Id).ToArray(),
            PreferHardwareEncoder = s.PreferHardwareEncoder,
            LoopbackLinkResolver = LoopbackLinkResolver,
        };
    }

    public async Task StartAsync()
    {
        await _gate.WaitAsync();
        try { await StartCoreAsync(); }
        finally { _gate.Release(); }
    }

    private async Task StartCoreAsync()
    {
        if (_server?.IsRunning == true) return;
        SetState(ServerState.Starting);
        try
        {
            if (_server == null)
            {
                var ps = new PlexiServer(_vdd, _engineLog);
                ps.SessionUpdated += (s, e) => SessionUpdated?.Invoke(this, e);
                _server = ps;
                _server.SessionStarted += OnSessionStarted;
                _server.SessionEnded += OnSessionEnded;
                _server.StatsUpdated += (s, e) => StatsUpdated?.Invoke(this, e);
                _server.PairingRequested += (s, e) => PairingRequested?.Invoke(this, e);
            }
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(15));
            await _server.StartAsync(BuildOptions(), cts.Token);
            _restartPending = false;
            LastError = null;
            SetState(ServerState.Running);
            _log.LogInformation("Server started");
        }
        catch (Exception ex)
        {
            LastError = ex is System.Net.Sockets.SocketException { SocketErrorCode: System.Net.Sockets.SocketError.AddressAlreadyInUse }
                ? "Port 47800 is already in use by another program."
                : ex.Message;
            _log.LogError(ex, "Server failed to start");
            SetState(ServerState.Error);
        }
    }

    public async Task StopAsync(bool paused)
    {
        await _gate.WaitAsync();
        try
        {
            if (_server != null)
            {
                try { await _server.StopAsync(); }
                catch (Exception ex) { _log.LogWarning(ex, "Server stop failed"); }
            }
            SetState(paused ? ServerState.Paused : ServerState.Stopped);
        }
        finally { _gate.Release(); }
    }

    /// Re-applies options (trusted list, approval policy, encoder). Deferred while sessions are live.
    public async Task ApplyOptionsAsync()
    {
        if (State is ServerState.Paused or ServerState.Stopped) return;
        if (Sessions.Count > 0) { _restartPending = true; return; }
        await RestartAsync();
    }

    public async Task RestartAsync()
    {
        await _gate.WaitAsync();
        try
        {
            if (_server != null) { try { await _server.StopAsync(); } catch { } }
            await StartCoreAsync();
        }
        finally { _gate.Release(); }
    }

    public void Disconnect(Guid sessionId) => _server?.Disconnect(sessionId);

    private void OnSessionStarted(object? sender, SessionInfo e) => SessionStarted?.Invoke(this, e);

    private void OnSessionEnded(object? sender, SessionInfo e)
    {
        SessionEnded?.Invoke(this, e);
        if (_restartPending && Sessions.Count == 0)
        {
            _ = Task.Run(async () =>
            {
                await Task.Delay(3000); // give a reconnecting tablet a moment
                if (_restartPending && Sessions.Count == 0) await RestartAsync();
            });
        }
    }

    private void SetState(ServerState s)
    {
        State = s;
        StateChanged?.Invoke(this, EventArgs.Empty);
    }

    public async ValueTask DisposeAsync()
    {
        if (_server != null)
        {
            try { await _server.StopAsync().WaitAsync(TimeSpan.FromSeconds(5)); } catch { }
            try { await _server.DisposeAsync(); } catch { }
        }
        _gate.Dispose();
    }
}
