using PlexiChore.Engine.Streaming;
using Xunit;

namespace PlexiChore.App.Tests;

public class MirrorAspectTests
{
    // modes reported by a 2560x1080 ultrawide on a GTX 1060 (subset)
    private static readonly MonitorMode[] Ultrawide =
    {
        new(1280, 800, 60), new(1280, 800, 120), new(1440, 900, 60), new(1600, 900, 60), new(1680, 1050, 59),
        new(1680, 1050, 60), new(1680, 1050, 120), new(1920, 1080, 60), new(1440, 1080, 60), new(1280, 768, 60),
        new(2560, 1080, 60), new(2560, 1080, 120), new(3840, 2160, 60), new(640, 480, 60),
    };

    [Fact]
    public void TabS8_on_ultrawide_picks_1680x1050_at_current_rate()
    {
        var pick = MirrorAspectPlanner.Pick(Ultrawide, new MonitorMode(2560, 1080, 60), 2560.0 / 1600);
        Assert.Equal(new MonitorMode(1680, 1050, 60), pick);
    }

    [Fact]
    public void Keeps_high_refresh_rate_when_offered()
    {
        var pick = MirrorAspectPlanner.Pick(Ultrawide, new MonitorMode(2560, 1080, 120), 1.6);
        Assert.Equal(new MonitorMode(1680, 1050, 120), pick);
    }

    [Fact]
    public void Portrait_tablet_size_is_treated_as_landscape()
    {
        var pick = MirrorAspectPlanner.Pick(Ultrawide, new MonitorMode(2560, 1080, 60), 1600.0 / 2560);
        Assert.Equal(new MonitorMode(1680, 1050, 60), pick);
    }

    [Fact]
    public void Never_picks_a_mode_bigger_than_the_current_one()
    {
        // 4:3 tablet: 1440x1080 fits, 3840x2160 is 16:9 anyway; a 16:9 tablet must not get the 4K super-resolution mode
        Assert.Equal(new MonitorMode(1440, 1080, 60), MirrorAspectPlanner.Pick(Ultrawide, new MonitorMode(2560, 1080, 60), 4.0 / 3));
        Assert.Equal(new MonitorMode(1920, 1080, 60), MirrorAspectPlanner.Pick(Ultrawide, new MonitorMode(2560, 1080, 60), 16.0 / 9));
    }

    [Fact]
    public void No_change_when_the_monitor_already_has_the_tablet_shape()
    {
        var modes = new[] { new MonitorMode(1920, 1200, 60), new MonitorMode(1680, 1050, 60) };
        Assert.Null(MirrorAspectPlanner.Pick(modes, new MonitorMode(1920, 1200, 60), 1.6));
    }

    [Fact]
    public void No_change_when_no_matching_mode()
    {
        var modes = new[] { new MonitorMode(1920, 1080, 60), new MonitorMode(1280, 720, 60) };
        Assert.Null(MirrorAspectPlanner.Pick(modes, new MonitorMode(1920, 1080, 60), 1.6));
    }

    [Fact]
    public void Falls_back_to_the_highest_rate_not_above_the_current_one()
    {
        var modes = new[] { new MonitorMode(1680, 1050, 59), new MonitorMode(1680, 1050, 50), new MonitorMode(1680, 1050, 120) };
        Assert.Equal(new MonitorMode(1680, 1050, 59), MirrorAspectPlanner.Pick(modes, new MonitorMode(2560, 1080, 60), 1.6));
    }
}
