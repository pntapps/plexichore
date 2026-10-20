namespace PlexiChore.Engine;

/// Windows display scaling ("Scale" in Settings > Display) for the tablet's virtual monitor.
/// Pure math, shared by Engine (auto value, protocol sanitising) and App (DisplayConfig relative-index conversion).
public static class DisplayScale
{
    /// Every scale Windows can expose for a monitor, in order. DisplayConfig's GET/SET_DPI_SCALE work with indices into
    /// this table RELATIVE to the monitor's recommended scale (same table as the SetDPI / windows-DPI-scaling-sample tool).
    public static readonly IReadOnlyList<int> DpiVals = new[] { 100, 125, 150, 175, 200, 225, 250, 300, 350, 400, 450, 500 };

    /// Values a tablet may request (protocol `requested.scalePercent`); 0 = auto.
    public static readonly IReadOnlyList<int> Requestable = new[] { 100, 125, 150, 175, 200, 225, 250, 300 };

    public const int AutoMin = 125, AutoMax = 250;

    /// Snaps a requested value onto <see cref="Requestable"/>; anything &lt;= 0 (or garbage) = 0 = auto.
    public static int SanitizeRequest(int percent) => percent <= 0 ? 0 : Nearest(percent, Requestable);

    /// Nearest step (ties go to the smaller step: on a tie, smaller text loses less desktop space).
    public static int Nearest(double percent, IReadOnlyList<int> steps)
    {
        int best = steps[0];
        double bestDiff = double.MaxValue;
        foreach (var s in steps)
        {
            double d = Math.Abs(s - percent);
            if (d < bestDiff - 1e-9) { best = s; bestDiff = d; }
        }
        return best;
    }

    /// Auto scale: make Windows UI the same physical size as the tablet's own Android UI. Android draws 1 dp as
    /// densityDpi/160 physical pixels and Windows draws 1 DIP as scale/100 desktop pixels, so scale = densityDpi/160 —
    /// divided by <paramref name="pixelRatio"/> (tablet pixels per virtual-monitor pixel, &gt; 1 when the resolution
    /// scale is below 100%). Android's densityDpi already follows the user's "Screen zoom" setting.
    /// Typical results: 10-11" 1920x1200 (240 dpi) → 150%, Tab S8 11" 2560x1600 (320/340 dpi) → 200%,
    /// Tab S8+ 12.4" 2800x1752 (320/340 dpi) → 200%.
    /// Clamped to [125, 250] (100 is allowed when the stream is downscaled).
    public static int Auto(int densityDpi, double pixelRatio = 1.0, int shortEdgePx = 0)
    {
        if (!double.IsFinite(pixelRatio) || pixelRatio < 1.0) pixelRatio = 1.0;
        double native = densityDpi > 0
            ? densityDpi / 160.0
            : shortEdgePx >= 1500 ? 2.0 : 1.5;      // unknown density: guess from the panel
        double pct = native * 100.0 / pixelRatio;
        int min = pixelRatio > 1.15 ? 100 : AutoMin;
        return Math.Clamp(Nearest(pct, Requestable), min, AutoMax);
    }

    /// Requested (0 = auto) → concrete percent.
    public static int Resolve(int requestedPercent, int densityDpi, double pixelRatio = 1.0, int shortEdgePx = 0)
    {
        var r = SanitizeRequest(requestedPercent);
        return r == 0 ? Auto(densityDpi, pixelRatio, shortEdgePx) : r;
    }

    /// Absolute view of DISPLAYCONFIG_SOURCE_DPI_SCALE_GET (all percents).
    public readonly record struct Range(int Min, int Current, int Recommended, int Max);

    /// Converts GET_DPI_SCALE's relative values (minScaleRel ≤ 0, curScaleRel, maxScaleRel ≥ 0, relative to the
    /// recommended scale) into percents. Null when they don't fit the table. Mirrors SetDPI's GetDPIScalingInfo.
    public static Range? FromRelative(int minRel, int curRel, int maxRel)
    {
        if (minRel > 0 || maxRel < 0) return null;
        int rec = -minRel;                        // index of the recommended scale (min scale is always DpiVals[0])
        if (rec + maxRel >= DpiVals.Count) return null;
        int cur = Math.Clamp(curRel, minRel, maxRel);
        return new Range(DpiVals[rec + minRel], DpiVals[rec + cur], DpiVals[rec], DpiVals[rec + maxRel]);
    }

    /// Percent → SET_DPI_SCALE's scaleRel (index difference to the recommended scale). Null if not in the table.
    public static int? ToRelative(int percent, int recommendedPercent)
    {
        int i = IndexOf(percent), r = IndexOf(recommendedPercent);
        return i < 0 || r < 0 ? null : i - r;
    }

    /// Clamps to the monitor's allowed range and snaps onto the table.
    public static int ClampToRange(int percent, Range range)
    {
        var allowed = DpiVals.Where(v => v >= range.Min && v <= range.Max).ToList();
        return allowed.Count == 0 ? range.Current : Nearest(percent, allowed);
    }

    /// True when <paramref name="next"/> differs from <paramref name="current"/> only in ScalePercent (SETTINGS that can
    /// be applied live, without re-attaching the monitor or restarting the stream).
    public static bool IsScaleOnlyChange(Protocol.RequestedSettings current, Protocol.RequestedSettings next)
    {
        if (current.ScalePercent == next.ScalePercent) return false;
        var probe = next.Clone();
        probe.ScalePercent = current.ScalePercent;
        return System.Text.Json.JsonSerializer.Serialize(probe, Protocol.Wire.Json) ==
               System.Text.Json.JsonSerializer.Serialize(current, Protocol.Wire.Json);
    }

    private static int IndexOf(int percent)
    {
        for (int i = 0; i < DpiVals.Count; i++) if (DpiVals[i] == percent) return i;
        return -1;
    }
}
