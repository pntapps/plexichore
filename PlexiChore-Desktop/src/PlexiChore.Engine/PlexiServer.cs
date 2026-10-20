using System.Collections.Concurrent;
using System.Net;
using System.Net.Sockets;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Logging.Abstractions;
using PlexiChore.Engine.Discovery;
using PlexiChore.Engine.Streaming;
using Vortice.MediaFoundation;

namespace PlexiChore.Engine;

/// PlexiChore streaming server (Windows). See PROTOCOL.md.
/// Host process requirement: per-monitor DPI awareness v2 (app.manifest &lt;dpiAwareness&gt;PerMonitorV2&lt;/dpiAwareness&gt;).
/// The engine additionally switches its own capture/input threads to PMv2, but the manifest keeps the whole
/// process (GetCursorInfo, SendInput metrics, WPF windows) consistent.
public sealed class PlexiServer : IPlexiServer, ISessionHost
{
    private readonly IVirtualDisplayProvider? _virtualDisplays;
    private readonly ILogger _log;
    private readonly ConcurrentDictionary<Guid, Session> _sessions = new();
    private readonly ConcurrentDictionary<Guid, Task> _sessionTasks = new();
    private readonly ConcurrentDictionary<string, byte> _trusted = new(StringComparer.OrdinalIgnoreCase);
    private readonly object _stateLock = new();
    private ServerOptions _options = new();
    private CancellationTokenSource? _cts;
    private TcpListener? _listener;
    private Task? _acceptTask;
    private DiscoveryBeacon? _discovery;
    private bool _mfStarted;
    private string _hostId = "";

    public PlexiServer(IVirtualDisplayProvider? virtualDisplays, ILogger? logger = null)
    {
        _log = logger ?? NullLogger.Instance;
        _virtualDisplays = virtualDisplays == null ? null : new VirtualDisplayLeases(virtualDisplays, _log);
    }

    public bool IsRunning { get; private set; }

    public IReadOnlyList<SessionInfo> Sessions =>
        _sessions.Values.Select(s => s.Info).Where(i => i != null).Cast<SessionInfo>().ToList();

    public event EventHandler<SessionInfo>? SessionStarted;
    public event EventHandler<SessionInfo>? SessionEnded;
    public event EventHandler<SessionStats>? StatsUpdated;
    public event EventHandler<PairingRequest>? PairingRequested;
    /// Additive: raised when an active session's stream parameters change (SETTINGS, resize, fallback).
    public event EventHandler<SessionInfo>? SessionUpdated;

    ServerOptions ISessionHost.Options => _options;
    IVirtualDisplayProvider? ISessionHost.VirtualDisplays => _virtualDisplays;

    public Task StartAsync(ServerOptions options, CancellationToken ct = default)
    {
        lock (_stateLock)
        {
            if (IsRunning) throw new InvalidOperationException("Server already running");
            _options = options;
            _hostId = string.IsNullOrWhiteSpace(options.HostId) ? Guid.NewGuid().ToString() : options.HostId;
            _trusted.Clear();
            foreach (var id in options.TrustedDeviceIds) _trusted[id] = 0;

            if (!_mfStarted)
            {
                MediaFactory.MFStartup(true).CheckError();
                _mfStarted = true;
            }

            var listener = new TcpListener(IPAddress.IPv6Any, options.TcpPort);
            listener.Server.DualMode = true;
            listener.Server.NoDelay = true;
            listener.Server.ExclusiveAddressUse = true;
            listener.Start(16);
            _listener = listener;

            _cts = new CancellationTokenSource();
            _acceptTask = AcceptLoopAsync(_cts.Token);

            _discovery = new DiscoveryBeacon(options.DiscoveryPort, BuildBeacon, _log);
            _discovery.Start();
            _ = Task.Run(Warmup);
            IsRunning = true;
        }
        _log.LogInformation("PlexiServer listening on TCP {Port}, discovery UDP {Disc}, host {Name} ({Id})",
            options.TcpPort, options.DiscoveryPort, options.HostName, _hostId);
        return Task.CompletedTask;
    }

