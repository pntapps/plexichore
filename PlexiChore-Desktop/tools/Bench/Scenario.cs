using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PlexiBench;

public sealed class ScenarioOptions
{
    public string Transport = "usb";          // usb | wireless-adb | wifi-direct
    public string Mode = "mirror";            // mirror | extend
    public string Codec = "h264";
    public double Seconds = 15;
    public string[] Motions = { "cursor", "anim" };
    public double CursorHz = 125, AnimFps = 60, ExpectedFps = 60;
    public string? HostIp;                     // wifi-direct target; default: detected LAN IP (192.168.0.132 preferred)
    public string? ControlSerial;              // serial used for dumpsys/logcat/am; default: USB if attached, else wireless
    public bool ForceStop = true;              // am force-stop before am start (clean connect-time measurement)
    public int Taps;                           // >0: input-latency phase with N taps
    public int ConnectTimeoutS = 25, ApproveTimeoutS = 90;
    public bool KeepSession;                   // leave the session running afterwards
    public string? OutRoot;
}

public sealed class PhaseResult
{
    public string Motion = "";
    public FrameStats? Tablet;
    public TickReport? Source;
    public double HostFps = double.NaN, HostComposeMs = double.NaN, HostConvertMs = double.NaN, HostEncodeCallMs = double.NaN,
        HostEncLatMs = double.NaN, HostEncLatMaxMs = double.NaN, HostBusy = double.NaN;
    public int HostPerfSamples, EncoderBusyDrops;
    // PlexiStats (tablet logcat, 1/s)
    public int TabStatsSamples;
    public double TabFps = double.NaN, TabRttMs = double.NaN, TabRttMaxMs = double.NaN, TabMaxGapMs = double.NaN, TabNetGapMs = double.NaN,
        TabDecodeMs = double.NaN, TabKbps = double.NaN, TabHitches = double.NaN, TabDropped = double.NaN;
    public string? TabVia;
    public List<string> Reconfigs = new(), Adaptive = new();
    public Dictionary<string, string> GfxInfo = new();
    public string? Screencap;
    public string? Error;
}

public sealed class ScenarioResult
{
    public string Transport = "", Mode = "", Started = "", Layer = "", ControlSerial = "", Host = "";
    public string? ReverseOwnerBefore, ReverseOwnerAfter, HelloTransport, HelloMode, Config, Encoder, CaptureSource, CaptureRect, VirtualRect, Monitor;
    public double AmToHelloMs = double.NaN, AmToConfigMs = double.NaN, AmToFirstFrameMs = double.NaN, ClockOffsetMs = double.NaN, ClockRttMs = double.NaN;
    public bool ExtendFellBack, ApprovalNeeded;
    public int ScaleApplied;
    public string VirtualAttach = "";   // cold | warm (reused within grace period) | ""
    public string? Firewall;
    public double[] InputLatencyMs = Array.Empty<double>();
    public string InputLatencyNote = "";
    public List<PhaseResult> Phases = new();
    public List<string> Notes = new();
    public string? Error;
}

public sealed class ScenarioRunner
{
    private readonly ScenarioOptions _o;
    private readonly Adb _adb = new();
    private readonly ScenarioResult _r = new();
    private string _ctl = "";
    private string _out = "";

    public ScenarioRunner(ScenarioOptions o) { _o = o; }

