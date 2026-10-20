using System.Drawing;
using System.IO;
using PlexiChore.App.VirtualDisplay;
using PlexiChore.Engine;
using PlexiChore.Engine.Protocol;
using Xunit;

namespace PlexiChore.App.Tests;

public class PrimaryLayoutTests
{
    private const string Mon = @"\\.\DISPLAY1";
    private const string Vdd = @"\\.\DISPLAY3";
    private static readonly Rectangle MonBounds = new(0, 0, 1920, 1080);

    private static MonitorPlacement P(string gdi, Rectangle b, bool primary, string id = "") =>
        new(gdi, id, primary, b.X, b.Y, b.Width, b.Height);

    /// The full flow: extend placement (tablet relative to monitor) followed by the primary shift.
    private static List<MonitorPlacement> PrimaryFor(string side, int w = 2560, int h = 1600)
    {
        var pos = DisplayLayout.ComputePosition(MonBounds, new[] { MonBounds }, w, h, side);
        var layout = new List<MonitorPlacement> { P(Mon, MonBounds, true, "MON-ID"), P(Vdd, new Rectangle(pos, new Size(w, h)), false) };
        return PrimaryLayout.ShiftToPrimary(layout, Vdd);
    }

    [Fact]
    public void ShiftIsNegatedOrigin()
    {
        Assert.Equal(new Point(-1920, 140), PrimaryLayout.ComputeShift(new Rectangle(1920, -140, 100, 100)));
        Assert.Equal(Point.Empty, PrimaryLayout.ComputeShift(new Rectangle(0, 0, 10, 10)));
    }

    [Theory]
    // tablet 2560x1600 is taller than the 1080p monitor → top-aligned on left/right
    [InlineData("right", -1920, 0)]
    [InlineData("left", 2560, 0)]
    // 2560 wider than 1920 → left-aligned on top/bottom
    [InlineData("top", 0, 1600)]
    [InlineData("bottom", 0, -1080)]
    public void TabletBecomesOriginAndSideIsKept(string side, int monX, int monY)
    {
        var plan = PrimaryFor(side);
        var vdd = plan.Single(p => p.GdiName == Vdd);
        var mon = plan.Single(p => p.GdiName == Mon);
        Assert.True(vdd.IsPrimary);
        Assert.False(mon.IsPrimary);
        Assert.Equal(Point.Empty, vdd.Location);
        Assert.Equal(new Point(monX, monY), mon.Location);
        Assert.Equal(new Size(1920, 1080), mon.Bounds.Size); // sizes untouched
    }

    [Fact]
    public void SmallerTabletKeepsCentringAfterShift()
    {
        // tablet 1280x800 right of the monitor, centred: (1920,140) → monitor at (-1920,-140)
        var plan = PrimaryFor("right", 1280, 800);
        Assert.Equal(new Point(-1920, -140), plan.Single(p => p.GdiName == Mon).Location);
    }

    [Fact]
    public void ShiftPreservesRelativeArrangementOfAllMonitors()
    {
        var layout = new List<MonitorPlacement>
        {
            P(Mon, MonBounds, true),
            P(@"\\.\DISPLAY2", new Rectangle(1920, 0, 1920, 1080), false),
            P(Vdd, new Rectangle(3840, 0, 2560, 1600), false),
        };
        var plan = PrimaryLayout.ShiftToPrimary(layout, Vdd);
        Assert.Single(plan, p => p.IsPrimary);
        for (int i = 0; i < layout.Count; i++)
        {
            Assert.Equal(layout[i].X - 3840, plan[i].X);
            Assert.Equal(layout[i].Y, plan[i].Y);
        }
        Assert.Throws<ArgumentException>(() => PrimaryLayout.ShiftToPrimary(layout, @"\\.\DISPLAY9"));
    }

    private static PrimaryRestoreRecord Record() => new(PrimaryRestoreRecord.CurrentVersion, new DateTime(2026, 10, 20, 12, 0, 0, DateTimeKind.Utc), Vdd,
        new List<MonitorPlacement>
        {
            P(Mon, MonBounds, true, "MON-ID"),
            P(@"\\.\DISPLAY2", new Rectangle(-1280, 100, 1280, 1024), false, "SIDE-ID"),
        });

    [Fact]
    public void RestoreRecordRoundTrips()
    {
        var r = Record();
        var back = PrimaryRestoreRecord.Deserialize(r.Serialize());
        Assert.NotNull(back);
        Assert.Equal(r.VirtualGdiName, back!.VirtualGdiName);
        Assert.Equal(r.CreatedUtc, back.CreatedUtc);
        Assert.Equal(r.Original, back.Original); // element-wise record equality
        Assert.Equal(Mon, back.OriginalPrimary!.GdiName);
        Assert.Equal(new Rectangle(-1280, 100, 1280, 1024), back.Original[1].Bounds);
    }

