using System.Drawing;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace PlexiChore.App.VirtualDisplay;

/// One desktop-attached monitor as persisted/planned for "primary" mode. Plain ints so the JSON stays stable.
public sealed record MonitorPlacement(string GdiName, string MonitorId, bool IsPrimary, int X, int Y, int Width, int Height)
{
    [JsonIgnore] public Rectangle Bounds => new(X, Y, Width, Height);
    [JsonIgnore] public Point Location => new(X, Y);

    public static MonitorPlacement From(DisplayInfo d) =>
        new(d.GdiName, d.MonitorId ?? "", d.IsPrimary, d.Bounds.X, d.Bounds.Y, d.Bounds.Width, d.Bounds.Height);

    public MonitorPlacement MovedTo(Point p, bool isPrimary) => this with { X = p.X, Y = p.Y, IsPrimary = isPrimary };
}

/// The user's layout from BEFORE the virtual monitor was made primary. Persisted to %APPDATA%\PlexiChore so that a
/// crash / kill while the tablet is the main display can be undone at the next start.
public sealed record PrimaryRestoreRecord(int Version, DateTime CreatedUtc, string VirtualGdiName, List<MonitorPlacement> Original)
{
    public const int CurrentVersion = 1;

    private static readonly JsonSerializerOptions Json = new() { WriteIndented = true };

    [JsonIgnore] public MonitorPlacement? OriginalPrimary => Original.FirstOrDefault(m => m.IsPrimary);

    public string Serialize() => JsonSerializer.Serialize(this, Json);

    public static PrimaryRestoreRecord? Deserialize(string json)
    {
        try
        {
            var r = JsonSerializer.Deserialize<PrimaryRestoreRecord>(json, Json);
            return r is { Original.Count: > 0 } && r.OriginalPrimary != null ? r : null;
        }
        catch (JsonException) { return null; }
    }

    public static PrimaryRestoreRecord? Load(string path)
    {
        try { return File.Exists(path) ? Deserialize(File.ReadAllText(path)) : null; }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    /// Atomic-ish write (temp file + move) so a crash mid-write never leaves a half record.
    public void Save(string path)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var tmp = path + ".tmp";
        File.WriteAllText(tmp, Serialize());
        File.Move(tmp, path, overwrite: true);
    }

    public static void Delete(string path)
    {
        try { if (File.Exists(path)) File.Delete(path); } catch { }
    }
}

/// Pure geometry for "primary" mode (unit-tested).
public static class PrimaryLayout
{
    /// Offset that moves <paramref name="newPrimary"/> to the desktop origin.
    public static Point ComputeShift(Rectangle newPrimary) => new(-newPrimary.X, -newPrimary.Y);

    /// Shifts every monitor by the same offset so <paramref name="newPrimaryGdi"/> lands at (0,0) and is flagged primary.
    /// Relative arrangement is preserved (e.g. tablet to the right of the monitor → monitor ends up at negative X).
    public static List<MonitorPlacement> ShiftToPrimary(IReadOnlyList<MonitorPlacement> layout, string newPrimaryGdi)
    {
        var target = layout.FirstOrDefault(m => string.Equals(m.GdiName, newPrimaryGdi, StringComparison.OrdinalIgnoreCase))
                     ?? throw new ArgumentException($"{newPrimaryGdi} is not in the layout", nameof(newPrimaryGdi));
        var shift = ComputeShift(target.Bounds);
        return layout.Select(m => m.MovedTo(new Point(m.X + shift.X, m.Y + shift.Y),
            string.Equals(m.GdiName, newPrimaryGdi, StringComparison.OrdinalIgnoreCase))).ToList();
    }

    /// Finds the record entry for a currently attached monitor: by monitor device path when known, else by GDI name.
    public static MonitorPlacement? Match(PrimaryRestoreRecord record, MonitorPlacement current)
    {
        if (!string.IsNullOrEmpty(current.MonitorId))
        {
            var byId = record.Original.Where(o => string.Equals(o.MonitorId, current.MonitorId, StringComparison.OrdinalIgnoreCase)).ToList();
            if (byId.Count == 1) return byId[0];
        }
        return record.Original.FirstOrDefault(o => string.Equals(o.GdiName, current.GdiName, StringComparison.OrdinalIgnoreCase));
    }

    /// Plans the positions that put the user's original layout back, for the PHYSICAL monitors currently attached
    /// (the virtual monitor is excluded by the caller and detached in the same apply).
    /// Returns null when the original primary is no longer attached (nothing sensible to restore; Windows picks one).
    /// Monitors that were not in the record are parked to the right of the restored layout so nothing overlaps.
    public static List<MonitorPlacement>? PlanRestore(PrimaryRestoreRecord record, IReadOnlyList<MonitorPlacement> currentPhysical)
    {
        var matched = new List<(MonitorPlacement Cur, MonitorPlacement Orig)>();
        var unmatched = new List<MonitorPlacement>();
        var used = new HashSet<MonitorPlacement>();
        foreach (var c in currentPhysical)
        {
            var o = Match(record, c);
            if (o != null && used.Add(o)) matched.Add((c, o));
            else unmatched.Add(c);
        }
        var primary = matched.FirstOrDefault(m => m.Orig.IsPrimary);
        if (primary.Cur == null) return null;

        // normalise so the original primary sits at 0,0 even if the record was taken from an odd state
        var shift = ComputeShift(primary.Orig.Bounds);
        var plan = matched.Select(m => m.Cur.MovedTo(new Point(m.Orig.X + shift.X, m.Orig.Y + shift.Y), m.Orig.IsPrimary)).ToList();

        if (unmatched.Count > 0)
        {
            var union = plan.Select(p => p.Bounds).Aggregate(Rectangle.Union);
            int x = union.Right;
            foreach (var u in unmatched)
            {
                plan.Add(u.MovedTo(new Point(x, union.Top), false));
                x += Math.Max(1, u.Width);
            }
        }
        return plan;
    }

    /// True when <paramref name="current"/> already matches <paramref name="plan"/> (positions + primary flag).
    public static bool IsSatisfied(IReadOnlyList<MonitorPlacement> plan, IReadOnlyList<MonitorPlacement> current) =>
        plan.All(p => current.Any(c =>
            string.Equals(c.GdiName, p.GdiName, StringComparison.OrdinalIgnoreCase) &&
            c.X == p.X && c.Y == p.Y && c.IsPrimary == p.IsPrimary));
}