    private void Log(string s) => Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} {s}");
    private void Note(string s) { _r.Notes.Add(s); Log("NOTE " + s); }

    public ScenarioResult Run()
    {
        _r.Transport = _o.Transport; _r.Mode = _o.Mode; _r.Started = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss");
        var root = _o.OutRoot ?? Path.Combine(AppContext.BaseDirectory, "..", "..", "..", "results");
        _out = Path.GetFullPath(Path.Combine(root, $"{DateTime.Now:yyyyMMdd-HHmmss}-{_o.Transport}-{_o.Mode}"));
        Directory.CreateDirectory(_out);
        Log($"== scenario {_o.Transport} / {_o.Mode} -> {_out}");
        try { RunInner(); }
        catch (Exception ex) { _r.Error = ex.Message; Log("ERROR " + ex); }
        finally
        {
            if (!_o.KeepSession && _ctl.Length > 0) { try { _adb.Shell(_ctl, $"am force-stop {Adb.Package}"); } catch { } }
            File.WriteAllText(Path.Combine(_out, "result.json"), JsonSerializer.Serialize(_r, Report.Json));
            Report.Append(Path.Combine(_out, ".."), _r, _out);
        }
        return _r;
    }

    private void RunInner()
    {
        // ---------------- preflight ----------------
        var devs = _adb.Devices();
        bool usbOk = devs.TryGetValue(Adb.UsbSerial, out var us) && us == "device";
        bool wlOk = devs.TryGetValue(Adb.WirelessSerial, out var ws) && ws == "device";
        Log($"adb devices: usb={us ?? "absent"} wireless={ws ?? "absent"}");
        _ctl = _o.ControlSerial ?? (usbOk ? Adb.UsbSerial : wlOk ? Adb.WirelessSerial : throw new Exception("no adb device ready"));
        _r.ControlSerial = _ctl;
        if (_o.Transport == "usb" && !usbOk) throw new Exception("usb scenario needs the cable serial " + Adb.UsbSerial);
        if (_o.Transport == "wireless-adb" && !wlOk) throw new Exception("wireless-adb scenario needs " + Adb.WirelessSerial + " (adb connect / pair first)");
        var app = HostChecks.PlexiChoreApp();
        if (app == null && HostChecks.EngineHostRunning() == null) throw new Exception("neither PlexiChore Desktop nor EngineHost is running");
        if (_o.Mode != "mirror" && app == null) throw new Exception($"{_o.Mode} needs PlexiChore Desktop (virtual display provider), EngineHost is mirror-only");
        if (!HostChecks.PortListening()) throw new Exception("nothing listens on TCP 47800 (server paused?)");

        // ---------------- transport ----------------
        _r.Host = _o.Transport == "wifi-direct" ? (HostChecks.PickLanIp(_o.HostIp ?? "192.168.0.132") ?? throw new Exception("no LAN IPv4")) : "127.0.0.1";
        EnsureTransport();
        _r.ReverseOwnerBefore = ReverseOwner();
        Log($"reverse owner: {_r.ReverseOwnerBefore} ({ReverseList.Classify(_r.ReverseOwnerBefore)}), host={_r.Host}, control serial={_ctl}");

        // ---------------- session start ----------------
        var (off, rtt, method) = _adb.ClockOffsetPersistent(_ctl);
        _r.ClockOffsetMs = off; _r.ClockRttMs = rtt;
        Log($"clock offset tablet-PC {off:F1} ms (best rtt {rtt:F1} ms, {method})");
        if (_o.ForceStop) { _adb.Shell(_ctl, $"am force-stop {Adb.Package}"); Thread.Sleep(1500); }
        var t0 = DateTime.Now;
        var am = _adb.Shell(_ctl, $"am start -n {Adb.Package}/.display.DebugDisplay --es host {_r.Host} --es codec {_o.Codec} --es mode {_o.Mode} --ez stats true");
        Log($"am start ({am.Ms:F0} ms): {am.All.Replace('\n', ' ')}");
        var eng = WaitForConfig(t0);
        _r.HelloTransport = eng.HelloTransport; _r.HelloMode = eng.HelloMode; _r.Config = eng.ConfigText; _r.Encoder = eng.Encoder;
        _r.CaptureSource = eng.CaptureSource; _r.CaptureRect = eng.CaptureRect; _r.VirtualRect = eng.VirtualRect; _r.ExtendFellBack = eng.ExtendFellBackToMirror;
        if (eng.Hello is { } h) _r.AmToHelloMs = (h - t0).TotalMilliseconds;
        if (eng.Config is { } c) _r.AmToConfigMs = (c - t0).TotalMilliseconds;
        if (eng.Config == null) throw new Exception(eng.Hello == null
            ? (_o.Transport == "wifi-direct" ? $"no HELLO from Wi-Fi within {_o.ConnectTimeoutS}s: firewall ({_r.Firewall}) or tablet not on the LAN" : "no HELLO: reverse/adb transport broken?")
            : "HELLO but no CONFIG (approval pending / pipeline failure)");
        string wantT = _o.Transport == "wifi-direct" ? "Wi-Fi" : "USB";
        if (eng.HelloTransport != wantT) Note($"engine saw transport {eng.HelloTransport}, expected {wantT}");
        if (_o.Mode != "mirror" && eng.ExtendFellBackToMirror) Note($"{_o.Mode.ToUpperInvariant()} FELL BACK TO MIRROR (virtual display attach failed)");
        _r.ScaleApplied = eng.ScaleApplied;
        if (_o.Mode != "mirror")
        {
            _r.VirtualAttach = eng.VirtualAttached == null ? "" : eng.VirtualReused ? "warm" : "cold";
            if (eng.ScaleApplied != 200) Note($"virtual monitor scale {(eng.ScaleApplied == 0 ? "not logged" : eng.ScaleApplied + "%")} (expected 200%)");
        }
        Log($"HELLO +{_r.AmToHelloMs:F0} ms via {eng.HelloTransport}, CONFIG +{_r.AmToConfigMs:F0} ms: {eng.ConfigText}");

        FirstFrame(t0);

        // ---------------- layer ----------------
        _r.Layer = FindLayer() ?? throw new Exception("PlexiChore SurfaceView layer not found / --latency empty");
        Log($"layer: {_r.Layer}");

        // ---------------- target monitor ----------------
        if (_o.Mode != "mirror") Thread.Sleep(1000); // let the virtual monitor's position / DPI settle before reading bounds
        var mon = ResolveMonitor(eng);
        _r.Monitor = mon.ToString();
        Log($"motion target: {mon}");
        if (EngineLog.ParseRect(eng.CaptureRect) is { } cr && cr != mon.Bounds) Note($"engine capture rect {cr} != monitor bounds {mon.Bounds} (DPI/coords mismatch?)");

        Thread.Sleep(1500); // let the first IDR / bitrate ramp settle
        foreach (var m in _o.Motions) _r.Phases.Add(RunPhase(m, mon));
        if (_o.Taps > 0) InputLatency(mon);

        _r.ReverseOwnerAfter = ReverseOwner();
        if (_r.ReverseOwnerAfter != _r.ReverseOwnerBefore) Note($"reverse owner changed during run: {_r.ReverseOwnerBefore} -> {_r.ReverseOwnerAfter} (AdbManager re-applied?)");
        var end = EngineLog.Summarize(EngineLog.Read(EngineLog.PathFor(t0), t0, t0, DateTime.Now));
        if (end.SessionEnded != null) Note($"session ended during run: {end.EndReason}");
    }

    // ---------- transport ----------
    private string? ReverseOwner() => ReverseList.Owner(_adb.Dev(_ctl, "reverse --list").Output);

    private void EnsureTransport()
    {
        string fwd = $"reverse tcp:{HostChecks.Port} tcp:{HostChecks.Port}", rm = $"reverse --remove tcp:{HostChecks.Port}";
        switch (_o.Transport)
        {
            case "usb":
            case "wireless-adb":
            {
                string target = _o.Transport == "usb" ? Adb.UsbSerial : Adb.WirelessSerial;
                string other = _o.Transport == "usb" ? Adb.WirelessSerial : Adb.UsbSerial;
                string want = _o.Transport == "usb" ? "usb" : "wireless";
                // adbd keeps ONE listener per port, owned by the transport that applied it last: applying on the target
                // takes it over. Only if that does not stick, remove via the other transport and re-apply.
                var r = _adb.Dev(target, fwd);
                if (!r.Ok) throw new Exception($"adb -s {target} {fwd}: {r.All}");
                var owner = ReverseList.Owner(_adb.Dev(target, "reverse --list").Output);
                if (ReverseList.Classify(owner) != want)
                {
                    Log($"reverse owner {owner} != {want}: removing via {other} and re-applying");
                    _adb.Dev(other, rm);
                    _adb.Dev(target, fwd);
                    owner = ReverseList.Owner(_adb.Dev(target, "reverse --list").Output);
                    if (ReverseList.Classify(owner) != want) throw new Exception($"could not make {want} own tcp:47800 (owner {owner})");
                }
                break;
            }
            case "wifi-direct":
            {
                // The tablet dials the LAN IP, so the adb reverse listener is irrelevant (and AdbManager would re-add it).
                var app = HostChecks.PlexiChoreApp();
                var cat = HostChecks.NetworkCategory();
                var prof = cat.Contains("Private") ? "Private" : cat.Contains("DomainAuthenticated") ? "Domain" : "Public";
                Log("checking Windows Firewall (read-only)...");
                _r.Firewall = $"{cat}: " + HostChecks.FirewallVerdict(HostChecks.InboundRules(), app?.Path, prof);
                Log("firewall: " + _r.Firewall);
                if (_r.Firewall.Contains("BLOCKED") || _r.Firewall.Contains("NO allow")) Note("firewall may block wifi-direct: " + _r.Firewall);
                var ping = _adb.Shell(_ctl, $"ping -c 5 -i 0.2 -W 1 {_r.Host}", 15000);
                var line = ping.Output.Split('\n').FirstOrDefault(l => l.Contains("rtt") || l.Contains("round-trip"))?.Trim();
                Log($"tablet -> {_r.Host} ping: {line ?? "no reply (ICMP is blocked by default on Windows; not conclusive)"}");
                if (line != null) _r.Notes.Add("wifi ping " + line);
                break;
            }
            default: throw new ArgumentException("transport must be usb | wireless-adb | wifi-direct");
        }
    }

    // ---------- connect ----------
    private EngineLogSummary WaitForConfig(DateTime t0)
    {
        var deadline = t0.AddSeconds(_o.ConnectTimeoutS);
        var path = EngineLog.PathFor(t0);
        bool prompted = false;
        while (true)
        {
            var s = EngineLog.Summarize(EngineLog.Read(path, t0, t0.AddMilliseconds(-50), DateTime.Now.AddSeconds(1)));
            if (s.Config != null) { Thread.Sleep(300); return EngineLog.Summarize(EngineLog.Read(path, t0, t0.AddMilliseconds(-50), DateTime.Now.AddSeconds(1))); }
            if (s.Hello != null && s.HelloTransport == "Wi-Fi" && !prompted && DateTime.Now - s.Hello.Value > TimeSpan.FromSeconds(2))
            {
                prompted = true; _r.ApprovalNeeded = true;
                deadline = DateTime.Now.AddSeconds(_o.ApproveTimeoutS);
                Console.Beep();
                Log($">>> Wi-Fi pairing approval needed: approve the tablet in PlexiChore Desktop (and trust it) within {_o.ApproveTimeoutS}s <<<");
            }
            if (DateTime.Now > deadline) return s;
            Thread.Sleep(250);
        }
    }

    private void FirstFrame(DateTime t0)
    {
        // logcat epoch timestamps are tablet wall clock; convert with the measured offset.
        LogcatLine? first = null;
        var until = DateTime.Now.AddSeconds(6);
        List<LogcatLine> lines = new();
        while (DateTime.Now < until)
        {
            var lc = _adb.Shell(_ctl, "logcat -d -v epoch -t 4000 PlexiDisplay:V PlexiCore:V PlexiH264:V PlexiVideo:V PlexiSession:V *:S", 15000);
            lines = Logcat.Parse(lc.Output);
            double t0Tab = ((t0.ToUniversalTime() - DateTime.UnixEpoch).TotalMilliseconds + _r.ClockOffsetMs) / 1000.0 - 0.5;
            first = lines.FirstOrDefault(l => l.Epoch >= t0Tab && l.Tag == "PlexiH264" && l.Message.StartsWith("Output format"));
            if (first != null) break;
            Thread.Sleep(700);
        }
        File.WriteAllLines(Path.Combine(_out, "logcat-connect.txt"), lines.Select(l => $"{l.Epoch:F6} {l.Level} {l.Tag}: {l.Message}"));
        if (first == null) { Note("first decoded frame not seen in logcat (PlexiH264 'Output format')"); return; }
        double pcMs = first.Epoch * 1000 - _r.ClockOffsetMs;
        _r.AmToFirstFrameMs = pcMs - (t0.ToUniversalTime() - DateTime.UnixEpoch).TotalMilliseconds;
        Log($"first decoded frame +{_r.AmToFirstFrameMs:F0} ms (±{_r.ClockRttMs / 2:F0})");
    }

    // ---------- SurfaceFlinger ----------
    private string? FindLayer(int attempts = 10)
    {
        for (int attempt = 0; attempt < attempts; attempt++)
        {
            var list = _adb.Shell(_ctl, "dumpsys SurfaceFlinger --list", 15000).Output;
            foreach (var cand in SfLayers.FindVideoLayers(list))
                foreach (var v in SfLayers.Variants(cand))
                {
                    var d = SfLatencyAccumulator.Parse(Latency(v));
                    if (d.Rows.Count > 0) return v;
                }
            Thread.Sleep(500);
        }
        return null;
    }

    private string Latency(string layer) => _adb.Shell(_ctl, $"dumpsys SurfaceFlinger --latency '{layer.Replace("'", "")}'", 10000).Output;

    private PhaseResult RunPhase(string motion, MonitorDesc mon)
    {
        var pr = new PhaseResult { Motion = motion };
        Log($"-- phase {motion}: {_o.Seconds}s on {mon}");
        _adb.Shell(_ctl, $"dumpsys gfxinfo {Adb.Package} reset");
        var acc = new SfLatencyAccumulator();
        var dumps = new StringBuilder();
        long startMark = 0, endMark = 0;
        int phase = 0; // 0 = before, 1 = measuring, 2 = done measuring (motion still running for the screencap)
        var stop = new CancellationTokenSource();
        var motionStarted = new ManualResetEventSlim();
        DateTime mStart = default, mEnd = default;

        var relayers = new List<string>();
        var poller = new Thread(() =>
        {
            var sw = Stopwatch.StartNew();
            int empty = 0;
            while (!stop.IsCancellationRequested)
            {
                var txt = Latency(_r.Layer);
                if (acc.Add(txt) == 0 && SfLatencyAccumulator.Parse(txt).Rows.Count == 0 && ++empty >= 3)
                {
                    empty = 0;
                    var nl = FindLayer(2);
                    if (nl != null && nl != _r.Layer) { relayers.Add($"{DateTime.Now:HH:mm:ss} {nl}"); _r.Layer = nl; }
                }
                dumps.Append("=== ").Append(DateTime.Now.ToString("HH:mm:ss.fff")).Append('\n').Append(txt);
                long max = acc.MaxPresent;
                if (phase == 0 && motionStarted.IsSet) { startMark = max; phase = 1; mStart = DateTime.Now; sw.Restart(); }
                else if (phase == 1 && sw.Elapsed.TotalSeconds >= _o.Seconds) { endMark = max; phase = 2; mEnd = DateTime.Now; }
                Thread.Sleep(600); // ring buffer = 128 frames (>1 s even at 120 fps); a dumpsys round trip adds ~50-150 ms
            }
        }) { IsBackground = true, Name = "sf-poll" };
        poller.Start();

        double runFor = _o.Seconds + 3; // + tail for the screencap, + poll granularity
        string? shot = null;
        var shooter = new Thread(() =>
        {
            while (phase < 2 && !stop.IsCancellationRequested) Thread.Sleep(50);
            Thread.Sleep(200);
            shot = Path.Combine(_out, $"overlay-{motion}.png");
            var png = _adb.ExecOutBinary(_ctl, "screencap -p");
            if (png.Length > 1000) File.WriteAllBytes(shot, png); else shot = null;
        }) { IsBackground = true };
        shooter.Start();

        try
        {
            // the measurement window opens when the generator reports its first tick / presented frame
            pr.Source = motion switch
            {
                "cursor" => CursorMotion.Run(mon.Bounds, runFor, _o.CursorHz, started: motionStarted.Set),
                "anim" => AnimWindow.Run(mon.Bounds, runFor, _o.AnimFps, started: motionStarted.Set),
                "idle" => IdleFor(runFor, motionStarted.Set),
                _ => throw new ArgumentException("motion must be cursor | anim | idle"),
            };
        }
        catch (Exception ex) { pr.Error = ex.Message; }
        shooter.Join(10000);
        stop.Cancel(); poller.Join(5000);
        if (endMark == 0) { endMark = acc.MaxPresent; mEnd = DateTime.Now; }
        pr.Screencap = shot;
        File.WriteAllText(Path.Combine(_out, $"sf-latency-{motion}.txt"), dumps.ToString());
        pr.Tablet = acc.Compute(_o.ExpectedFps, startMark + 1, endMark);
        Log($"tablet: {pr.Tablet}");
        Log($"source: {pr.Source}");

        var eng = EngineLog.Summarize(EngineLog.Read(EngineLog.PathFor(mStart), mStart, mStart, mEnd));
        pr.EncoderBusyDrops = eng.EncoderBusyDrops; pr.HostPerfSamples = eng.Perf.Count;
        pr.HostFps = eng.PerfAvg("fps"); pr.HostComposeMs = eng.PerfAvg("compose"); pr.HostConvertMs = eng.PerfAvg("convert");
        pr.HostEncodeCallMs = eng.PerfAvg("encodeCall"); pr.HostEncLatMs = eng.PerfAvg("lat"); pr.HostEncLatMaxMs = eng.PerfMax("max"); pr.HostBusy = eng.PerfSum("busy");
        Log($"host: perf samples {pr.HostPerfSamples}, fps {pr.HostFps:F1}, encodeCall {pr.HostEncodeCallMs:F2} ms, enc lat {pr.HostEncLatMs:F2} (max {pr.HostEncLatMaxMs:F2}), busy {pr.HostBusy}, 'Encoder busy' drops {pr.EncoderBusyDrops}");
        pr.Reconfigs = eng.Configs; pr.Adaptive = eng.Adaptive; // any CONFIG inside a phase window is a mid-session re-CONFIG
        foreach (var rl in relayers) pr.Reconfigs.Add("SurfaceView layer changed " + rl);
        if (pr.Reconfigs.Count > 0) Log("re-CONFIG: " + string.Join(" | ", pr.Reconfigs));
        if (pr.Adaptive.Count > 0) Log("adaptive: " + string.Join(" | ", pr.Adaptive));
        PlexiStats(pr, mStart, mEnd);
        pr.GfxInfo = GfxInfo.Parse(_adb.Shell(_ctl, $"dumpsys gfxinfo {Adb.Package}").Output);
        return pr;
    }

    private void PlexiStats(PhaseResult pr, DateTime from, DateTime to)
    {
        var since = Tab(from).ToString("F3", CultureInfo.InvariantCulture);
        // -T <epoch>: -t N would count lines BEFORE the tag filter (only ~6 s of a busy log)
        var lc = _adb.Shell(_ctl, $"logcat -d -v epoch -T {since} -s PlexiStats", 15000).Output;
        double Tab(DateTime t) => ((t.ToUniversalTime() - DateTime.UnixEpoch).TotalMilliseconds + _r.ClockOffsetMs) / 1000.0;
        // each line summarises the preceding second: skip the first partial second of the window
        var rows = Logcat.Parse(lc).Where(l => l.Tag == "PlexiStats" && l.Epoch >= Tab(from) + 1.0 && l.Epoch <= Tab(to) + 0.2).ToList();
        File.WriteAllLines(Path.Combine(_out, $"plexistats-{pr.Motion}.txt"), rows.Select(r => $"{r.Epoch:F3} {r.Message}"));
        var kv = rows.Select(r => EngineLog.ParseKeyValues(r.Message)).ToList();
        double Avg(string k) { var v = kv.Where(d => d.ContainsKey(k)).Select(d => d[k]).ToList(); return v.Count == 0 ? double.NaN : v.Average(); }
        double Max(string k) { var v = kv.Where(d => d.ContainsKey(k)).Select(d => d[k]).ToList(); return v.Count == 0 ? double.NaN : v.Max(); }
        double Sum(string k) { var v = kv.Where(d => d.ContainsKey(k)).Select(d => d[k]).ToList(); return v.Count == 0 ? double.NaN : v.Sum(); }
        pr.TabStatsSamples = rows.Count;
        pr.TabFps = Avg("fps"); pr.TabRttMs = Avg("rtt"); pr.TabRttMaxMs = Max("rtt"); pr.TabMaxGapMs = Max("maxGap"); pr.TabNetGapMs = Max("netGap");
        pr.TabDecodeMs = Avg("decode"); pr.TabKbps = Avg("kbps"); pr.TabHitches = Sum("hitches"); pr.TabDropped = Max("dropped") - (kv.FirstOrDefault(d => d.ContainsKey("dropped"))?["dropped"] ?? 0); // the tablet counter is cumulative per connection: frames dropped during this phase
        pr.TabVia = rows.Select(r => System.Text.RegularExpressions.Regex.Match(r.Message, @" via (.*)$").Groups[1].Value).LastOrDefault();
        Log($"PlexiStats: n={rows.Count} fps {pr.TabFps:F1} rtt {pr.TabRttMs:F1} (max {pr.TabRttMaxMs:F1}) ms, maxGap {pr.TabMaxGapMs:F1} ms, netGap {pr.TabNetGapMs:F1} ms, hitches {pr.TabHitches}, dropped {pr.TabDropped}, decode {pr.TabDecodeMs:F1} ms, {pr.TabKbps / 1000:F1} Mbps via {pr.TabVia}");
    }

    private static TickReport IdleFor(double s, Action started) { started(); Thread.Sleep(TimeSpan.FromSeconds(s)); return new TickReport("idle", s, 0, 0, 0, 0, 0, 0, 0); }

    // ---------- input latency (approximate) ----------
    private void InputLatency(MonitorDesc mon)
    {
        // Taps land on our own topmost non-activating cover window, never on the user's desktop.
        var size = _adb.Shell(_ctl, "wm size").Output;
        var m = System.Text.RegularExpressions.Regex.Match(size, @"(\d+)x(\d+)\s*$", System.Text.RegularExpressions.RegexOptions.Multiline);
        int a = m.Success ? int.Parse(m.Groups[1].Value) : 2560, b = m.Success ? int.Parse(m.Groups[2].Value) : 1600;
        int tw = Math.Max(a, b), th = Math.Min(a, b); // DisplayActivity is sensorLandscape
        var changes = new List<(DateTime T, int X, int Y)>();
        var stop = new CancellationTokenSource();
        var watcher = new Thread(() =>
        {
            Native.GetCursorPos(out var last);
            while (!stop.IsCancellationRequested)
            {
                Native.GetCursorPos(out var p);
                if (p.X != last.X || p.Y != last.Y) { lock (changes) changes.Add((DateTime.UtcNow, p.X, p.Y)); last = p; }
                Thread.SpinWait(2000);
            }
        }) { IsBackground = true, Priority = ThreadPriority.Highest };
        var lat = new List<double>();
        var upper = new List<double>();
        int noChange = 0;
        using var sh = new PersistentShell(_adb, _ctl);
        var cover = new Thread(() => AnimWindow.Run(mon.Bounds, _o.Taps * 2.0 + 6, 30)) { IsBackground = true };
        cover.Start(); Thread.Sleep(1500); watcher.Start();
        for (int i = 0; i < _o.Taps; i++)
        {
            int x = (int)(tw * (i % 2 == 0 ? 0.35 : 0.65)), y = th / 2;
            var sent = DateTime.UtcNow;
            // `input` (a JVM, ~100-300 ms start-up) returns after the event was injected; the echo stamps that moment.
            var outLine = sh.Exec($"input tap {x} {y}; echo $EPOCHREALTIME", 8000);
            if (!double.TryParse(outLine.Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var tabDone)) continue;
            var doneOnPc = DateTime.UnixEpoch.AddMilliseconds(tabDone * 1000 - _r.ClockOffsetMs);
            Thread.Sleep(400);
            (DateTime T, int X, int Y)? hit;
            lock (changes) hit = changes.Where(c => c.T >= sent).Select(c => ((DateTime, int, int)?)c).FirstOrDefault();
            if (hit == null) { noChange++; continue; }
            lat.Add((hit.Value.T - doneOnPc).TotalMilliseconds);
            upper.Add((hit.Value.T - sent).TotalMilliseconds);
            Thread.Sleep(200);
        }
        stop.Cancel(); cover.Join(15000);
        _r.InputLatencyMs = lat.ToArray();
        var s = lat.OrderBy(v => v).ToList();
        _r.InputLatencyNote = s.Count == 0 ? $"no PC cursor movement for {noChange} taps (touch mode may not move the cursor)"
            : $"tablet `input` return -> PC cursor move: median {Stats.Percentile(s, 50):F0} ms, p90 {Stats.Percentile(s, 90):F0} ms (n={s.Count}, ±{_r.ClockRttMs / 2:F0} ms clock error; excludes touch-panel latency); PC send -> cursor move (incl. `input` start-up) median {Stats.Percentile(upper.OrderBy(v => v).ToList(), 50):F0} ms";
        Log("input: " + _r.InputLatencyNote);
    }

    private MonitorDesc ResolveMonitor(EngineLogSummary eng)
    {
        try { if (eng.CaptureSource != null) return Monitors.Resolve(eng.CaptureSource); } catch (Exception ex) { Note("capture monitor lookup: " + ex.Message); }
        try { if (_o.Mode == "extend" && eng.VirtualDevice != null) return Monitors.Resolve(eng.VirtualDevice); } catch { }
        return Monitors.Resolve(_o.Mode == "extend" ? "virtual" : "primary");
    }
}

