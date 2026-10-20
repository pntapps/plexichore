using System.Globalization;
using System.Xml.Linq;
using Microsoft.Win32;

namespace PlexiChore.App.VirtualDisplay;

public enum AddModeResult { Added, AlreadyPresent, CapReached, Invalid }

/// Reads/writes the Virtual Display Driver's vdd_settings.xml (default C:\VirtualDisplayDriver\vdd_settings.xml,
/// overridable by HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver\VDDPATH). Preserves unknown elements.
///
/// The driver only reads this file when the device starts (install / elevated device restart). Its mode list must
/// stay COMPACT: every &lt;g_refresh_rate&gt; is multiplied across all unique resolutions, and with too many modes
/// (e.g. 28 resolutions × 5 rates = 140) IddCxMonitorArrival fails with STATUS_NOT_SUPPORTED (0xC00000BB, upstream
/// issue #254) — the adapter starts but no monitor appears. 16 resolutions @60 Hz (32 generated modes) works; the
/// preset list is 16 landscape + 3 portrait = 19 resolutions (38 generated modes), within the 24 / 48 caps.
public sealed class VddSettingsFile
{
    public const string DefaultDir = @"C:\VirtualDisplayDriver";
    public const string FileName = "vdd_settings.xml";

    /// Hard caps (see class remarks). Enforced by <see cref="Normalize"/> and <see cref="TryAddMode"/>.
    public const int MaxResolutions = 24;
    public const int MaxGlobalRefreshRates = 2;
    public const int MaxGeneratedModes = 48;
    public const int PresetHz = 60;

    /// Compact tablet preset list (verified working on Win10 19045 / IddCx 0x1501). Each @60 Hz, one global 60 Hz.
    public static readonly (int W, int H)[] PresetModes =
    {
        (2560, 1600), (1920, 1200), (1280, 800), (2880, 1800), (2000, 1200), (2400, 1600), (3000, 2000), (2732, 2048),
        (2048, 1536), (1600, 1000), (2560, 1440), (1920, 1080), (1366, 768), (2800, 1752), (2960, 1848), (1440, 900),
        // portrait (tablet held upright, Android 16+ large screens ignore orientation locks): 19 resolutions = 38 modes
        (1600, 2560), (1200, 1920), (1752, 2800),
    };

    /// &lt;options&gt; values written at install/repair (the driver reads all of them; missing values default badly).
    private static readonly (string Name, string Value)[] OptionDefaults =
    {
        ("CustomEdid", "false"), ("PreventSpoof", "false"), ("EdidCeaOverride", "false"), ("HardwareCursor", "true"),
        ("SendLogsThroughPipe", "false"), ("SDR10bit", "false"), ("HDRPlus", "false"),
        ("logging", "false"), ("debuglogging", "false"),
    };

    /// &lt;cursor&gt; values (missing ints are read as -1 by the driver).
    private static readonly (string Name, string Value)[] CursorDefaults =
    {
        ("HardwareCursor", "true"), ("CursorMaxX", "128"), ("CursorMaxY", "128"),
        ("AlphaCursorSupport", "true"), ("XorCursorSupportLevel", "2"),
    };

    private static readonly (string Name, string Value)[] ColourDefaults =
    {
        ("SDR10bit", "false"), ("HDRPlus", "false"), ("ColourFormat", "RGB"),
    };

    private const string ManagedComment =
        " Managed by PlexiChore Desktop. Keep the mode list compact: too many modes stop the virtual monitor from starting. ";

    public XDocument Document { get; }
    public string Path { get; }

    private VddSettingsFile(string path, XDocument doc) { Path = path; Document = doc; }

    /// Directory the driver reads its settings from.
    public static string ResolveDirectory()
    {
        try
        {
            using var k = Registry.LocalMachine.OpenSubKey(@"SOFTWARE\MikeTheTech\VirtualDisplayDriver");
            if (k?.GetValue("VDDPATH") is string p && p.Length > 0) return p;
        }
        catch { }
        return DefaultDir;
    }

    public static string ResolvePath() => System.IO.Path.Combine(ResolveDirectory(), FileName);

    public static VddSettingsFile Load(string path)
    {
        XDocument doc;
        if (File.Exists(path))
        {
            try { doc = XDocument.Load(path); }
            catch { doc = CreateDefault(1); }
        }
        else doc = CreateDefault(1);
        if (doc.Root?.Name != "vdd_settings") doc = CreateDefault(1);
        return new VddSettingsFile(path, doc);
    }

