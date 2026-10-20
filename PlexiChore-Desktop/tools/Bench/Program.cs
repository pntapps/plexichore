// PlexiChore smoothness benchmark harness. See bench.ps1 for the scenario matrix wrapper.
//
//   Bench run --transport usb|wireless-adb|wifi-direct --mode mirror|extend [--seconds 15] [--motions cursor,anim]
//             [--taps 10] [--host-ip 192.168.0.132] [--control-serial S] [--no-force-stop] [--keep] [--out DIR]
//   Bench preflight                 read-only: adb devices, reverse owner, layers, PC app/port, LAN IP, firewall
//   Bench monitors                  monitors in physical px (per-monitor-v2 DPI aware)
//   Bench cursor [--monitor primary|virtual|DISPLAYn|x,y,w,h] [--seconds 5] [--hz 125] [--dry]
//   Bench anim   [--monitor ...] [--seconds 5] [--fps 60] [--offscreen]
//   Bench sf-stats <latency dump files...> [--fps 60]      (files may hold several "=== time" separated polls)
//   Bench engine-log <file> [--day yyyy-MM-dd]
//   Bench table <results dir>       rebuild a markdown table from */result.json
//   Bench selftest                  offline parser tests on samples\
using System.Globalization;
using PlexiBench;

Native.EnsurePerMonitorDpi();
if (args.Length == 0) { PrintUsage(); return 2; }
var cmd = args[0];
var opt = Args.Parse(args.Skip(1).ToArray());

try
{
    switch (cmd)
    {
        case "run":
        {
            var o = new ScenarioOptions
            {
                Transport = opt.Get("transport", "usb"),
                Mode = opt.Get("mode", "mirror"),
                Codec = opt.Get("codec", "h264"),
                Seconds = opt.D("seconds", 15),
                Motions = opt.Get("motions", "cursor,anim").Split(',', StringSplitOptions.RemoveEmptyEntries),
                CursorHz = opt.D("hz", 125),
                AnimFps = opt.D("fps", 60),
                ExpectedFps = opt.D("expected-fps", 60),
                HostIp = opt.GetOrNull("host-ip"),
                ControlSerial = opt.GetOrNull("control-serial"),
                ForceStop = !opt.Has("no-force-stop"),
                Taps = (int)opt.D("taps", 0),
                KeepSession = opt.Has("keep"),
                OutRoot = opt.GetOrNull("out"),
            };
            var r = new ScenarioRunner(o).Run();
            return r.Error == null ? 0 : 1;
        }
        case "preflight": return Preflight();
        case "monitors":
            Console.WriteLine($"DPI awareness: {Native.DpiAwarenessName()}");
            foreach (var m in Monitors.List()) Console.WriteLine(m);
            return 0;
        case "cursor":
        {
            var mon = Monitors.Resolve(opt.Get("monitor", "primary"));
            Console.WriteLine($"cursor circles on {mon}{(opt.Has("dry") ? " (dry: timing only, cursor untouched)" : "")}");
            Console.WriteLine(CursorMotion.Run(mon.Bounds, opt.D("seconds", 5), opt.D("hz", 125), dry: opt.Has("dry")));
            return 0;
        }
        case "anim":
        {
            var mon = Monitors.Resolve(opt.Get("monitor", "primary"));
            var rect = mon.Bounds;
            // --offscreen: same size, placed far outside every monitor, so nothing visible/captured changes (render-cost test)
            if (opt.Has("offscreen")) rect = new System.Drawing.Rectangle(-32000 + 100, -32000 + 100, rect.Width, rect.Height);
            Console.WriteLine($"anim {rect.Width}x{rect.Height} at ({rect.X},{rect.Y})");
            Console.WriteLine(AnimWindow.Run(rect, opt.D("seconds", 5), opt.D("fps", 60)));
            return 0;
        }
        case "sf-stats":
        {
            var acc = new SfLatencyAccumulator();
            foreach (var f in opt.Positional)
                foreach (var chunk in File.ReadAllText(f).Split("=== "))
                    acc.Add(chunk.Contains('\n') && chunk.Split('\n')[0].Contains(':') ? chunk[(chunk.IndexOf('\n') + 1)..] : chunk);
            Console.WriteLine(acc.Compute(opt.D("fps", 60)));
            return 0;
        }
        case "engine-log":
        {
            var day = opt.Has("day") ? DateTime.ParseExact(opt.Get("day", ""), "yyyy-MM-dd", CultureInfo.InvariantCulture) : DateTime.Today;
            var s = EngineLog.Summarize(EngineLog.ParseLines(File.ReadAllText(opt.Positional[0]), day));
            Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(s, Report.Json));
            Console.WriteLine($"perf avg fps {s.PerfAvg("fps"):F1} encodeCall {s.PerfAvg("encodeCall"):F2} lat {s.PerfAvg("lat"):F2} max {s.PerfMax("max"):F2} busy {s.PerfSum("busy")}");
            return 0;
        }
        case "table":
        {
            var dir = Path.GetFullPath(opt.Positional.FirstOrDefault() ?? Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "results"));
            Console.Write(Report.Table(Directory.GetFiles(dir, "result.json", SearchOption.AllDirectories).OrderBy(f => f), dir));
            return 0;
        }
        case "selftest": return SelfTest.Run();
        default: PrintUsage(); return 2;
    }
}
catch (Exception ex)
{
    Console.Error.WriteLine("error: " + ex.Message);
    return 1;
}