    [Fact]
    public void RestoreRecordFileRoundTripAndDelete()
    {
        var dir = Path.Combine(Path.GetTempPath(), "plexi-tests-" + Guid.NewGuid().ToString("N"));
        var path = Path.Combine(dir, "primary-restore.json");
        try
        {
            Assert.Null(PrimaryRestoreRecord.Load(path));
            Record().Save(path);
            Assert.Equal(Record().Original, PrimaryRestoreRecord.Load(path)!.Original);
            PrimaryRestoreRecord.Delete(path);
            Assert.False(File.Exists(path));
        }
        finally { try { Directory.Delete(dir, true); } catch { } }
    }

    [Theory]
    [InlineData("")]
    [InlineData("not json")]
    [InlineData("{}")]
    [InlineData("""{"Version":1,"VirtualGdiName":"x","Original":[{"GdiName":"a","MonitorId":"","IsPrimary":false,"X":0,"Y":0,"Width":1,"Height":1}]}""")]
    public void InvalidRecordsAreRejected(string json) => Assert.Null(PrimaryRestoreRecord.Deserialize(json));

    [Fact]
    public void PlanRestorePutsOriginalPrimaryBack()
    {
        // current state while the tablet was primary (monitor shifted to negative X); VM excluded by caller
        var current = new List<MonitorPlacement>
        {
            P(Mon, new Rectangle(-1920, 0, 1920, 1080), false, "MON-ID"),
            P(@"\\.\DISPLAY2", new Rectangle(-3200, 100, 1280, 1024), false, "SIDE-ID"),
        };
        var plan = PrimaryLayout.PlanRestore(Record(), current)!;
        Assert.Equal(2, plan.Count);
        var mon = plan.Single(p => p.GdiName == Mon);
        Assert.True(mon.IsPrimary);
        Assert.Equal(Point.Empty, mon.Location);
        Assert.Equal(new Point(-1280, 100), plan.Single(p => p.GdiName == @"\\.\DISPLAY2").Location);
        Assert.False(PrimaryLayout.IsSatisfied(plan, current));
        Assert.True(PrimaryLayout.IsSatisfied(plan, plan));
    }

    [Fact]
    public void PlanRestoreMatchesByMonitorIdWhenGdiNamesChanged()
    {
        // after a reboot GDI numbering may differ; the monitor device path still identifies it
        var current = new List<MonitorPlacement> { P(@"\\.\DISPLAY5", new Rectangle(-1920, 0, 1920, 1080), false, "MON-ID") };
        var plan = PrimaryLayout.PlanRestore(Record(), current)!;
        Assert.Equal(@"\\.\DISPLAY5", plan[0].GdiName);
        Assert.True(plan[0].IsPrimary);
        Assert.Equal(Point.Empty, plan[0].Location);
    }

    [Fact]
    public void PlanRestoreParksUnknownMonitorsAndGivesUpWithoutOriginalPrimary()
    {
        var current = new List<MonitorPlacement>
        {
            P(Mon, new Rectangle(-1920, 0, 1920, 1080), false, "MON-ID"),
            P(@"\\.\DISPLAY7", new Rectangle(5000, 0, 1024, 768), false, "NEW-ID"),
        };
        var plan = PrimaryLayout.PlanRestore(Record(), current)!;
        var parked = plan.Single(p => p.GdiName == @"\\.\DISPLAY7");
        Assert.False(parked.IsPrimary);
        Assert.Equal(new Point(1920, 0), parked.Location); // right of the restored layout, no overlap
        Assert.Single(plan, p => p.IsPrimary);

        var withoutPrimary = new List<MonitorPlacement> { P(@"\\.\DISPLAY2", new Rectangle(0, 0, 1280, 1024), true, "SIDE-ID") };
        Assert.Null(PrimaryLayout.PlanRestore(Record(), withoutPrimary));
    }

    [Theory]
    [InlineData("primary", "primary")]
    [InlineData("PRIMARY", "primary")]
    [InlineData("extend", "extend")]
    [InlineData("mirror", "mirror")]
    [InlineData("weird", "mirror")]
    public void ProtocolKeepsPrimaryMode(string requested, string expected)
    {
        var s = new RequestedSettings { Mode = requested };
        s.Sanitize();
        Assert.Equal(expected, s.Mode);
    }

    private sealed class LegacyProvider : IVirtualDisplayProvider
    {
        public bool IsAvailable => true;
        public int Calls;
        public Task<VirtualMonitor?> AttachAsync(int width, int height, int refreshHz, string position, CancellationToken ct = default)
        {
            Calls++;
            return Task.FromResult<VirtualMonitor?>(new VirtualMonitor("x", new Rectangle(0, 0, width, height)));
        }
        public Task DetachAsync(VirtualMonitor monitor) => Task.CompletedTask;
    }

    [Fact]
    public async Task DefaultPrimaryOverloadDeclinesOnLegacyProviders()
    {
        IVirtualDisplayProvider p = new LegacyProvider();
        Assert.Null(await p.AttachAsync(100, 100, 60, "right", makePrimary: true));
        Assert.NotNull(await p.AttachAsync(100, 100, 60, "right", makePrimary: false));
        Assert.Equal(1, ((LegacyProvider)p).Calls);
    }
}