    /// A complete, compact settings document (same structure as the known-good live file).
    public static XDocument CreateDefault(int monitorCount)
    {
        var root = new XElement("vdd_settings",
            new XComment(ManagedComment),
            new XElement("monitors", new XElement("count", monitorCount)),
            new XElement("gpu", new XElement("friendlyname", "default")),
            new XElement("global", new XElement("g_refresh_rate", PresetHz)),
            new XElement("resolutions", PresetModes.Select(m => Res(m.W, m.H, PresetHz))),
            new XElement("options", OptionDefaults.Select(o => new XElement(o.Name, o.Value))),
            new XElement("cursor", CursorDefaults.Select(o => new XElement(o.Name, o.Value))),
            new XElement("colour", ColourDefaults.Select(o => new XElement(o.Name, o.Value))));
        return new XDocument(new XDeclaration("1.0", "utf-8", null), root);
    }

    private static XElement Res(int w, int h, int hz) =>
        new("resolution", new XElement("width", w), new XElement("height", h), new XElement("refresh_rate", hz));

    private XElement Root => Document.Root!;

    public int MonitorCount
    {
        get => int.TryParse(Root.Element("monitors")?.Element("count")?.Value, out var c) ? c : 1;
        set
        {
            var mon = Root.Element("monitors") ?? AddFirst(new XElement("monitors"));
            var cnt = mon.Element("count");
            if (cnt == null) mon.Add(new XElement("count", value));
            else cnt.Value = value.ToString(CultureInfo.InvariantCulture);
        }
    }

    private XElement AddFirst(XElement e) { Root.AddFirst(e); return e; }

    public IReadOnlyList<DisplayMode> Resolutions =>
        Root.Element("resolutions")?.Elements("resolution")
            .Select(r => new DisplayMode(
                int.TryParse(r.Element("width")?.Value, out var w) ? w : 0,
                int.TryParse(r.Element("height")?.Value, out var h) ? h : 0,
                int.TryParse(r.Element("refresh_rate")?.Value, out var z) ? z : 0))
            .Where(m => m.Width > 0 && m.Height > 0).ToList()
        ?? new List<DisplayMode>();

    public IReadOnlyList<int> GlobalRefreshRates =>
        Root.Element("global")?.Elements("g_refresh_rate")
            .Select(e => int.TryParse(e.Value, out var v) ? v : 0).Where(v => v > 0).ToList()
        ?? new List<int>();

    /// Number of modes the driver generates: one per &lt;resolution&gt; entry plus every global rate for every unique
    /// resolution (16 entries + 1 global rate → 32).
    public static int CountGeneratedModes(int resolutionEntries, int uniqueResolutions, int globalRates) =>
        resolutionEntries + uniqueResolutions * globalRates;

    public int GeneratedModeCount
    {
        get
        {
            var res = Resolutions;
            return CountGeneratedModes(res.Count, res.Select(r => (r.Width, r.Height)).Distinct().Count(), GlobalRefreshRates.Count);
        }
    }

    public bool IsWithinCap =>
        Resolutions.Count <= MaxResolutions && GlobalRefreshRates.Count <= MaxGlobalRefreshRates && GeneratedModeCount <= MaxGeneratedModes;

    public bool HasResolution(int w, int h) => Resolutions.Any(r => r.Width == w && r.Height == h);

