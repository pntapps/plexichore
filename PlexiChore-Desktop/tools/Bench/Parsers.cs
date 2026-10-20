using System.Drawing;
using System.Globalization;
using System.Text.RegularExpressions;

namespace PlexiBench;

public static class Stats
{
    /// Linear-interpolated percentile of a SORTED list.
    public static double Percentile(IReadOnlyList<double> sorted, double p)
    {
        if (sorted.Count == 0) return double.NaN;
        double idx = (sorted.Count - 1) * p / 100.0;
        int lo = (int)Math.Floor(idx), hi = (int)Math.Ceiling(idx);
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (idx - lo);
    }
}

// ------------------------------------------------------------------ SurfaceFlinger --latency

public sealed record FrameStats(int Frames, double Seconds, double AvgFps, double P50Ms, double P95Ms, double P99Ms, double MaxMs,
    int Stutters, int Janks, double ExpectedMs, double RefreshMs, int CoverageGaps)
{
    public static readonly FrameStats Empty = new(0, 0, 0, double.NaN, double.NaN, double.NaN, double.NaN, 0, 0, 0, 0, 0);
    public override string ToString() =>
        $"{Frames} frames / {Seconds:F2}s = {AvgFps:F1} fps; interval p50 {P50Ms:F1} p95 {P95Ms:F1} p99 {P99Ms:F1} max {MaxMs:F1} ms; " +
        $"stutters(>{2 * ExpectedMs:F1}ms) {Stutters}, janks(>{1.5 * ExpectedMs:F1}ms) {Janks}; refresh {RefreshMs:F2} ms; coverage gaps {CoverageGaps}";
}

public sealed record LatencyDump(long RefreshNs, List<(long Desired, long Actual, long Ready)> Rows);

/// Accumulates `dumpsys SurfaceFlinger --latency <layer>` snapshots (each holds only the last ~128
/// frames, so it must be polled at least every ~1 s at 120 fps) and computes presentation statistics.
public sealed class SfLatencyAccumulator
{
    public const long Pending = long.MaxValue;
    private readonly SortedSet<long> _present = new();
    private long _lastMax;
    public long RefreshNs { get; private set; }
    public int Polls { get; private set; }
    public int CoverageGaps { get; private set; }

    /// Parses the text format: line 1 = refresh period (ns); then "desiredPresent\tactualPresent\tframeReady" (ns, CLOCK_MONOTONIC).
    /// Column 2 (actual present) is what reached the glass. 0 / INT64_MAX = unknown / still pending.
    public static LatencyDump Parse(string text)
    {
        var rows = new List<(long, long, long)>();
        long refresh = 0;
        bool first = true;
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            var cols = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (first)
            {
                first = false;
                if (cols.Length == 1 && long.TryParse(cols[0], out refresh)) continue;
            }
            if (cols.Length >= 3 && long.TryParse(cols[0], out var a) && long.TryParse(cols[1], out var b) && long.TryParse(cols[2], out var c))
                rows.Add((a, b, c));
        }
        return new LatencyDump(refresh, rows);
    }

    public int Add(string dumpText) => Add(Parse(dumpText));

    /// Returns the number of new presented frames.
    public int Add(LatencyDump d)
    {
        Polls++;
        if (d.RefreshNs > 0) RefreshNs = d.RefreshNs;
        var valid = d.Rows.Select(r => r.Actual).Where(t => t > 0 && t != Pending).OrderBy(t => t).ToList();
        if (valid.Count == 0) return 0;
        // A full ring buffer (>=127 rows) whose oldest entry is newer than anything we have seen means frames fell
        // out between polls (poll faster).
        if (_lastMax > 0 && d.Rows.Count >= 127 && valid[0] > _lastMax) CoverageGaps++;
        int added = 0;
        foreach (var t in valid) if (_present.Add(t)) added++;
        _lastMax = Math.Max(_lastMax, valid[^1]);
        return added;
    }

    public IReadOnlyCollection<long> Presents => _present;
    public long MaxPresent => _present.Count > 0 ? _present.Max : 0;

    /// Stats over presents within [fromNs, toNs] (CLOCK_MONOTONIC of the tablet; pass 0/long.MaxValue for all).
    public FrameStats Compute(double expectedFps = 60, long fromNs = 0, long toNs = long.MaxValue)
    {
        var p = _present.Where(t => t >= fromNs && t <= toNs).ToList();
        double expected = 1000.0 / expectedFps;
        if (p.Count < 2) return FrameStats.Empty with { Frames = p.Count, ExpectedMs = expected, RefreshMs = RefreshNs / 1e6 };
        var iv = new List<double>(p.Count - 1);
        for (int i = 1; i < p.Count; i++) iv.Add((p[i] - p[i - 1]) / 1e6);
        var s = iv.OrderBy(x => x).ToList();
        double secs = (p[^1] - p[0]) / 1e9;
        return new FrameStats(p.Count, secs, (p.Count - 1) / secs, Stats.Percentile(s, 50), Stats.Percentile(s, 95), Stats.Percentile(s, 99), s[^1],
            iv.Count(x => x > 2 * expected), iv.Count(x => x > 1.5 * expected), expected, RefreshNs / 1e6, CoverageGaps);
    }
}

