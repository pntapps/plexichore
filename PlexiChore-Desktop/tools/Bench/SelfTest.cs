using System.Text;

namespace PlexiBench;

/// Offline checks of every parser against captured / synthetic samples (no device, no network).
public static class SelfTest
{
    private static int _fail, _pass;

    private static void Check(bool ok, string what)
    {
        if (ok) _pass++; else _fail++;
        Console.WriteLine($"  [{(ok ? "PASS" : "FAIL")}] {what}");
    }

    private static string Sample(string name) => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "samples", name));

    public static int Run()
    {
        Console.WriteLine("SurfaceFlinger --list (Android 16 RequestedLayerState format)");
        var l16 = SfLayers.FindVideoLayers(Sample("sf-list-android16.txt"));
        Check(l16.Count == 3, $"3 SurfaceView candidates (got {l16.Count})");
        Check(l16.Count > 0 && l16[0] == "ee4ef9b SurfaceView[com.pntapps.plexichore/com.pntapps.plexichore.display.DebugDisplay]@0(BLAST)#75676",
              $"best = newest BLAST layer, full name incl. hash prefix and #seq (got '{l16.FirstOrDefault()}')");
        Check(!l16.Any(n => n.StartsWith("Background") || n.StartsWith("Bounds")), "Background/Bounds layers excluded");
        var variants = SfLayers.Variants(l16[0]).ToList();
        Check(variants.Contains("SurfaceView[com.pntapps.plexichore/com.pntapps.plexichore.display.DebugDisplay]@0(BLAST)"), "name variants include bare name");

        Console.WriteLine("SurfaceFlinger --list (legacy one-name-per-line)");
        var lOld = SfLayers.FindVideoLayers(Sample("sf-list-legacy.txt"));
        Check(lOld.Count == 2 && lOld[0].Contains("(BLAST)"), $"legacy: BLAST first (got {string.Join(" | ", lOld)})");

        Console.WriteLine("SurfaceFlinger --latency parsing");
        var real = SfLatencyAccumulator.Parse(Sample("sf-latency-real.txt"));
        Check(real.RefreshNs == 8333333, "refresh period line (120 Hz panel)");
        Check(real.Rows.Count == 7 && real.Rows[0].Actual == 411594204483922, "rows + actual-present column");
        var accReal = new SfLatencyAccumulator();
        accReal.Add(real);
        var sr = accReal.Compute(60);
        Check(sr.Frames == 7 && Math.Abs(sr.MaxMs - 33.3) < 0.1, $"real sample stats: {sr}");

        // Synthetic 60 fps stream, 600 frames, one 50 ms hitch at frame 300, one 30 ms jank at 400, polled as
        // overlapping 128-row windows with a pending (INT64_MAX) last row, like a live SF ring buffer.
        long t = 1_000_000_000_000, step = 16_666_667;
        var pres = new List<long>();
        for (int i = 0; i < 600; i++)
        {
            t += i == 300 ? 50_000_000 : i == 400 ? 30_000_000 : step;
            pres.Add(t);
        }
        var acc = new SfLatencyAccumulator();
        for (int e = 100; ; e += 60) // ~1 s polls, last one at the end of the stream
        {
            int end = Math.Min(e, 600);
            var sb = new StringBuilder("16666666\n");
            int start = Math.Max(0, end - 127);
            for (int i = start; i < end; i++) sb.Append($"{i}\t{pres[i]}\t{i}\n");
            sb.Append($"0\t{SfLatencyAccumulator.Pending}\t0\n");
            acc.Add(sb.ToString());
            if (end == 600) break;
        }
        var ss = acc.Compute(60);
        Check(ss.Frames == 600, $"merge/dedupe across overlapping polls: {ss.Frames} frames");
        Check(ss.Stutters == 1 && ss.Janks == 2, $"stutter (>33.3 ms) = 1, jank (>25 ms) = 2: got {ss.Stutters}/{ss.Janks}");
        Check(Math.Abs(ss.P50Ms - 16.67) < 0.05, $"p50 = 16.67 ms (got {ss.P50Ms:F2})");
        Check(Math.Abs(ss.MaxMs - 50) < 0.01, $"max = 50 ms (got {ss.MaxMs:F2})");
        Check(Math.Abs(ss.AvgFps - 599 / ((pres[^1] - pres[0]) / 1e9)) < 0.01 && ss.AvgFps > 59 && ss.AvgFps < 60, $"avg fps {ss.AvgFps:F2}");
        Check(ss.CoverageGaps == 0, "no coverage gap with 1 s polls");
        var win = acc.Compute(60, pres[100], pres[200]);
        Check(win.Frames == 101 && win.Stutters == 0, $"windowed stats [100..200]: {win.Frames} frames");

        // Polls too sparse (every 200 frames with a full 128-row buffer) must be flagged.
        var gap = new SfLatencyAccumulator();
        for (int end = 128; end <= 600; end += 200)
        {
            var sb = new StringBuilder("16666666\n");
            for (int i = end - 128; i < end; i++) sb.Append($"{i}\t{pres[i]}\t{i}\n");
            gap.Add(sb.ToString());
        }
        Check(gap.CoverageGaps == 2, $"sparse polling flagged as coverage gaps (got {gap.CoverageGaps})");

        Console.WriteLine("adb reverse --list");
        Check(ReverseList.Owner(Sample("reverse-list.txt")) == "UsbFfs" && ReverseList.Classify("UsbFfs") == "usb", "UsbFfs owner -> usb");
        Check(ReverseList.Classify("adb-ABC123XYZ-AbCdEf._adb-tls-connect._tcp") == "wireless" && ReverseList.Owner("") == null, "tls owner -> wireless; empty -> none");

        Console.WriteLine("engine log");
        var day = new DateTime(2026, 10, 20);
        var lines = EngineLog.ParseLines(Sample("engine-log.txt"), day).ToList();
        Check(lines.Count == 14, $"14 log lines parsed (got {lines.Count})");
        var s = EngineLog.Summarize(lines);
        Check(s.Hello == day.Add(TimeSpan.Parse("17:51:29.073")) && s.HelloTransport == "USB" && s.HelloMode == "extend", "HELLO time/transport/mode");
        Check(s.Config == day.Add(TimeSpan.Parse("17:51:33.196")) && s.CaptureSource == @"\\.\DISPLAY7" && s.Encoder == "hw:NVIDIA H.264 Encoder MFT", $"CONFIG source/encoder ({s.CaptureSource} / {s.Encoder})");
        Check(s.CaptureRect == "X=1920,Y=0,Width=2560,Height=1600" && EngineLog.ParseRect(s.CaptureRect) is { X: 1920, Width: 2560 }, "CONFIG capture rect");
        Check(s.VirtualDevice == @"\\.\DISPLAY7", "virtual display device");
        Check(s.VirtualRect == "X=1920,Y=0,Width=2560,Height=1600", "virtual display rect");
        Check(s.EncoderBusyDrops == 1 && s.Perf.Count == 2, "1 'Encoder busy' + 2 perf lines");
        Check(Math.Abs(s.PerfAvg("fps") - 58.5) < 1e-9 && s.PerfMax("max") == 19.4 && s.PerfSum("busy") == 2 && Math.Abs(s.PerfAvg("encodeCall") - 1.4) < 1e-9, "perf fields (fps/max/busy/encodeCall)");
        Check(s.SessionEnded == day.Add(TimeSpan.Parse("17:57:30.949")) && s.EndReason == "connection closed by tablet", "real session end (not the 'no HELLO' probe)");
        Check(s.ExtendFellBackToMirror, "extend->mirror fallback detected");
        var p = EngineLog.ParsePerf("perf: 60.0 fps compose 1 newField 3.5");
        Check(p["fps"] == 60 && p["newField"] == 3.5, "perf parser tolerates new fields");

        Console.WriteLine("engine log v2 (20:2x build: DDA cursor, adaptive encoder, display scale, grace period)");
        var s2 = EngineLog.Summarize(EngineLog.ParseLines(Sample("engine-log-v2.txt"), day));
        Check(s2.VirtualReused && s2.VirtualDevice == @"\\.\DISPLAY8", $"'reused' + 'attached (mode)' -> warm, device {s2.VirtualDevice}");
        Check(s2.ScaleApplied == 200, $"display scale applied 200% (got {s2.ScaleApplied})");
        Check(s2.Adaptive.Count == 2 && s2.Adaptive[0].Contains("Encoder slow at 1920x1200"), $"adaptive encoder events: {s2.Adaptive.Count}");
        Check(s2.Reconfigs.Count == 2 && s2.Reconfigs[^1].EndsWith("1920x1200 (adapt)"), $"re-CONFIGs: {string.Join(" | ", s2.Reconfigs)}");
        Check(s2.ExtendFellBackToMirror, "lower-case 'extend mode unavailable' detected");
        Check(s2.Perf.Count == 4 && Math.Abs(s2.Perf[0]["encodeCall"] - 15.15) < 1e-9 && s2.Perf[0].ContainsKey("lat") && s2.Perf[0]["gap"] == 32.7, "new perf wording: submit->encodeCall, latency->lat, max gap");
        var ps = EngineLog.ParseKeyValues("fps=59.8 rtt=3.1ms kbps=12000 decode=2.1ms dropped=0 maxGap=20.1ms hitches=1 netGap=18.0ms via USB 127.0.0.1");
        Check(ps["fps"] == 59.8 && ps["rtt"] == 3.1 && ps["maxGap"] == 20.1 && ps["hitches"] == 1 && ps["netGap"] == 18.0, "PlexiStats key=value parsing");

        Console.WriteLine("logcat -v epoch");
        var lc = Logcat.Parse(Sample("logcat-epoch.txt"));
        Check(lc.Count == 3 && lc[2].Tag == "PlexiH264" && lc[2].Message.StartsWith("Output format") && Math.Abs(lc[2].Epoch - 1760961090.012345) < 1e-6, "epoch/tag/message");

        Console.WriteLine("netsh firewall rules");
        var rules = HostChecks.ParseNetsh(Sample("netsh-sample.txt"));
        var exe = @"C:\Users\user\AndroidStudioProjects\PlexiChore-Desktop\dist\PlexiChore.exe";
        Check(rules.Count == 2, $"2 rules parsed (got {rules.Count})");
        Check(HostChecks.FirewallVerdict(rules, exe, "Private").StartsWith("allowed"), "Private -> allowed");
        Check(HostChecks.FirewallVerdict(rules, exe, "Public").StartsWith("BLOCKED"), "Public -> blocked");
        Check(HostChecks.FirewallVerdict(rules, @"C:\other\PlexiChore.exe", "Private").StartsWith("NO allow"), "other exe path -> no allow rule");

        Console.WriteLine("report");
        var r = new ScenarioResult { Transport = "usb", Mode = "mirror", AmToHelloMs = 812, AmToConfigMs = 1490, AmToFirstFrameMs = 1620, HelloTransport = "USB", ReverseOwnerBefore = "UsbFfs" };
        r.Phases.Add(new PhaseResult { Motion = "cursor", Tablet = ss, Source = new TickReport("cursor", 15, 1875, 125, 124.9, 0.05, 0.4, 1.2, 0), HostFps = 59.8, HostEncodeCallMs = 1.2, HostEncLatMs = 6.2, HostEncLatMaxMs = 11.3, HostBusy = 0 });
        var rows = Report.Rows(r, ".").ToList();
        Check(rows.Count == 1 && rows[0].Split('|').Length == Report.Header.Split('\n')[0].Split('|').Length, $"row column count matches header: {rows[0]}");
        var json = System.Text.Json.JsonSerializer.Serialize(r, Report.Json);
        try
        {
            var back = System.Text.Json.JsonSerializer.Deserialize<ScenarioResult>(json, Report.Json)!;
            Check(back.Phases[0].Tablet!.Frames == 600 && double.IsNaN(back.ClockOffsetMs), "result.json round trip (NaN-safe)");
        }
        catch (Exception ex) { Check(false, "result.json round trip: " + ex.Message); }

        Console.WriteLine($"\n{_pass} passed, {_fail} failed");
        return _fail == 0 ? 0 : 1;
    }
}
