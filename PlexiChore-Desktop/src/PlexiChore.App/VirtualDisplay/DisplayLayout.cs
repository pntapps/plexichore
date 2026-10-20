using System.Drawing;

namespace PlexiChore.App.VirtualDisplay;

/// Pure geometry helpers (unit-tested): where to put the virtual monitor and which mode to pick.
public static class DisplayLayout
{
    /// Places a w×h monitor adjacent to <paramref name="primary"/> on the requested side, centred along the shared
    /// edge, then pushes it outward until it no longer overlaps any other monitor (so Windows doesn't re-arrange it).
    public static Point ComputePosition(Rectangle primary, IReadOnlyCollection<Rectangle> others, int w, int h, string? position)
    {
        var side = (position ?? "right").Trim().ToLowerInvariant();
        if (side is not ("left" or "right" or "top" or "bottom")) side = "right";
        Point p = side switch
        {
            "left" => new Point(primary.Left - w, primary.Top + (primary.Height - h) / 2),
            "top" => new Point(primary.Left + (primary.Width - w) / 2, primary.Top - h),
            "bottom" => new Point(primary.Left + (primary.Width - w) / 2, primary.Bottom),
            _ => new Point(primary.Right, primary.Top + (primary.Height - h) / 2),
        };
        // Keep the shared edge in contact: if the tablet is taller than primary, align top instead of going above it.
        if (side is "left" or "right" && h >= primary.Height) p.Y = primary.Top;
        if (side is "top" or "bottom" && w >= primary.Width) p.X = primary.Left;

        for (int guard = 0; guard < 32; guard++)
        {
            var r = new Rectangle(p, new Size(w, h));
            var hit = others.FirstOrDefault(o => o != primary && o.IntersectsWith(r));
            if (hit == Rectangle.Empty) break;
            p = side switch
            {
                "left" => new Point(hit.Left - w, p.Y),
                "top" => new Point(p.X, hit.Top - h),
                "bottom" => new Point(p.X, hit.Bottom),
                _ => new Point(hit.Right, p.Y),
            };
        }
        return p;
    }

    /// Picks the best available mode for the requested size/refresh (the driver's mode list is fixed at device start,
    /// so the exact tablet size may be missing; the Engine scales the stream):
    /// exact size (closest hz) → same aspect ratio, largest not exceeding the request → any mode not exceeding the
    /// request, largest (closest aspect breaks ties) → otherwise the mode closest in area (same aspect preferred).
    /// A portrait request (tablet held upright) only makes sense if the driver has a portrait mode. Without one, the
    /// best-fitting landscape mode would be a tiny one (e.g. 1600×1000 for 1600×2560), so the request is turned back
    /// to landscape: the tablet then shows the full-resolution landscape desktop and asks the user to rotate.
    /// Returns the (possibly swapped) size and whether it was swapped.
    public static (int W, int H, bool Swapped) OrientForModes(IReadOnlyCollection<DisplayMode> modes, int w, int h)
    {
        bool wantPortrait = h > w;
        if (!wantPortrait || modes.Count == 0) return (w, h, false);
        bool hasPortrait = modes.Any(m => m.Height > m.Width);
        return hasPortrait ? (w, h, false) : (h, w, true);
    }

    public static DisplayMode? ChooseMode(IReadOnlyCollection<DisplayMode> modes, int w, int h, int hz)
    {
        modes = modes.Where(m => m.Width > 0 && m.Height > 0).ToList();
        if (modes.Count == 0 || w <= 0 || h <= 0) return null;
        static int HzScore(DisplayMode m, int hz) => Math.Abs(m.Hz - hz);
        DisplayMode BestHz(IEnumerable<DisplayMode> pool) =>
            pool.OrderBy(m => HzScore(m, hz)).ThenByDescending(m => m.Hz).First();

        var exact = modes.Where(m => m.Width == w && m.Height == h).ToList();
        if (exact.Count > 0) return BestHz(exact);

        double aspect = (double)w / h;
        long area = (long)w * h;
        double AspectDiff(DisplayMode m) => Math.Abs((double)m.Width / m.Height - aspect);
        long Area(DisplayMode m) => (long)m.Width * m.Height;

        var fitting = modes.Where(m => m.Width <= w && m.Height <= h).ToList();
        var sameAspect = fitting.Where(m => AspectDiff(m) < 0.02).ToList();
        if (sameAspect.Count > 0)
        {
            var best = sameAspect.Max(Area);
            return BestHz(sameAspect.Where(m => Area(m) == best));
        }
        if (fitting.Count > 0)
        {
            var best = fitting.Max(Area);
            var pool = fitting.Where(m => Area(m) == best).ToList();
            var bestAspect = pool.Min(AspectDiff);
            return BestHz(pool.Where(m => AspectDiff(m) == bestAspect));
        }
        var closest = modes.OrderBy(m => AspectDiff(m) < 0.02 ? 0 : 1)
            .ThenBy(m => Math.Abs(Area(m) - area)).First();
        return BestHz(modes.Where(m => m.Width == closest.Width && m.Height == closest.Height));
    }

    /// Normalises a requested size to even dimensions within sane bounds.
    public static (int W, int H) Sanitize(int w, int h)
    {
        w = Math.Clamp(w, 640, 7680) & ~1;
        h = Math.Clamp(h, 480, 4320) & ~1;
        return (w, h);
    }
}