    private void Warmup() => EngineWarmup.Run(_log);

    private byte[] BuildBeacon()
    {
        bool vd = false;
        try { vd = _virtualDisplays?.IsAvailable == true; } catch { }
        return DiscoveryBeacon.BuildPayload(_hostId, _options.HostName, _options.TcpPort, vd);
    }

    private async Task AcceptLoopAsync(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            Socket sock;
            try { sock = await _listener!.AcceptSocketAsync(ct).ConfigureAwait(false); }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException ex) { _log.LogDebug("accept: {Msg}", ex.Message); continue; }

            var session = new Session(sock, this, _log, ct);
            _log.LogInformation("Connection from {Remote} ({Transport})", session.Remote, session.IsUsb ? "USB/loopback" : "network");
            _sessions[session.Id] = session;
            _sessionTasks[session.Id] = Task.Run(async () =>
            {
                try { await session.RunAsync().ConfigureAwait(false); }
                catch (Exception ex) { _log.LogError(ex, "session crashed"); }
                finally
                {
                    _sessions.TryRemove(session.Id, out _);
                    _sessionTasks.TryRemove(session.Id, out _);
                }
            });
        }
    }

    public async Task StopAsync()
    {
        CancellationTokenSource? cts;
        lock (_stateLock)
        {
            if (!IsRunning) return;
            IsRunning = false;
            cts = _cts;
            _cts = null;
        }
        try { _listener?.Stop(); } catch { }
        _discovery?.Dispose();
        _discovery = null;

        await Task.WhenAll(_sessions.Values.Select(s => s.DisconnectAsync("host stopping"))).ConfigureAwait(false);
        cts?.Cancel();
        try { await Task.WhenAll(_sessionTasks.Values.ToArray()).WaitAsync(TimeSpan.FromSeconds(10)).ConfigureAwait(false); }
        catch (Exception ex) { _log.LogDebug("stop: {Msg}", ex.Message); }
        if (_virtualDisplays is VirtualDisplayLeases leases) { try { await leases.DetachAllAsync().ConfigureAwait(false); } catch { } }
        try { if (_acceptTask != null) await _acceptTask.ConfigureAwait(false); } catch { }
        cts?.Dispose();
        _log.LogInformation("PlexiServer stopped");
    }

    public void Disconnect(Guid sessionId)
    {
        if (_sessions.TryGetValue(sessionId, out var s)) _ = s.DisconnectAsync("disconnected by host");
    }

    public async ValueTask DisposeAsync()
    {
        await StopAsync().ConfigureAwait(false);
        if (_mfStarted)
        {
            try { MediaFactory.MFShutdown(); } catch { }
            _mfStarted = false;
        }
    }

    // ---------------- ISessionHost ----------------
    bool ISessionHost.IsTrusted(string deviceId) => _trusted.ContainsKey(deviceId);
    void ISessionHost.MarkTrusted(string deviceId) => _trusted[deviceId] = 0;

    void ISessionHost.OnSessionStarted(Session s, SessionInfo info) => Raise(SessionStarted, info);
    void ISessionHost.OnSessionUpdated(Session s, SessionInfo info) => Raise(SessionUpdated, info);
    void ISessionHost.OnSessionEnded(Session s, SessionInfo info) => Raise(SessionEnded, info);
    void ISessionHost.OnStats(SessionStats stats) => Raise(StatsUpdated, stats);

    void ISessionHost.OnPairing(PairingRequest req)
    {
        if (PairingRequested == null)
        {
            _log.LogWarning("Pairing requested by {Name} but no handler is attached; rejecting", req.DeviceName);
            req.Respond(false);
            return;
        }
        Raise(PairingRequested, req);
    }

    private void Raise<T>(EventHandler<T>? handler, T arg)
    {
        if (handler == null) return;
        foreach (EventHandler<T> h in handler.GetInvocationList())
        {
            try { h(this, arg); }
            catch (Exception ex) { _log.LogError(ex, "Event handler threw"); }
        }
    }
}
