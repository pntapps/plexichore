using System.Text;
using System.Text.Json;
using PlexiChore.App.ViewModels;
using PlexiChore.Engine;
using PlexiChore.Engine.Protocol;
using Xunit;

namespace PlexiChore.App.Tests;

public class DisplayScaleTests
{
    [Theory]
    [InlineData(240, 150)]   // 10-11" 1920x1200 tablets (hdpi bucket)
    [InlineData(320, 200)]   // Galaxy Tab S8 11" 2560x1600 / Tab S8+ 12.4" 2800x1752 (xhdpi)
    [InlineData(340, 200)]   // Samsung's default for Tab S8/S8+ (tie 212.5 → lower step)
    [InlineData(280, 175)]
    [InlineData(360, 225)]
    [InlineData(400, 250)]
    [InlineData(480, 250)]   // clamped to AutoMax
    [InlineData(160, 125)]   // clamped to AutoMin
    public void Auto_matches_android_ui_size(int densityDpi, int expected) =>
        Assert.Equal(expected, DisplayScale.Auto(densityDpi));

    [Fact]
    public void Auto_accounts_for_downscaled_stream()
    {
        // Tab S8 at 50% resolution: every desktop pixel is already 2 tablet pixels
        Assert.Equal(100, DisplayScale.Auto(320, pixelRatio: 2.0));
        Assert.Equal(150, DisplayScale.Auto(320, pixelRatio: 2560.0 / 1920));
        Assert.Equal(200, DisplayScale.Auto(320, pixelRatio: 0.5)); // < 1 ignored
    }

    [Fact]
    public void Auto_without_density_guesses_from_panel()
    {
        Assert.Equal(200, DisplayScale.Auto(0, 1.0, shortEdgePx: 1600));
        Assert.Equal(150, DisplayScale.Auto(0, 1.0, shortEdgePx: 1200));
    }

    [Theory]
    [InlineData(0, 0)]
    [InlineData(-5, 0)]
    [InlineData(100, 100)]
    [InlineData(200, 200)]
    [InlineData(210, 200)]
    [InlineData(240, 250)]
    [InlineData(999, 300)]
    public void SanitizeRequest_snaps_to_steps(int input, int expected) =>
        Assert.Equal(expected, DisplayScale.SanitizeRequest(input));

    [Fact]
    public void Resolve_prefers_explicit_request()
    {
        Assert.Equal(175, DisplayScale.Resolve(175, 320));
        Assert.Equal(200, DisplayScale.Resolve(0, 320));
    }

    [Fact]
    public void DpiVals_table_is_exact() =>
        Assert.Equal(new[] { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 }, DisplayScale.DpiVals);

    [Fact]
    public void FromRelative_matches_real_virtual_monitor()
    {
        // read-only probe of the VDD monitor (\\.\DISPLAY7) returned min=-1 cur=0 max=5
        var r = DisplayScale.FromRelative(-1, 0, 5)!.Value;
        Assert.Equal(new DisplayScale.Range(100, 125, 125, 250), r);
        // 1080p desktop monitor: min=0 cur=0 max=3 → recommended 100, max 175
        Assert.Equal(new DisplayScale.Range(100, 100, 100, 175), DisplayScale.FromRelative(0, 0, 3)!.Value);
    }

    [Fact]
    public void FromRelative_clamps_current_and_rejects_out_of_table()
    {
        Assert.Equal(250, DisplayScale.FromRelative(-1, 9, 5)!.Value.Current);
        Assert.Equal(100, DisplayScale.FromRelative(-1, -4, 5)!.Value.Current);
        Assert.Null(DisplayScale.FromRelative(-4, 0, 9));   // 4 + 9 ≥ 12 entries
        Assert.Null(DisplayScale.FromRelative(1, 0, 2));
    }

    [Theory]
    [InlineData(200, 125, 3)]
    [InlineData(100, 125, -1)]
    [InlineData(125, 125, 0)]
    [InlineData(250, 150, 4)]
    [InlineData(300, 100, 7)]
    public void ToRelative_is_index_difference(int percent, int recommended, int rel) =>
        Assert.Equal(rel, DisplayScale.ToRelative(percent, recommended));

    [Fact]
    public void ToRelative_rejects_unknown_values() => Assert.Null(DisplayScale.ToRelative(110, 125));

    [Fact]
    public void Round_trip_set_then_get()
    {
        var before = DisplayScale.FromRelative(-1, 0, 5)!.Value;
        var rel = DisplayScale.ToRelative(200, before.Recommended)!.Value;
        Assert.Equal(200, DisplayScale.FromRelative(-1, rel, 5)!.Value.Current);
    }

    [Fact]
    public void ClampToRange_respects_monitor_limits()
    {
        var r = new DisplayScale.Range(100, 125, 125, 175);
        Assert.Equal(175, DisplayScale.ClampToRange(250, r));
        Assert.Equal(150, DisplayScale.ClampToRange(150, r));
        Assert.Equal(100, DisplayScale.ClampToRange(50, r));
    }

    [Fact]
    public void Hello_requested_scalePercent_parses_and_defaults_to_auto()
    {
        var withScale = JsonSerializer.Deserialize<HelloMessage>(
            """{"densityDpi":320,"requested":{"mode":"extend","scalePercent":175}}""", Wire.Json)!;
        withScale.Requested.Sanitize();
        Assert.Equal(175, withScale.Requested.ScalePercent);
        Assert.Equal(320, withScale.DensityDpi);

        var old = JsonSerializer.Deserialize<HelloMessage>("""{"requested":{"mode":"extend"}}""", Wire.Json)!;
        old.Requested.Sanitize();
        Assert.Equal(0, old.Requested.ScalePercent);
    }

    [Fact]
    public void Settings_merge_scale_only_is_detected()
    {
        var cur = new RequestedSettings { Mode = "extend", ScalePercent = 0 };
        var next = cur.Merge(Encoding.UTF8.GetBytes("""{"scalePercent":225}"""));
        next.Sanitize();
        Assert.Equal(225, next.ScalePercent);
        Assert.True(DisplayScale.IsScaleOnlyChange(cur, next));

        var both = cur.Merge(Encoding.UTF8.GetBytes("""{"scalePercent":225,"fps":30}"""));
        both.Sanitize();
        Assert.False(DisplayScale.IsScaleOnlyChange(cur, both));
        Assert.False(DisplayScale.IsScaleOnlyChange(cur, cur.Clone()));
    }

    [Fact]
    public void Config_serializes_scalePercent()
    {
        var json = JsonSerializer.Serialize(new ConfigMessage { Mode = "extend", ScalePercent = 200 }, Wire.Json);
        Assert.Contains("\"scalePercent\":200", json);
    }

    [Fact]
    public void Session_card_scale_text()
    {
        Assert.Equal("Scale 200% (auto)", SessionViewModel.FormatScale(200, true));
        Assert.Equal("Scale 175%", SessionViewModel.FormatScale(175, false));
        Assert.Equal("", SessionViewModel.FormatScale(0, true));
    }
}