public static class Report
{
    public static readonly JsonSerializerOptions Json = new() { WriteIndented = true, IncludeFields = true, NumberHandling = JsonNumberHandling.AllowNamedFloatingPointLiterals };

    public const string Header =
        "| Transport | Mode | Motion | am→HELLO / CONFIG / 1st frame (ms) | Tablet fps | Interval p50 / p95 / p99 / max (ms) | Stutters >2× | Janks >1.5× | PlexiStats fps / rtt (max) / maxGap / hitches | Source Hz | Host fps | submit / enc lat (max) ms | Enc busy | Re-CONFIG / adaptive | Overlay | Notes |\n" +
        "|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|";

    private static string F(double v, string fmt = "F0") => double.IsNaN(v) ? "–" : v.ToString(fmt, CultureInfo.InvariantCulture);

    public static IEnumerable<string> Rows(ScenarioResult r, string? dir = null)
    {
        string conn = $"{F(r.AmToHelloMs)} / {F(r.AmToConfigMs)} / {F(r.AmToFirstFrameMs)}";
        string notes = string.Join("; ", new[] { r.Error, r.ExtendFellBack ? "EXTEND→MIRROR fallback" : null, r.ApprovalNeeded ? "needed Wi-Fi approval" : null,
            r.ScaleApplied > 0 ? $"scale {r.ScaleApplied}%" : null, r.VirtualAttach.Length > 0 ? $"{r.VirtualAttach} attach" : null,
            r.HelloTransport != null ? $"via {r.HelloTransport}, adb owner {r.ReverseOwnerBefore ?? "none"}" : null }
            .Concat(r.Notes).Where(s => !string.IsNullOrEmpty(s)));
        if (r.Phases.Count == 0) { yield return $"| {r.Transport} | {r.Mode} | – | {conn} | – | – | – | – | – | – | – | – | – | – | – | {notes} |"; yield break; }
        foreach (var p in r.Phases)
        {
            var t = p.Tablet ?? FrameStats.Empty;
            string shot = p.Screencap != null ? $"[png]({Path.GetRelativePath(dir ?? ".", p.Screencap).Replace('\\', '/')})" : "–";
            string n = string.Join("; ", new[] { p.Error, notes, t.CoverageGaps > 0 ? $"{t.CoverageGaps} SF coverage gaps" : null }.Where(s => !string.IsNullOrEmpty(s)));
            yield return $"| {r.Transport} | {r.Mode} | {p.Motion} | {conn} | {F(t.AvgFps, "F1")} | {F(t.P50Ms, "F1")} / {F(t.P95Ms, "F1")} / {F(t.P99Ms, "F1")} / {F(t.MaxMs, "F1")} | {t.Stutters} | {t.Janks} | {F(p.TabFps, "F1")} / {F(p.TabRttMs, "F1")} ({F(p.TabRttMaxMs, "F0")}) / {F(p.TabMaxGapMs, "F0")} / {F(p.TabHitches)} | " +
                         $"{F(p.Source?.AchievedHz ?? double.NaN, "F1")} | {F(p.HostFps, "F1")} | {F(p.HostEncodeCallMs, "F2")} / {F(p.HostEncLatMs, "F1")} ({F(p.HostEncLatMaxMs, "F1")}) | {p.EncoderBusyDrops}{(double.IsNaN(p.HostBusy) ? "" : "/" + F(p.HostBusy))} | {(p.Reconfigs.Count + p.Adaptive.Count == 0 ? "none" : string.Join("<br>", p.Reconfigs.Concat(p.Adaptive)))} | {shot} | {n} |";
        }
        if (r.InputLatencyNote.Length > 0) yield return $"| {r.Transport} | {r.Mode} | input | – | – | – | – | – | – | – | – | – | – | – | – | {r.InputLatencyNote} |";
    }

    public static void Append(string resultsDir, ScenarioResult r, string scenarioDir)
    {
        var md = Path.GetFullPath(Path.Combine(resultsDir, "results.md"));
        var sb = new StringBuilder();
        if (!File.Exists(md)) sb.AppendLine("# PlexiChore smoothness benchmark").AppendLine().AppendLine(Header);
        foreach (var row in Rows(r, Path.GetDirectoryName(md))) sb.AppendLine(row);
        File.AppendAllText(md, sb.ToString());
        Console.WriteLine();
        Console.WriteLine(Header);
        foreach (var row in Rows(r, Path.GetDirectoryName(md))) Console.WriteLine(row);
        Console.WriteLine($"\n(appended to {md})");
    }

    /// Rebuilds a table from result.json files (e.g. after editing / for a subset).
    public static string Table(IEnumerable<string> jsonFiles, string relTo)
    {
        var sb = new StringBuilder(Header).Append('\n');
        foreach (var f in jsonFiles)
        {
            var r = JsonSerializer.Deserialize<ScenarioResult>(File.ReadAllText(f), Json);
            if (r != null) foreach (var row in Rows(r, relTo)) sb.Append(row).Append('\n');
        }
        return sb.ToString();
    }
}
