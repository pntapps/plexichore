using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;

namespace PlexiChore.Engine.Discovery;

/// UDP discovery: beacon to 255.255.255.255:47801 and every NIC's directed broadcast once per second,
/// and unicast replies to "PLEXI?" probes.
internal sealed class DiscoveryBeacon : IDisposable
{
    private readonly ILogger _log;
    private readonly int _port;
    private readonly Func<byte[]> _payload;
    private readonly CancellationTokenSource _cts = new();
    private UdpClient? _listener;
    private Task? _rx, _tx;
    private List<(IPAddress Local, IPAddress Broadcast, UdpClient Sock)> _senders = new();
    private long _nextNicRefresh;

    public DiscoveryBeacon(int port, Func<byte[]> payload, ILogger log)
    {
        _port = port; _payload = payload; _log = log;
    }

    public static byte[] BuildPayload(string id, string name, int tcpPort, bool virtualDisplay) =>
        JsonSerializer.SerializeToUtf8Bytes(new Dictionary<string, object>
        {
            ["svc"] = "plexichore", ["v"] = 1, ["id"] = id, ["name"] = name, ["os"] = "windows",
            ["port"] = tcpPort, ["virtualDisplay"] = virtualDisplay,
        });

    public void Start()
    {
        try
        {
            var s = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
            s.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
            s.EnableBroadcast = true;
            s.Bind(new IPEndPoint(IPAddress.Any, _port));
            _listener = new UdpClient { Client = s };
            _rx = Task.Run(() => ReceiveLoop(_cts.Token));
        }
        catch (Exception ex)
        {
            _log.LogWarning("Discovery listener on UDP {Port} unavailable: {Msg} (beacons still sent)", _port, ex.Message);
        }
        _tx = Task.Run(() => BeaconLoop(_cts.Token));
    }

    private async Task ReceiveLoop(CancellationToken ct)
    {
        while (!ct.IsCancellationRequested)
        {
            try
            {
                var r = await _listener!.ReceiveAsync(ct).ConfigureAwait(false);
                if (r.Buffer.Length >= 6 && Encoding.ASCII.GetString(r.Buffer, 0, Math.Min(r.Buffer.Length, 16)).TrimEnd('\0', '\r', '\n', ' ') == "PLEXI?")
                {
                    await _listener.SendAsync(_payload(), r.RemoteEndPoint, ct).ConfigureAwait(false);
                    _log.LogDebug("Discovery probe from {Ep} answered", r.RemoteEndPoint);
                }
            }
            catch (OperationCanceledException) { return; }
            catch (ObjectDisposedException) { return; }
            catch (SocketException) { /* ICMP port unreachable etc. */ }
        }
    }

    private void RefreshNics()
    {
        foreach (var s in _senders) s.Sock.Dispose();
        _senders = new();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up || nic.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
            IPInterfaceProperties props;
            try { props = nic.GetIPProperties(); } catch { continue; }
            foreach (var ua in props.UnicastAddresses)
            {
                if (ua.Address.AddressFamily != AddressFamily.InterNetwork || ua.IPv4Mask == null) continue;
                var ip = ua.Address.GetAddressBytes();
                var mask = ua.IPv4Mask.GetAddressBytes();
                var bc = new byte[4];
                for (int i = 0; i < 4; i++) bc[i] = (byte)(ip[i] | ~mask[i]);
                try
                {
                    var sock = new UdpClient(new IPEndPoint(ua.Address, 0)) { EnableBroadcast = true };
                    _senders.Add((ua.Address, new IPAddress(bc), sock));
                }
                catch (Exception ex) { _log.LogDebug("beacon socket {Ip}: {Msg}", ua.Address, ex.Message); }
            }
        }
    }

    private async Task BeaconLoop(CancellationToken ct)
    {
        var global = new IPEndPoint(IPAddress.Broadcast, _port);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                if (Environment.TickCount64 >= _nextNicRefresh)
                {
                    RefreshNics();
                    _nextNicRefresh = Environment.TickCount64 + 10_000;
                }
                var payload = _payload();
                foreach (var (_, bcast, sock) in _senders)
                {
                    try
                    {
                        await sock.SendAsync(payload, global, ct).ConfigureAwait(false);
                        if (!bcast.Equals(IPAddress.Broadcast))
                            await sock.SendAsync(payload, new IPEndPoint(bcast, _port), ct).ConfigureAwait(false);
                    }
                    catch (SocketException) { _nextNicRefresh = 0; }
                }
                await Task.Delay(1000, ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) { return; }
            catch (Exception ex) { _log.LogDebug("beacon: {Msg}", ex.Message); await Task.Delay(1000, CancellationToken.None); }
        }
    }

    public void Dispose()
    {
        _cts.Cancel();
        _listener?.Dispose();
        try { Task.WaitAll(new[] { _rx ?? Task.CompletedTask, _tx ?? Task.CompletedTask }, 2000); } catch { }
        foreach (var s in _senders) s.Sock.Dispose();
        _senders.Clear();
    }
}