static int Preflight()
{
    var adb = new Adb();
    var devs = adb.Devices();
    Console.WriteLine($"adb: {adb.Path}");
    foreach (var s in new[] { Adb.UsbSerial, Adb.WirelessSerial })
        Console.WriteLine($"  {s}: {(devs.TryGetValue(s, out var st) ? st : "absent")}");
    var ctl = devs.GetValueOrDefault(Adb.UsbSerial) == "device" ? Adb.UsbSerial : devs.GetValueOrDefault(Adb.WirelessSerial) == "device" ? Adb.WirelessSerial : null;
    if (ctl != null)
    {
        var rl = adb.Dev(ctl, "reverse --list").Output;
        var owner = ReverseList.Owner(rl);
        Console.WriteLine($"reverse tcp:47800 owner: {owner ?? "none"} ({ReverseList.Classify(owner)})");
        var layers = SfLayers.FindVideoLayers(adb.Shell(ctl, "dumpsys SurfaceFlinger --list").Output);
        Console.WriteLine($"PlexiChore SurfaceView layers: {(layers.Count == 0 ? "none (no session)" : string.Join(" | ", layers))}");
        var (off, rtt, method) = adb.ClockOffsetPersistent(ctl, 15);
        Console.WriteLine($"tablet clock offset {off:F1} ms (best rtt {rtt:F1} ms via {method})");
    }
    var app = HostChecks.PlexiChoreApp();
    Console.WriteLine($"PlexiChore Desktop: {(app is { } a ? $"pid {a.Pid} {a.Path} since {a.Started:HH:mm:ss}" : "not running")}; {HostChecks.EngineHostRunning() ?? "no EngineHost"}");
    Console.WriteLine($"TCP 47800 listening: {HostChecks.PortListening()}");
    Console.WriteLine($"LAN IPv4: {string.Join(", ", HostChecks.LanIPv4().Select(x => $"{x.Iface}={x.Ip}{(x.HasGateway ? " (gw)" : "")}"))}");
    var cat = HostChecks.NetworkCategory();
    var prof = cat.Contains("Private") ? "Private" : cat.Contains("DomainAuthenticated") ? "Domain" : "Public";
    Console.WriteLine($"network category: {cat}");
    Console.WriteLine($"firewall (inbound TCP 47800 -> PlexiChore.exe): {HostChecks.FirewallVerdict(HostChecks.InboundRules(), app?.Path, prof)}");
    var settings = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "PlexiChore", "settings.json");
    if (File.Exists(settings))
    {
        var txt = File.ReadAllText(settings);
        Console.WriteLine($"settings: requireApprovalForWifi={(txt.Contains("\"requireApprovalForWifi\": true") ? "true" : "false")}, autoAdbReverse={(txt.Contains("\"autoAdbReverse\": true") ? "true" : "false")}, trustedDevices={(txt.Contains("\"trustedDevices\": []") ? "none" : "some")}");
    }
    Console.WriteLine("monitors:");
    foreach (var m in Monitors.List()) Console.WriteLine("  " + m);
    return 0;
}

static void PrintUsage()
{
    var src = Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "Program.cs");
    Console.WriteLine(File.Exists(src) ? string.Join('\n', File.ReadLines(src).TakeWhile(l => l.StartsWith("//"))) : "see tools/Bench/Program.cs header");
}

internal sealed class Args
{
    private readonly Dictionary<string, string?> _kv = new(StringComparer.OrdinalIgnoreCase);
    public List<string> Positional { get; } = new();

    public static Args Parse(string[] a)
    {
        var r = new Args();
        for (int i = 0; i < a.Length; i++)
        {
            if (a[i].StartsWith("--"))
            {
                var k = a[i][2..];
                string? v = i + 1 < a.Length && !a[i + 1].StartsWith("--") ? a[++i] : null;
                r._kv[k] = v;
            }
            else r.Positional.Add(a[i]);
        }
        return r;
    }

    public bool Has(string k) => _kv.ContainsKey(k);
    public string Get(string k, string def) => _kv.TryGetValue(k, out var v) && v != null ? v : def;
    public string? GetOrNull(string k) => _kv.TryGetValue(k, out var v) ? v : null;
    public double D(string k, double def) => _kv.TryGetValue(k, out var v) && v != null ? double.Parse(v, CultureInfo.InvariantCulture) : def;
}
