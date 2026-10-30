using System.IO;
using System.IO.Pipes;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Text;
using PlexiChore.App.Services;
using PlexiChore.App.Services.Adb;
using PlexiChore.App.VirtualDisplay;
using Xunit;

namespace PlexiChore.App.Tests;

public class AdbParserTests
{
    private const string Sample = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        R52T70ABCDE            device usb:1-4 product:gts8wifixx model:SM_X700 device:gts8wifi transport_id:3
        adb-R52T70ABCDE-Xy1Z2a._adb-tls-connect._tcp device product:gts8wifixx model:SM_X700 device:gts8wifi transport_id:5
        192.168.1.44:5555      offline transport_id:6
        0123456789ABCDEF       unauthorized usb:1-2 transport_id:7
        ZX1G22                 no permissions (missing udev rules?); see [http://developer.android.com/tools/device.html] usb:1-1 transport_id:8

        """;

    [Fact]
    public void ParsesAllStates()
    {
        var d = AdbParser.ParseDevices(Sample);
        Assert.Equal(5, d.Count);
        Assert.Equal("R52T70ABCDE", d[0].Serial);
        Assert.True(d[0].IsReady);
        Assert.Equal("SM X700", d[0].Model);
        Assert.False(d[0].IsWireless);
        Assert.True(d[1].IsWireless);
        Assert.True(d[1].IsReady);
        Assert.Equal("offline", d[2].State);
        Assert.True(d[2].IsWireless);
        Assert.True(d[3].IsUnauthorized);
        Assert.Equal("no permissions", d[4].State);
        Assert.Equal("1-1", d[4].Props["usb"]);
    }

    [Fact]
    public void EmptyListParsesToNothing()
    {
        Assert.Empty(AdbParser.ParseDevices("List of devices attached\r\n\r\n"));
    }

    [Fact]
    public void DetectsReverseRule()
    {
        Assert.True(AdbParser.HasReverse("UsbFfs tcp:47800 tcp:47800\n", 47800));
        Assert.True(AdbParser.HasReverse("host-19 tcp:47800 tcp:47800\r\nhost-19 tcp:8081 tcp:8081\r\n", 47800));
        Assert.False(AdbParser.HasReverse("host-19 tcp:8081 tcp:8081\n", 47800));
        Assert.False(AdbParser.HasReverse("", 47800));
    }

    [Fact]
    public void ReverseLinkTellsCableFromWirelessDebugging()
    {
        Assert.Equal("usb-cable", AdbParser.ReverseLink("UsbFfs tcp:47800 tcp:47800\n", 47800));
        Assert.Equal("usb-wireless-adb", AdbParser.ReverseLink("host-22 tcp:8081 tcp:8081\r\nhost-22 tcp:47800 tcp:47800\r\n", 47800));
        Assert.Null(AdbParser.ReverseLink("host-22 tcp:8081 tcp:8081\n", 47800));
        Assert.Null(AdbParser.ReverseLink("", 47800));
    }
}

public class DisplayLayoutTests
{
    private static readonly Rectangle Primary = new(0, 0, 1920, 1080);

    [Theory]
    [InlineData("right", 1920)]
    [InlineData("left", -2560)]
    [InlineData(null, 1920)]
    [InlineData("bogus", 1920)]
    public void SideBySide(string? side, int x)
    {
        // 2560x1600 is taller than primary → top-aligned
        var p = DisplayLayout.ComputePosition(Primary, new[] { Primary }, 2560, 1600, side);
        Assert.Equal(x, p.X);
        Assert.Equal(0, p.Y);
    }

    [Fact]
    public void CentredWhenSmaller()
    {
        var p = DisplayLayout.ComputePosition(Primary, new[] { Primary }, 1280, 800, "right");
        Assert.Equal(new Point(1920, 140), p);
        p = DisplayLayout.ComputePosition(Primary, new[] { Primary }, 1280, 800, "top");
        Assert.Equal(new Point(320, -800), p);
        p = DisplayLayout.ComputePosition(Primary, new[] { Primary }, 1280, 800, "bottom");
        Assert.Equal(new Point(320, 1080), p);
    }

    [Fact]
    public void PushesPastExistingMonitor()
    {
        var second = new Rectangle(1920, 0, 1920, 1080);
        var p = DisplayLayout.ComputePosition(Primary, new[] { Primary, second }, 1280, 800, "right");
        Assert.Equal(3840, p.X);
        var r = new Rectangle(p, new Size(1280, 800));
        Assert.False(r.IntersectsWith(second));
    }

    [Fact]
    public void ChoosesExactThenAspectThenFallback()
    {
        var modes = new List<DisplayMode>
        {
            new(2560, 1600, 60), new(2560, 1600, 120), new(1920, 1200, 60), new(1920, 1080, 60), new(3840, 2160, 60),
        };
        Assert.Equal(new DisplayMode(2560, 1600, 120), DisplayLayout.ChooseMode(modes, 2560, 1600, 120));
        Assert.Equal(new DisplayMode(2560, 1600, 60), DisplayLayout.ChooseMode(modes, 2560, 1600, 60));
        Assert.Equal(new DisplayMode(2560, 1600, 60), DisplayLayout.ChooseMode(modes, 2560, 1600, 75));
        // 2800x1752 (16:10) not present → largest 16:10 that fits
        Assert.Equal(new DisplayMode(2560, 1600, 60), DisplayLayout.ChooseMode(modes, 2800, 1752, 60));
        // no same-aspect mode fits → largest that fits
        Assert.Equal(new DisplayMode(1920, 1080, 60), DisplayLayout.ChooseMode(modes, 1920, 1100, 60));
        Assert.Null(DisplayLayout.ChooseMode(Array.Empty<DisplayMode>(), 1, 1, 60));
    }

    [Fact]
    public void PortraitRequestFallsBackToLandscapeWithoutPortraitModes()
    {
        // an older driver install (landscape-only mode list, before Repair) → landscape
        var landscapeOnly = PresetModes().Where(m => m.Width > m.Height).ToList();
        Assert.Equal((2560, 1600, true), DisplayLayout.OrientForModes(landscapeOnly, 1600, 2560));
        // current presets include portrait modes → exact portrait monitors for the common tablets
        Assert.Equal((1600, 2560, false), DisplayLayout.OrientForModes(PresetModes(), 1600, 2560));
        Assert.Equal(new DisplayMode(1600, 2560, 60), DisplayLayout.ChooseMode(PresetModes(), 1600, 2560, 60)); // Tab S8 / 16:10 2.5K
        Assert.Equal(new DisplayMode(1200, 1920, 60), DisplayLayout.ChooseMode(PresetModes(), 1200, 1920, 60)); // 10" FHD+
        Assert.Equal(new DisplayMode(1752, 2800, 60), DisplayLayout.ChooseMode(PresetModes(), 1752, 2800, 60)); // Tab S8+/S9+
        Assert.Equal((2560, 1600, false), DisplayLayout.OrientForModes(PresetModes(), 2560, 1600)); // landscape untouched
    }

    private static List<DisplayMode> PresetModes() =>
        VddSettingsFile.PresetModes.Select(m => new DisplayMode(m.W, m.H, 60)).ToList();

    [Theory]
    [InlineData(2560, 1600, 2560, 1600)] // exact
    [InlineData(2224, 1668, 2048, 1536)] // iPad Pro 10.5 (4:3) → largest 4:3 that fits
    [InlineData(2388, 1668, 2048, 1536)] // 1.43 aspect, no match → largest mode that fits
    [InlineData(2000, 1250, 1920, 1200)] // 16:10 not present exactly → largest 16:10 that fits
    [InlineData(1340, 800, 1280, 800)]   // fits only 1280×800
    [InlineData(1000, 625, 1280, 800)]   // nothing fits → closest, same aspect preferred
    [InlineData(3840, 2160, 2560, 1440)] // 4K 16:9 → largest 16:9 that fits
    public void ChoosesBestPresetForTabletSizes(int w, int h, int ew, int eh)
    {
        var m = DisplayLayout.ChooseMode(PresetModes(), w, h, 120)!;
        Assert.Equal((ew, eh), (m.Width, m.Height));
        Assert.Equal(60, m.Hz);
    }

    [Fact]
    public void NothingFitsPicksClosestArea()
    {
        var modes = new List<DisplayMode> { new(1280, 800, 60), new(1366, 768, 60), new(3840, 2160, 60) };
        Assert.Equal(new DisplayMode(1280, 800, 60), DisplayLayout.ChooseMode(modes, 1024, 700, 60));
    }

    [Fact]
    public void SanitizesToEven()
    {
        Assert.Equal((2000, 1250), DisplayLayout.Sanitize(2001, 1251));
        Assert.Equal((640, 480), DisplayLayout.Sanitize(10, 10));
    }
}

public class VddSettingsFileTests : IDisposable
{
    private readonly string _dir = Path.Combine(Path.GetTempPath(), "plexi-tests-" + Guid.NewGuid().ToString("N"));
    public VddSettingsFileTests() => Directory.CreateDirectory(_dir);
    public void Dispose() { try { Directory.Delete(_dir, true); } catch { } }

    // Trimmed copy of the vdd_settings.xml shipped in VirtualDisplayDriver-x86.Driver.Only.zip (25.7.23)
    private const string Shipped = """
        <?xml version='1.0' encoding='utf-8'?>
        <vdd_settings>
            <monitors>
                <count>1</count>
            </monitors>
            <gpu>
                <friendlyname>default</friendlyname>
            </gpu>
        	<global>
        		<g_refresh_rate>60</g_refresh_rate>
        		<g_refresh_rate>90</g_refresh_rate>
        		<g_refresh_rate>120</g_refresh_rate>
        	</global>
            <resolutions>
                <resolution>
                    <width>800</width>
                    <height>600</height>
                    <refresh_rate>30</refresh_rate>
                </resolution>
                <resolution>
                    <width>1920</width>
                    <height>1080</height>
                    <refresh_rate>30</refresh_rate>
                </resolution>
            </resolutions>
            <options>
        		<CustomEdid>false</CustomEdid>
        		<HardwareCursor>true</HardwareCursor>
            </options>
        </vdd_settings>
        """;

    private static readonly (int W, int H)[] ExpectedPresets =
    {
        (2560, 1600), (1920, 1200), (1280, 800), (2880, 1800), (2000, 1200), (2400, 1600), (3000, 2000), (2732, 2048),
        (2048, 1536), (1600, 1000), (2560, 1440), (1920, 1080), (1366, 768), (2800, 1752), (2960, 1848), (1440, 900),
        // portrait (tablet held upright, Android 16+ large screens ignore orientation locks): 19 resolutions = 38 modes
        (1600, 2560), (1200, 1920), (1752, 2800),
    };

    [Fact]
    public void PresetListIsTheVerifiedCompactList()
    {
        Assert.Equal(ExpectedPresets, VddSettingsFile.PresetModes);
        Assert.True(VddSettingsFile.PresetModes.Length <= VddSettingsFile.MaxResolutions);
    }

    [Fact]
    public void DefaultDocumentIsCompactAndComplete()
    {
        var f = VddSettingsFile.Load(Path.Combine(_dir, "nope.xml"));
        Assert.Equal(1, f.MonitorCount);
        Assert.Equal(ExpectedPresets.Select(m => new DisplayMode(m.W, m.H, 60)), f.Resolutions);
        Assert.Equal(new[] { 60 }, f.GlobalRefreshRates);
        Assert.Equal(38, f.GeneratedModeCount); // 19 entries (16 landscape + 3 portrait) + 19 unique × 1 global rate
        Assert.True(f.IsWithinCap);

        var root = f.Document.Root!;
        Assert.Equal("default", root.Element("gpu")!.Element("friendlyname")!.Value);
        var opt = root.Element("options")!;
        Assert.Equal("false", opt.Element("logging")!.Value);
        Assert.Equal("false", opt.Element("debuglogging")!.Value);
        Assert.Equal("false", opt.Element("SendLogsThroughPipe")!.Value);
        Assert.Equal("true", opt.Element("HardwareCursor")!.Value);
        var cur = root.Element("cursor")!;
        Assert.Equal("true", cur.Element("HardwareCursor")!.Value);
        Assert.Equal("128", cur.Element("CursorMaxX")!.Value);
        Assert.Equal("128", cur.Element("CursorMaxY")!.Value);
        Assert.Equal("true", cur.Element("AlphaCursorSupport")!.Value);
        Assert.Equal("2", cur.Element("XorCursorSupportLevel")!.Value);
        var col = root.Element("colour")!;
        Assert.Equal("false", col.Element("SDR10bit")!.Value);
        Assert.Equal("false", col.Element("HDRPlus")!.Value);
        Assert.Equal("RGB", col.Element("ColourFormat")!.Value);

        var bad = Path.Combine(_dir, "bad.xml");
        File.WriteAllText(bad, "<not-xml");
        Assert.Equal(1, VddSettingsFile.Load(bad).MonitorCount);
    }

    [Fact]
    public void ModeCountMultipliesGlobalRatesAcrossUniqueResolutions()
    {
        Assert.Equal(32, VddSettingsFile.CountGeneratedModes(16, 16, 1));
        Assert.Equal(168, VddSettingsFile.CountGeneratedModes(28, 28, 5)); // the broken 28 × 5 setup
        var path = Path.Combine(_dir, "vdd_settings.xml");
        File.WriteAllText(path, Shipped); // 2 entries, 3 global rates
        var f = VddSettingsFile.Load(path);
        Assert.Equal(2 + 2 * 3, f.GeneratedModeCount);
        Assert.False(f.IsWithinCap); // 3 global rates > 2
    }

    /// The broken setup from this PC: 28 resolutions × 5 global rates → IddCxMonitorArrival 0xC00000BB.
    private static string BloatedXml()
    {
        var legacy = new (int, int)[]
        {
            (2560, 1600), (1920, 1200), (1280, 800), (2800, 1752), (2100, 1314), (1400, 876), (2960, 1848), (2220, 1386),
            (1480, 924), (2000, 1200), (1500, 900), (1000, 600), (2048, 1536), (1536, 1152), (1024, 768), (2224, 1668),
            (2388, 1668), (2360, 1640), (2732, 2048), (2880, 1800), (2160, 1350), (1440, 900), (3000, 2000), (2560, 1440),
            (1920, 1080), (1600, 900), (1366, 768), (3840, 2160),
        };
        var res = string.Concat(legacy.Select(m => $"<resolution><width>{m.Item1}</width><height>{m.Item2}</height><refresh_rate>60</refresh_rate></resolution>"));
        return "<?xml version='1.0' encoding='utf-8'?><vdd_settings><!-- Managed by PlexiChore Desktop. old --><monitors><count>0</count></monitors>" +
               "<gpu><friendlyname>NVIDIA</friendlyname></gpu><global><g_refresh_rate>30</g_refresh_rate><g_refresh_rate>60</g_refresh_rate>" +
               "<g_refresh_rate>90</g_refresh_rate><g_refresh_rate>120</g_refresh_rate><g_refresh_rate>144</g_refresh_rate></global>" +
               $"<resolutions>{res}</resolutions><options><CustomEdid>false</CustomEdid><logging>true</logging><debuglogging>true</debuglogging>" +
               "<SomethingNew>keep</SomethingNew></options><future><x>1</x></future></vdd_settings>";
    }

    [Fact]
    public void NormalizeRepairsBloatedSettings()
    {
        var path = Path.Combine(_dir, "vdd_settings.xml");
        File.WriteAllText(path, BloatedXml());
        var f = VddSettingsFile.Load(path);
        Assert.Equal(28, f.Resolutions.Count);
        Assert.False(f.IsWithinCap);

        f.Normalize();
        f.Save();
        var g = VddSettingsFile.Load(path);
        Assert.True(g.IsWithinCap);
        Assert.Equal(ExpectedPresets.Select(m => new DisplayMode(m.W, m.H, 60)), g.Resolutions);
        Assert.Equal(new[] { 60 }, g.GlobalRefreshRates);
        Assert.Equal(1, g.MonitorCount);                                                      // count 0 → 1
        var root = g.Document.Root!;
        Assert.Equal("NVIDIA", root.Element("gpu")!.Element("friendlyname")!.Value);           // GPU kept
        Assert.Equal("false", root.Element("options")!.Element("logging")!.Value);             // logging off
        Assert.Equal("false", root.Element("options")!.Element("debuglogging")!.Value);
        Assert.Equal("keep", root.Element("options")!.Element("SomethingNew")!.Value);        // unknown kept
        Assert.NotNull(root.Element("future"));
        Assert.Equal("2", root.Element("cursor")!.Element("XorCursorSupportLevel")!.Value);    // added
        Assert.Equal("RGB", root.Element("colour")!.Element("ColourFormat")!.Value);
        Assert.Single(root.Nodes().OfType<System.Xml.Linq.XComment>());                        // comment replaced, not duplicated
        Assert.True(File.Exists(path + ".bak"));

        // idempotent
        var before = g.Document.ToString();
        g.Normalize();
        Assert.Equal(before, g.Document.ToString());
    }

    [Fact]
    public void NormalizeKeepsExtrasFirstAndCapsThem()
    {
        var f = VddSettingsFile.Load(Path.Combine(_dir, "nope.xml"));
        var extras = Enumerable.Range(0, 20).Select(i => (2000 + i * 2, 1500)).Prepend((1920, 1200)).ToList(); // preset dup ignored
        f.Normalize(extras);
        Assert.Equal(VddSettingsFile.MaxResolutions, f.Resolutions.Count);
        Assert.Equal(new DisplayMode(2000, 1500, 60), f.Resolutions[0]);
        Assert.True(f.IsWithinCap);
        Assert.True(f.GeneratedModeCount <= VddSettingsFile.MaxGeneratedModes);
        foreach (var p in ExpectedPresets) Assert.True(f.HasResolution(p.W, p.H)); // presets never dropped
    }

    [Fact]
    public void TryAddModeRespectsCap()
    {
        var f = VddSettingsFile.Load(Path.Combine(_dir, "nope.xml"));
        Assert.Equal(AddModeResult.AlreadyPresent, f.TryAddMode(2560, 1600));
        Assert.Equal(AddModeResult.Invalid, f.TryAddMode(0, 1600));
        Assert.Equal(AddModeResult.Added, f.TryAddMode(2224, 1668));
        Assert.Equal(new DisplayMode(2224, 1668, 60), f.Resolutions[0]); // first = preferred
        Assert.Equal(new[] { 60 }, f.GlobalRefreshRates);                // never adds rates
        for (var i = 0; f.Resolutions.Count < VddSettingsFile.MaxResolutions; i++)
            Assert.Equal(AddModeResult.Added, f.TryAddMode(3000 + i * 2, 1700));
        Assert.True(f.IsWithinCap);
        Assert.Equal(AddModeResult.CapReached, f.TryAddMode(1234, 800));
        Assert.True(f.IsWithinCap);
    }

    [Fact]
    public void TryAddModeRefusesWhenGlobalRatesWouldExceedModeCap()
    {
        var f = VddSettingsFile.Load(Path.Combine(_dir, "nope.xml"));
        f.Document.Root!.Element("global")!.Add(new System.Xml.Linq.XElement("g_refresh_rate", 120));
        Assert.Equal(19 + 19 * 2, f.GeneratedModeCount); // 57 = already over the 48 cap
        Assert.Equal(AddModeResult.CapReached, f.TryAddMode(2224, 1668));
    }

    [Fact]
    public void MonitorCountRoundTrips()
    {
        var path = Path.Combine(_dir, "vdd_settings.xml");
        File.WriteAllText(path, Shipped);
        var f = VddSettingsFile.Load(path);
        f.MonitorCount = 0;
        f.Save();
        Assert.Equal(0, VddSettingsFile.Load(path).MonitorCount);
        Assert.Contains("<count>0</count>", File.ReadAllText(path));
    }

    [Fact]
    public void ExtraModesStoreRoundTrips()
    {
        var path = Path.Combine(_dir, "extra.json");
        Assert.Empty(VddExtraModes.Load(path));
        VddExtraModes.Add(2224, 1668, path);
        VddExtraModes.Add(2388, 1668, path);
        VddExtraModes.Add(2224, 1668, path); // moves to front, no duplicate
        Assert.Equal(new[] { (2224, 1668), (2388, 1668) }, VddExtraModes.Load(path));
        for (var i = 0; i < 20; i++) VddExtraModes.Add(1000 + i * 2, 700, path);
        Assert.Equal(VddExtraModes.MaxExtras, VddExtraModes.Load(path).Count);
        File.WriteAllText(path, "garbage");
        Assert.Empty(VddExtraModes.Load(path));
    }
}

public class VddPipeAndStatusTests
{
    [Fact]
    public void PipeDecodeHandlesAnsiPongAndUtf16Settings()
    {
        Assert.Equal("PONG", VddPipeClient.Decode(Encoding.ASCII.GetBytes("PONG")));          // 4 ANSI bytes
        Assert.Equal("PONG", VddPipeClient.Decode(Encoding.Unicode.GetBytes("PONG\0")));
        Assert.Equal("SETTINGS DEBUG=false LOG=true", VddPipeClient.Decode(Encoding.Unicode.GetBytes("SETTINGS DEBUG=false LOG=true")));
    }

    [Fact]
    public void CommandsAreUtf16LeWithoutTerminator()
    {
        Assert.Equal(new byte[] { (byte)'P', 0, (byte)'I', 0, (byte)'N', 0, (byte)'G', 0 }, VddPipeClient.Encode("PING"));
    }

    [Theory]
    [InlineData("RELOAD_DRIVER")]
    [InlineData("SETDISPLAYCOUNT 1")]
    [InlineData("SETGPU \"x\"")]
    [InlineData("HDRPLUS true")]
    [InlineData("SDR10 true")]
    [InlineData("CUSTOMEDID true")]
    [InlineData("PREVENTSPOOF true")]
    [InlineData("CEAOVERRIDE true")]
    [InlineData("HARDWARECURSOR true")]
    [InlineData("ping")]
    public async Task ReloadTriggeringCommandsAreRefused(string cmd)
    {
        Assert.False(VddPipeClient.IsAllowed(cmd));
        // refused before any connection is attempted (pipe name irrelevant)
        await Assert.ThrowsAsync<InvalidOperationException>(() => VddPipeClient.SendAsync("plexi-none-" + Guid.NewGuid().ToString("N"), cmd, null, default));
    }

    [Fact]
    public void ParsesSettingsReply()
    {
        var s = VddPipeClient.ParseSettings("SETTINGS DEBUG=true LOG=false");
        Assert.NotNull(s);
        Assert.Equal("true", s!["DEBUG"]);
        Assert.Equal("false", s["log"]);
        Assert.Null(VddPipeClient.ParseSettings("PONG"));
    }

    /// Simulates the driver: read one command, write the reply, DisconnectNamedPipe immediately (no flush).
    private static async Task FakeDriverAsync(NamedPipeServerStream server, Func<string, byte[]> reply, TaskCompletionSource<string> received)
    {
        await server.WaitForConnectionAsync();
        var buf = new byte[512];
        var n = await server.ReadAsync(buf);
        var cmd = Encoding.Unicode.GetString(buf, 0, n);
        received.TrySetResult(cmd);
        var r = reply(cmd);
        await server.WriteAsync(r);
        server.Disconnect();
    }

    [Theory]
    [InlineData("PING", "PONG", false)]
    [InlineData("GETSETTINGS", "SETTINGS DEBUG=false LOG=false", true)]
    public async Task ReadsReplyThatIsFollowedByImmediateDisconnect(string cmd, string reply, bool utf16)
    {
        var name = "plexi-vdd-test-" + Guid.NewGuid().ToString("N");
        using var server = new NamedPipeServerStream(name, PipeDirection.InOut, 1, PipeTransmissionMode.Message, PipeOptions.Asynchronous);
        var received = new TaskCompletionSource<string>();
        var fake = FakeDriverAsync(server, _ => utf16 ? Encoding.Unicode.GetBytes(reply) : Encoding.ASCII.GetBytes(reply), received);
        var got = await VddPipeClient.SendAsync(name, cmd, TimeSpan.FromSeconds(3), default);
        await fake;
        Assert.Equal(cmd, await received.Task);
        Assert.Equal(reply, got);
    }

    [Fact]
    public void ReadyWithoutMonitorNeedsRepair()
    {
        var ready = new VddDeviceStatus(VddState.Ready, @"ROOT\DISPLAY\0000", "Virtual Display Driver", 0, null);
        var broken = ready.WithMonitor(false);
        Assert.Equal(VddState.NeedsRepair, broken.State);
        Assert.Equal(VddDeviceStatus.NoMonitorDetail, broken.Detail);
        Assert.False(broken.MonitorPresent);
        var ok = ready.WithMonitor(true);
        Assert.Equal(VddState.Ready, ok.State);
        Assert.True(ok.MonitorPresent);
        // other states are not masked
        var disabled = new VddDeviceStatus(VddState.Disabled, "x", null, 22, "d").WithMonitor(false);
        Assert.Equal(VddState.Disabled, disabled.State);
    }

    [Fact]
    public void RepairScriptRestartsDeviceAndNeverReloadsViaPipe()
    {
        Assert.Contains("'repair'", VddInstaller.Script);
        Assert.Contains("/restart-device", VddInstaller.Script);
        Assert.Contains("Write-Settings", VddInstaller.Script);
        Assert.DoesNotContain("MTTVirtualDisplayPipe", VddInstaller.Script);
    }

    [Fact]
    public void VddMonitorProbeIsReadOnlyAndDoesNotThrow()
    {
        var present = VirtualDisplayDriverProvider.VddMonitorPresent(null);
        Assert.NotNull(Displays.QueryAvailableTargets());
        // on a machine with a healthy VDD (adapter + monitor), the probe must see the monitor
        var st = VddDeviceDetector.Detect();
        if (st.State == VddState.Ready && Environment.GetEnvironmentVariable("PLEXICHORE_EXPECT_VDD_MONITOR") == "1")
            Assert.True(present || VirtualDisplayDriverProvider.VddMonitorPresent(st.InstanceId));
    }
}

public class VddInstallerTests
{
    private const string Release25723 = """
        {"tag_name":"25.7.23","assets":[
          {"name":"VDD.Control.25.7.23.zip","browser_download_url":"https://x/VDD.Control.25.7.23.zip"},
          {"name":"VirtualAudioDriver-x86.Driver.Only.zip","browser_download_url":"https://x/audio.zip"},
          {"name":"VirtualDisplayDriver-ARM64.Driver.Only.zip","browser_download_url":"https://x/arm.zip"},
          {"name":"VirtualDisplayDriver-x86.Driver.Only.zip","browser_download_url":"https://x/x86.zip"}]}
        """;

    [Fact]
    public void PicksDriverOnlyAssetPerArch()
    {
        var x64 = VddInstaller.PickAsset(Release25723, Architecture.X64);
        Assert.NotNull(x64);
        Assert.Equal("25.7.23", x64!.Tag);
        Assert.Equal("https://x/x86.zip", x64.Url);
        Assert.Equal("https://x/arm.zip", VddInstaller.PickAsset(Release25723, Architecture.Arm64)!.Url);
    }

    [Fact]
    public void PrefersExplicitX64Asset()
    {
        const string json = """
            {"tag_name":"24.10.27","assets":[
              {"name":"VirtualDisplayDriver-ARM64.zip","browser_download_url":"https://x/arm.zip"},
              {"name":"VirtualDisplayDriver-x64.zip","browser_download_url":"https://x/x64.zip"}]}
            """;
        Assert.Equal("https://x/x64.zip", VddInstaller.PickAsset(json, Architecture.X64)!.Url);
    }

    [Fact]
    public void NoDriverAssetReturnsNull()
    {
        Assert.Null(VddInstaller.PickAsset("""{"tag_name":"1","assets":[{"name":"VDD.Control.zip","browser_download_url":"u"}]}""", Architecture.X64));
    }

    [Fact]
    public void ScriptHandlesAllActions()
    {
        Assert.Contains("'install'", VddInstaller.Script);
        Assert.Contains("--remove-device-node", VddInstaller.Script);
        Assert.Contains("@('install'", VddInstaller.Script);
        Assert.Contains(@"'Root\MttVDD'", VddInstaller.Script);
        Assert.Contains("VDDPATH", VddInstaller.Script);
    }
}

public class MiscTests
{
    [Fact]
    public void FirewallScriptAddsBothRules()
    {
        var s = FirewallService.BuildScript(@"C:\x\PlexiChore.exe", add: true);
        Assert.Contains("protocol=TCP localport=47800", s);
        Assert.Contains("protocol=UDP localport=47801", s);
        Assert.Contains("delete rule", s);
        Assert.DoesNotContain("add rule", FirewallService.BuildScript("x", add: false));
    }

    [Fact]
    public void PipeDecodeHandlesUtf16AndUtf8()
    {
        Assert.Equal("PONG", VddPipeClient.Decode(Encoding.Unicode.GetBytes("PONG\0")));
        Assert.Equal("PONG", VddPipeClient.Decode(Encoding.UTF8.GetBytes("PONG")));
    }

    [Fact]
    public void SettingsGenerateStableHostIdAndTrustList()
    {
        var path = Path.Combine(Path.GetTempPath(), "plexi-settings-" + Guid.NewGuid().ToString("N"), "settings.json");
        try
        {
            var a = new SettingsService(path);
            Assert.True(Guid.TryParse(a.Current.HostId, out _));
            a.AddTrusted("dev-1", "Tab S8");
            a.AddTrusted("DEV-1", "Tab S8 renamed");
            var b = new SettingsService(path);
            Assert.Equal(a.Current.HostId, b.Current.HostId);
            Assert.Single(b.Current.TrustedDevices);
            Assert.True(b.IsTrusted("dev-1"));
            b.RemoveTrusted("dev-1");
            Assert.False(new SettingsService(path).IsTrusted("dev-1"));
        }
        finally { try { Directory.Delete(Path.GetDirectoryName(path)!, true); } catch { } }
    }
}

public class DisplayEnumerationTests
{
    [Fact]
    public void EnumeratesAttachedDisplaysReadOnly()
    {
        // Read-only smoke test of the GDI / DisplayConfig interop on the current machine.
        var all = VirtualDisplayDriverProvider.FindVddDisplays(); // must not throw even when VDD is absent
        Assert.NotNull(all);
        var sources = Displays.QueryActiveSources();
        Assert.NotEmpty(sources);
        var d = Displays.Enumerate();
        Assert.Contains(d, x => x.AttachedToDesktop && !x.Bounds.IsEmpty);
        var primary = d.FirstOrDefault(x => x.IsPrimary);
        Assert.NotNull(primary);
        Assert.Equal(0, primary!.Bounds.X);
        Assert.NotEmpty(Displays.GetModes(primary.GdiName));
    }
}

public class WatchdogTests
{
    [Theory]
    [InlineData(unchecked((int)0xC0000005), true)]  // access violation (NVIDIA MFT teardown crash)
    [InlineData(unchecked((int)0xC0000409), true)]  // fail-fast
    [InlineData(unchecked((int)0xE0434352), true)]  // unhandled .NET exception
    [InlineData(0, false)]                          // Quit
    [InlineData(1, false)]                          // End task / taskkill
    [InlineData(unchecked((int)0xC000013A), false)] // logoff / Ctrl+C
    public void OnlyCrashExitCodesRestart(int code, bool restart) => Assert.Equal(restart, Watchdog.IsCrash(code));
}