    /// Rewrites the mode list to the compact presets (+ <paramref name="extraModes"/>, e.g. tablet resolutions the user
    /// added, kept first so they win) and resets options/cursor/colour to known-good values (logging off).
    /// Keeps the monitor count (at least 1), the GPU choice and any unknown elements. Always within the cap.
    public void Normalize(IEnumerable<(int W, int H)>? extraModes = null)
    {
        foreach (var c in Root.Nodes().OfType<XComment>().Where(c => c.Value.Contains("Managed by PlexiChore")).ToList()) c.Remove();
        Root.AddFirst(new XComment(ManagedComment));
        if (MonitorCount < 1) MonitorCount = 1;
        if (Root.Element("gpu") == null) InsertAfter("monitors", new XElement("gpu", new XElement("friendlyname", "default")));

        var global = Root.Element("global") ?? InsertAfter("gpu", new XElement("global"));
        global.RemoveNodes();
        global.Add(new XElement("g_refresh_rate", PresetHz));

        var list = new List<(int W, int H)>();
        foreach (var m in (extraModes ?? Array.Empty<(int, int)>()).Concat(PresetModes))
            if (m.W > 0 && m.H > 0 && !list.Contains(m)) list.Add(m);
        // presets are never dropped; extras beyond the cap are
        var extras = list.Where(m => !PresetModes.Contains(m)).Take(MaxResolutions - PresetModes.Length).ToList();
        list = extras.Concat(PresetModes).ToList();

        var res = Root.Element("resolutions") ?? InsertAfter("global", new XElement("resolutions"));
        res.RemoveNodes();
        foreach (var (w, h) in list) res.Add(Res(w, h, PresetHz));

        SetChildren(Root.Element("options") ?? InsertAfter("resolutions", new XElement("options")), OptionDefaults);
        SetChildren(Root.Element("cursor") ?? InsertAfter("options", new XElement("cursor")), CursorDefaults);
        SetChildren(Root.Element("colour") ?? InsertAfter("cursor", new XElement("colour")), ColourDefaults);
    }

    private static void SetChildren(XElement parent, IEnumerable<(string Name, string Value)> values)
    {
        foreach (var (name, value) in values)
        {
            var e = parent.Element(name);
            if (e == null) parent.Add(new XElement(name, value));
            else e.Value = value;
        }
    }

    /// Adds w×h @60 Hz as the first resolution if it is missing and the cap allows it. Does NOT take effect until the
    /// device is restarted (elevated). Never adds global refresh rates.
    public AddModeResult TryAddMode(int w, int h)
    {
        if (w <= 0 || h <= 0) return AddModeResult.Invalid;
        if (HasResolution(w, h)) return AddModeResult.AlreadyPresent;
        var res = Resolutions;
        var unique = res.Select(r => (r.Width, r.Height)).Distinct().Count();
        var globals = Math.Max(1, GlobalRefreshRates.Count);
        if (res.Count + 1 > MaxResolutions || CountGeneratedModes(res.Count + 1, unique + 1, globals) > MaxGeneratedModes)
            return AddModeResult.CapReached;
        (Root.Element("resolutions") ?? InsertAfter("global", new XElement("resolutions"))).AddFirst(Res(w, h, PresetHz));
        return AddModeResult.Added;
    }

    private XElement InsertAfter(string sibling, XElement e)
    {
        var s = Root.Element(sibling);
        if (s != null) s.AddAfterSelf(e); else Root.Add(e);
        return e;
    }

    public void Save(string? path = null)
    {
        path ??= Path;
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        var tmp = path + ".plexichore.tmp";
        Document.Save(tmp);
        if (File.Exists(path))
        {
            try { File.Copy(path, path + ".bak", true); } catch { }
        }
        File.Move(tmp, path, true);
    }
}

/// Tablet resolutions the user explicitly added ("Add this tablet's exact resolution"); kept by Repair/Install.
/// Stored in %LOCALAPPDATA%\PlexiChore\vdd-extra-modes.json.
public static class VddExtraModes
{
    public static string DefaultPath => System.IO.Path.Combine(PlexiChore.App.Services.AppPaths.LocalDir, "vdd-extra-modes.json");

    public static int MaxExtras => VddSettingsFile.MaxResolutions - VddSettingsFile.PresetModes.Length;

    public static List<(int W, int H)> Load(string? path = null)
    {
        try
        {
            path ??= DefaultPath;
            if (!File.Exists(path)) return new();
            var arr = System.Text.Json.JsonSerializer.Deserialize<int[][]>(File.ReadAllText(path)) ?? Array.Empty<int[]>();
            return arr.Where(a => a.Length == 2 && a[0] > 0 && a[1] > 0).Select(a => (a[0], a[1])).Distinct().ToList();
        }
        catch { return new(); }
    }

    public static void Add(int w, int h, string? path = null)
    {
        path ??= DefaultPath;
        var list = Load(path);
        list.Remove((w, h));
        list.Insert(0, (w, h));
        list = list.Take(MaxExtras).ToList();
        Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
        File.WriteAllText(path, System.Text.Json.JsonSerializer.Serialize(list.Select(m => new[] { m.W, m.H })));
    }
}