public static class SfLayers
{
    private const string Pkg = "com.pntapps.plexichore";

    /// Extracts candidate layer names for the PlexiChore video SurfaceView from `dumpsys SurfaceFlinger --list`.
    /// Android 14+ prints `RequestedLayerState{<name> parentId=..}`; older versions print one bare name per line.
    /// Best candidate first: the BLAST SurfaceView layer with the highest sequence id (#n), i.e. the newest.
    public static List<string> FindVideoLayers(string listOutput)
    {
        var names = new List<string>();
        foreach (var raw in listOutput.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0) continue;
            var m = Regex.Match(line, @"^RequestedLayerState\{(.*?)(?:\s+(?:parentId|relativeParentId|z)=.*)?\}?$");
            var name = m.Success ? m.Groups[1].Value.Trim() : line;
            if (name.Contains("SurfaceView[" + Pkg, StringComparison.Ordinal) && !name.StartsWith("Background for", StringComparison.Ordinal)
                && !name.StartsWith("Bounds for", StringComparison.Ordinal))
                names.Add(name);
        }
        return names.Distinct()
            .OrderByDescending(n => n.Contains("(BLAST)"))
            .ThenByDescending(SeqId)
            .ToList();
    }

    /// Alternative spellings to try with --latency if the exact name yields no rows.
    public static IEnumerable<string> Variants(string name)
    {
        yield return name;
        var noSeq = Regex.Replace(name, @"#\d+$", "");
        if (noSeq != name) yield return noSeq;
        var noHash = Regex.Replace(name, @"^[0-9a-f]{5,8} ", "");
        if (noHash != name) { yield return noHash; yield return Regex.Replace(noHash, @"#\d+$", ""); }
    }

    private static long SeqId(string n) { var m = Regex.Match(n, @"#(\d+)$"); return m.Success ? long.Parse(m.Groups[1].Value) : 0; }
}

// ------------------------------------------------------------------ adb reverse --list

public static class ReverseList
{
    /// `adb reverse --list` lines look like "UsbFfs tcp:47800 tcp:47800" (cable) or "<transport> tcp:47800 tcp:47800".
    /// The first column names the transport that serves the device-side listener (adbd keeps ONE per port).
    public static string? Owner(string output, int port = 47800)
    {
        foreach (var raw in output.Split('\n'))
        {
            var cols = raw.Trim().Split(' ', StringSplitOptions.RemoveEmptyEntries);
            if (cols.Length >= 3 && cols[^2] == $"tcp:{port}") return cols[0];
        }
        return null;
    }

    public static string Classify(string? owner) => owner == null ? "none"
        : owner.Contains("usb", StringComparison.OrdinalIgnoreCase) ? "usb" : "wireless";
}

// ------------------------------------------------------------------ PlexiChore engine log

public sealed record EngineLine(DateTime Time, string Level, string Category, string Message);

public sealed class EngineLogSummary
{
    public DateTime? Hello, Config, VirtualAttached, SessionEnded;
    public string? HelloTransport, HelloMode, ConfigText, Encoder, CaptureSource, CaptureRect, VirtualDevice, VirtualRect, EndReason;
    public bool ExtendFellBackToMirror;
    public int EncoderBusyDrops;
    public bool AwaitingApproval, VirtualReused;
    public int ScaleApplied;
    public readonly List<string> Reconfigs = new(), Adaptive = new(), Configs = new(); // Configs = every CONFIG in the window

    public readonly List<Dictionary<string, double>> Perf = new();

    public double PerfAvg(string key) { var v = Perf.Where(p => p.ContainsKey(key)).Select(p => p[key]).ToList(); return v.Count == 0 ? double.NaN : v.Average(); }
    public double PerfMax(string key) { var v = Perf.Where(p => p.ContainsKey(key)).Select(p => p[key]).ToList(); return v.Count == 0 ? double.NaN : v.Max(); }
    public double PerfSum(string key) { var v = Perf.Where(p => p.ContainsKey(key)).Select(p => p[key]).ToList(); return v.Count == 0 ? double.NaN : v.Sum(); }
}

