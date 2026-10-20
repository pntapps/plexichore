// Standalone host for PlexiChore.Engine: mirror mode (no virtual display provider), console logging.
// Usage: EngineHost [--port 47800] [--discovery-port 47801] [--approve] [--seconds N] [--sw] [--verbose]
using Microsoft.Extensions.Logging;
using PlexiChore.Engine;

if (args.Length > 0 && args[0] == "--encbench")
{
    // EngineHost --encbench [--dev \\.\DISPLAY1] [--sizes 2560x1600,1920x1200] [--tunings "qvs=0;qvs=0,cabac=0"] [--fps 60] [--seconds 5]
    using var lf = LoggerFactory.Create(b => b.AddSimpleConsole(o => { o.SingleLine = true; }).SetMinimumLevel(args.Contains("--verbose") ? LogLevel.Debug : LogLevel.Warning));
    return PlexiChore.Engine.Diagnostics.EncoderProbe.Run(args.Skip(1).ToArray(), lf.CreateLogger("probe"));
}

int port = 47800, discoveryPort = 47801, seconds = 0;
bool autoApprove = false, sw = false, verbose = false;
for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--port": port = int.Parse(args[++i]); break;
        case "--discovery-port": discoveryPort = int.Parse(args[++i]); break;
        case "--seconds": seconds = int.Parse(args[++i]); break;
        case "--approve": autoApprove = true; break;
        case "--sw": sw = true; break;
        case "--verbose": verbose = true; break;
    }
}

using var factory = LoggerFactory.Create(b => b
    .AddSimpleConsole(o => { o.SingleLine = true; o.TimestampFormat = "HH:mm:ss.fff "; })
    .SetMinimumLevel(verbose ? LogLevel.Debug : LogLevel.Information));
var log = factory.CreateLogger("PlexiChore");

await using var server = new PlexiServer(virtualDisplays: null, log);
server.SessionStarted += (_, s) => log.LogInformation("[event] SessionStarted {S}", s);
server.SessionEnded += (_, s) => log.LogInformation("[event] SessionEnded {Id} {Name}", s.SessionId, s.DeviceName);
server.SessionUpdated += (_, s) => log.LogInformation("[event] SessionUpdated {S}", s);
server.StatsUpdated += (_, s) => log.LogInformation("[stats] fps={Fps:F1} encode={Enc:F2}ms {Kbps}kbps rtt={Rtt:F1}ms", s.CaptureFps, s.EncodeMs, s.BitrateKbps, s.RttMs);
server.PairingRequested += (_, p) =>
{
    log.LogWarning("[pairing] {Name} ({Id}) code {Code} -> {Decision}", p.DeviceName, p.DeviceId, p.Code, autoApprove ? "auto-approved" : "type y + Enter to approve");
    if (autoApprove) { p.Respond(true); return; }
    _ = Task.Run(() => p.Respond(string.Equals(Console.ReadLine()?.Trim(), "y", StringComparison.OrdinalIgnoreCase)));
};

using var cts = new CancellationTokenSource();
Console.CancelKeyPress += (_, e) => { e.Cancel = true; cts.Cancel(); };
await server.StartAsync(new ServerOptions
{
    TcpPort = port,
    DiscoveryPort = discoveryPort,
    HostId = "enginehost-" + Environment.MachineName,
    PreferHardwareEncoder = !sw,
    RequireApprovalForWifi = true,
}, cts.Token);
log.LogInformation("EngineHost running (Ctrl+C to stop{Limit})", seconds > 0 ? $", auto-exit after {seconds}s" : "");
try { await Task.Delay(seconds > 0 ? TimeSpan.FromSeconds(seconds) : Timeout.InfiniteTimeSpan, cts.Token); }
catch (OperationCanceledException) { }
await server.StopAsync();
return 0;