public static class EngineLog
{
    private static readonly Regex LineRx = new(@"^(\d\d:\d\d:\d\d\.\d{3}) \[(\w{3})\] ([\w.]+): (.*)$", RegexOptions.Compiled);

    public static string PathFor(DateTime day) => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "PlexiChore", "logs", $"plexichore-{day:yyyyMMdd}.log");

    /// Reads (shared) the lines of `day`'s log file with timestamps in [from, to].
    public static List<EngineLine> Read(string path, DateTime day, DateTime from, DateTime to)
    {
        if (!File.Exists(path)) return new();
        using var fs = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var sr = new StreamReader(fs);
        return ParseLines(sr.ReadToEnd(), day).Where(l => l.Time >= from && l.Time <= to).ToList();
    }

    private static string ConfigTag(EngineLine l, string msg)
    {
        var m = Regex.Match(msg, @": \w+ (\d+x\d+)@\d+ .*\((\w+)\)$");
        return $"{l.Time:HH:mm:ss} {(m.Success ? m.Groups[1].Value + " (" + m.Groups[2].Value + ")" : msg)}";
    }

    public static IEnumerable<EngineLine> ParseLines(string text, DateTime day)
    {
        foreach (var raw in text.Split('\n'))
        {
            var m = LineRx.Match(raw.TrimEnd('\r'));
            if (!m.Success) continue;
            var t = day.Date + TimeSpan.ParseExact(m.Groups[1].Value, @"hh\:mm\:ss\.fff", CultureInfo.InvariantCulture);
            yield return new EngineLine(t, m.Groups[2].Value, m.Groups[3].Value, m.Groups[4].Value);
        }
    }

    public static EngineLogSummary Summarize(IEnumerable<EngineLine> lines)
    {
        var s = new EngineLogSummary();
        foreach (var l in lines)
        {
            var msg = l.Message;
            Match m;
            if (s.Hello == null && (m = Regex.Match(msg, @"^HELLO from .* via (\S+) .*mode=(\w+)")).Success)
            { s.Hello = l.Time; s.HelloTransport = m.Groups[1].Value; s.HelloMode = m.Groups[2].Value; }
            else if (s.Config == null && msg.StartsWith("CONFIG -> "))
            {
                s.Configs.Add(ConfigTag(l, msg));
                s.Config = l.Time; s.ConfigText = msg;
                m = Regex.Match(msg, @"from (\\\\\.\\\S+) \{(X=-?\d+,Y=-?\d+,Width=\d+,Height=\d+)\} encoder=(.*?)(?: \(\w+\))?$");
                if (m.Success) { s.CaptureSource = m.Groups[1].Value; s.CaptureRect = m.Groups[2].Value; s.Encoder = m.Groups[3].Value; }
            }
            else if (msg.StartsWith("CONFIG -> "))
            {
                // re-CONFIG mid-session (adaptive resolution, resize, fallback)
                s.Reconfigs.Add(ConfigTag(l, msg)); s.Configs.Add(ConfigTag(l, msg));
            }
            // "Virtual display attached: dev {..}" (old) / "Virtual display attached (extend): dev {..}" / "Virtual display reused (attached already): dev {..}"
            else if ((m = Regex.Match(msg, @"^Virtual display (attached|reused)(?: \([^)]*\))?: (\S+) \{(.*)\}")).Success)
            { s.VirtualAttached = l.Time; s.VirtualReused |= m.Groups[1].Value == "reused"; s.VirtualDevice = m.Groups[2].Value; s.VirtualRect = m.Groups[3].Value; }
            else if (Regex.IsMatch(msg, @"^\w+ mode unavailable, using mirror", RegexOptions.IgnoreCase)) s.ExtendFellBackToMirror = true;
            else if (l.Category == "Engine" && (m = Regex.Match(msg, @"^Display scale \S+: .*applied (\d+)%")).Success) s.ScaleApplied = int.Parse(m.Groups[1].Value);
            else if (msg.StartsWith("Encoder slow") || msg.StartsWith("Encoder too slow") || msg.StartsWith("Encoder still too slow")
                     || msg.StartsWith("Full-motion content") || msg.StartsWith("Content calm") || msg.StartsWith("Encode size now")) s.Adaptive.Add($"{l.Time:HH:mm:ss} {msg}");
            else if (msg.StartsWith("Encoder busy")) s.EncoderBusyDrops++;
            else if (msg.StartsWith("perf: ")) s.Perf.Add(ParsePerf(msg));
            else if (Regex.IsMatch(msg, @"(?i)approv|pairing")) s.AwaitingApproval = true;
            else if (s.SessionEnded == null && s.Hello != null && (m = Regex.Match(msg, @"^Session .* ended: (.*)$")).Success && !msg.EndsWith("no HELLO"))
            { s.SessionEnded = l.Time; s.EndReason = m.Groups[1].Value; }
        }
        return s;
    }

    /// "perf: 59.8 fps (ptrOnly 12) compose 0.41 convert 0.30 encodeCall 1.20 ms | enc wait 0.10 lat 6.20 max 11.30 busy 0"
    /// -> {fps, ptrOnly, compose, convert, encodeCall, wait, lat, max, busy}. Tolerant of added/removed fields.
    public static Dictionary<string, double> ParsePerf(string msg)
    {
        var d = new Dictionary<string, double>();
        var body = msg.StartsWith("perf: ") ? msg[6..] : msg;
        var lead = Regex.Match(body, @"^(-?[\d.]+) fps");
        if (lead.Success) d["fps"] = double.Parse(lead.Groups[1].Value, CultureInfo.InvariantCulture);
        foreach (Match m in Regex.Matches(body, @"([A-Za-z][A-Za-z]*)\s+(-?\d+(?:\.\d+)?)"))
            d[m.Groups[1].Value] = double.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
        // newer engine wording: "max gap 32.4 ms ... submit 0.39 ms | encoder wait 0.36 latency 32.09 max 32.57 busy 0"
        if (!d.ContainsKey("encodeCall") && d.TryGetValue("submit", out var sub)) d["encodeCall"] = sub;
        if (!d.ContainsKey("lat") && d.TryGetValue("latency", out var lat)) d["lat"] = lat;
        return d;
    }

    /// PlexiStats (tablet, 1/s): "fps=60.0 rtt=3.1ms kbps=12000 decode=2.1ms dropped=0 maxGap=20.1ms hitches=0 netGap=18.0ms via USB 127.0.0.1"
    public static Dictionary<string, double> ParseKeyValues(string msg)
    {
        var d = new Dictionary<string, double>();
        foreach (Match m in Regex.Matches(msg, @"(\w+)=(-?\d+(?:\.\d+)?)"))
            d[m.Groups[1].Value] = double.Parse(m.Groups[2].Value, CultureInfo.InvariantCulture);
        return d;
    }

    public static Rectangle? ParseRect(string? s)
    {
        if (s == null) return null;
        var m = Regex.Match(s, @"X=(-?\d+),Y=(-?\d+),Width=(\d+),Height=(\d+)");
        return m.Success ? new Rectangle(int.Parse(m.Groups[1].Value), int.Parse(m.Groups[2].Value), int.Parse(m.Groups[3].Value), int.Parse(m.Groups[4].Value)) : null;
    }
}

// ------------------------------------------------------------------ logcat (-v epoch)

public sealed record LogcatLine(double Epoch, string Level, string Tag, string Message);

public static class Logcat
{
    // "1729430000.123456  1234  1250 I PlexiH264: Started c2.qti.avc.decoder 1920x1080@60"
    private static readonly Regex Rx = new(@"^\s*(\d+\.\d+)\s+\d+\s+\d+\s+([VDIWEF])\s+(.+?)\s*:\s(.*)$", RegexOptions.Compiled);

    public static List<LogcatLine> Parse(string text) => text.Split('\n')
        .Select(l => Rx.Match(l.TrimEnd('\r')))
        .Where(m => m.Success)
        .Select(m => new LogcatLine(double.Parse(m.Groups[1].Value, CultureInfo.InvariantCulture), m.Groups[2].Value, m.Groups[3].Value.Trim(), m.Groups[4].Value))
        .ToList();
}

// ------------------------------------------------------------------ dumpsys gfxinfo

public static class GfxInfo
{
    public static Dictionary<string, string> Parse(string text)
    {
        var d = new Dictionary<string, string>();
        foreach (var key in new[] { "Total frames rendered", "Janky frames", "50th percentile", "90th percentile", "95th percentile", "99th percentile",
                                     "Number Missed Vsync", "Number Slow UI thread", "Number Frame deadline missed" })
        {
            var m = Regex.Match(text, Regex.Escape(key) + @":\s*([^\r\n]+)");
            if (m.Success) d[key] = m.Groups[1].Value.Trim();
        }
        return d;
    }
}
