using System.Diagnostics;
using System.Drawing;
using System.Windows.Forms;

namespace PlexiBench;

public sealed record MonitorDesc(string Device, Rectangle Bounds, bool Primary)
{
    public override string ToString() => $"{Device} {Bounds.Width}x{Bounds.Height} at ({Bounds.X},{Bounds.Y}){(Primary ? " primary" : "")}";
}

public static class Monitors
{
    /// All monitors in physical pixels (the process is per-monitor-v2 DPI aware).
    public static List<MonitorDesc> List()
    {
        var list = new List<MonitorDesc>();
        Native.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr h, IntPtr _, ref Native.RECT _, IntPtr _) =>
        {
            var mi = new Native.MONITORINFOEX { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<Native.MONITORINFOEX>() };
            if (Native.GetMonitorInfoW(h, ref mi))
            {
                var r = mi.rcMonitor;
                list.Add(new MonitorDesc(mi.szDevice, Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom), (mi.dwFlags & 1) != 0));
            }
            return true;
        }, IntPtr.Zero);
        return list;
    }

    /// spec: "primary", "virtual" (the newest non-primary monitor, i.e. highest DISPLAYn), "\\.\DISPLAYn",
    /// "DISPLAYn", or "x,y,w,h" (explicit physical rect, e.g. parsed from the engine CONFIG line).
    public static MonitorDesc Resolve(string spec)
    {
        var all = List();
        if (all.Count == 0) throw new InvalidOperationException("no monitors");
        if (spec.Equals("primary", StringComparison.OrdinalIgnoreCase)) return all.First(m => m.Primary);
        if (spec.Equals("virtual", StringComparison.OrdinalIgnoreCase))
        {
            var np = all.Where(m => !m.Primary).OrderByDescending(m => DisplayNumber(m.Device)).FirstOrDefault();
            return np ?? throw new InvalidOperationException("no non-primary (virtual) monitor attached; is an extend session running?");
        }
        var parts = spec.Split(',');
        if (parts.Length == 4 && parts.All(p => int.TryParse(p, out _)))
        {
            var v = parts.Select(int.Parse).ToArray();
            return new MonitorDesc("rect", new Rectangle(v[0], v[1], v[2], v[3]), false);
        }
        var dev = spec.StartsWith(@"\\.\") ? spec : @"\\.\" + spec;
        return all.FirstOrDefault(m => m.Device.Equals(dev, StringComparison.OrdinalIgnoreCase))
               ?? throw new InvalidOperationException($"monitor {spec} not found; have: {string.Join("; ", all)}");
    }

    private static int DisplayNumber(string dev) => int.TryParse(new string(dev.Reverse().TakeWhile(char.IsDigit).Reverse().ToArray()), out var n) ? n : 0;
}

public sealed record TickReport(string Kind, double Seconds, int Ticks, double TargetHz, double AchievedHz, double JitterP50Ms, double JitterP99Ms, double MaxLateMs, int LateOver2Ms)
{
    public override string ToString() =>
        $"{Kind}: {Ticks} ticks in {Seconds:F2}s = {AchievedHz:F1} Hz (target {TargetHz}), interval jitter p50 {JitterP50Ms:F2} p99 {JitterP99Ms:F2} ms, max late {MaxLateMs:F2} ms, >2ms-late {LateOver2Ms}";

    public static TickReport From(string kind, double targetHz, List<long> stamps)
    {
        double f = Stopwatch.Frequency, period = 1000.0 / targetHz;
        if (stamps.Count < 2) return new TickReport(kind, 0, stamps.Count, targetHz, 0, 0, 0, 0, 0);
        var iv = new List<double>();
        for (int i = 1; i < stamps.Count; i++) iv.Add((stamps[i] - stamps[i - 1]) * 1000.0 / f);
        var jit = iv.Select(x => Math.Abs(x - period)).OrderBy(x => x).ToList();
        double secs = (stamps[^1] - stamps[0]) / f;
        return new TickReport(kind, secs, stamps.Count, targetHz, (stamps.Count - 1) / secs,
            Stats.Percentile(jit, 50), Stats.Percentile(jit, 99), iv.Max() - period, iv.Count(x => x > period + 2));
    }
}

/// Smooth cursor circles via SetCursorPos at a fixed rate (default 125 Hz, like a typical USB mouse).
public static class CursorMotion
{
    public static TickReport Run(Rectangle area, double seconds, double hz = 125, double revPerSec = 0.5, bool dry = false, CancellationToken ct = default, Action? started = null)
    {
        Native.GetCursorPos(out var orig);
        double cx = area.X + area.Width / 2.0, cy = area.Y + area.Height / 2.0;
        double r = Math.Min(area.Width, area.Height) * 0.35;
        var stamps = new List<long>((int)(seconds * hz) + 16);
        long t0 = Stopwatch.GetTimestamp(), end = t0 + (long)(seconds * Stopwatch.Frequency);
        var prio = Thread.CurrentThread.Priority;
        Thread.CurrentThread.Priority = ThreadPriority.Highest;
        using (var tick = new PreciseTicker(hz))
        {
            while (!ct.IsCancellationRequested)
            {
                tick.Wait();
                long now = Stopwatch.GetTimestamp();
                if (now >= end) break;
                double a = 2 * Math.PI * revPerSec * (now - t0) / Stopwatch.Frequency;
                int x = (int)Math.Round(cx + r * Math.Cos(a)), y = (int)Math.Round(cy + r * Math.Sin(a));
                if (!dry) Native.SetCursorPos(x, y);
                stamps.Add(now);
                if (stamps.Count == 1) started?.Invoke();
            }
        }
        Thread.CurrentThread.Priority = prio;
        if (!dry) Native.SetCursorPos(orig.X, orig.Y);
        return TickReport.From(dry ? "cursor(dry)" : "cursor", hz, stamps);
    }
}

/// Borderless, topmost, non-activating window covering `area`, animated at `fps` from a render thread:
/// scrolling hue bands + a bouncing box + a frame counter / PC clock (readable on a tablet screencap).
public sealed class AnimWindow : Form
{
    private const int WS_EX_TOPMOST = 0x8, WS_EX_NOACTIVATE = 0x08000000, WS_EX_TOOLWINDOW = 0x80, WM_DPICHANGED = 0x02E0;
    private readonly Rectangle _area;

    private AnimWindow(Rectangle area)
    {
        _area = area;
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        BackColor = Color.Black;
        AutoScaleMode = AutoScaleMode.None;
        Bounds = area;
        Text = "PlexiChore Bench";
    }

    protected override bool ShowWithoutActivation => true;
    protected override CreateParams CreateParams
    {
        get { var cp = base.CreateParams; cp.ExStyle |= WS_EX_TOPMOST | WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW; return cp; }
    }
    protected override void OnPaintBackground(PaintEventArgs e) { } // render thread owns the pixels
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_DPICHANGED) { ForcePos(); m.Result = IntPtr.Zero; return; } // keep exact physical rect
        base.WndProc(ref m);
    }
    private void ForcePos() => Native.SetWindowPos(Handle, Native.HWND_TOPMOST, _area.X, _area.Y, _area.Width, _area.Height, Native.SWP_NOACTIVATE | Native.SWP_SHOWWINDOW);

    public static TickReport Run(Rectangle area, double seconds, double fps = 60, CancellationToken ct = default, Action? started = null)
    {
        var T = Stopwatch.StartNew();
        void D(string s) { if (Environment.GetEnvironmentVariable("PLEXI_BENCH_DEBUG") == "1") Console.Error.WriteLine($"[anim {T.ElapsedMilliseconds} ms] {s}"); }
        TickReport? report = null;
        var ui = new Thread(() =>
        {
            Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
            using var form = new AnimWindow(area);
            form.Shown += (_, _) =>
            {
                D("shown");
                form.ForcePos();
                var h = form.Handle;
                var render = new Thread(() =>
                {
                    report = form.RenderLoop(seconds, fps, ct, started);
                    D("render loop done");
                    try { form.BeginInvoke(form.Close); } catch { }
                }) { IsBackground = true, Priority = ThreadPriority.AboveNormal, Name = "bench-render" };
                render.Start();
            };
            Application.Run(form);
            D("message loop done");
        });
        ui.SetApartmentState(ApartmentState.STA);
        ui.IsBackground = true;
        ui.Start();
        ui.Join();
        D("ui thread joined");
        return report ?? new TickReport("anim", 0, 0, fps, 0, 0, 0, 0, 0);
    }

    private TickReport RenderLoop(double seconds, double fps, CancellationToken ct, Action? started)
    {
        int w = _area.Width, h = _area.Height;
        var stamps = new List<long>((int)(seconds * fps) + 16);
        using var g0 = Graphics.FromHwnd(Handle);
        using var ctx = new BufferedGraphicsContext();
        using var buf = ctx.Allocate(g0, new Rectangle(0, 0, w, h));
        var g = buf.Graphics;
        g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.None;
        g.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
        const int bands = 48;
        var brushes = Enumerable.Range(0, bands).Select(i => new SolidBrush(Hsv(360.0 * i / bands, 0.85, 0.9))).ToArray();
        using var white = new SolidBrush(Color.White);
        using var black = new SolidBrush(Color.Black);
        using var font = new Font(FontFamily.GenericMonospace, Math.Max(24, h / 18f), FontStyle.Bold, GraphicsUnit.Pixel);
        float bandW = (float)Math.Ceiling(w * 2.0 / bands); // 2 widths of bands, scrolled
        float speed = w / 4f;                                  // px/s, a full screen width every 4 s
        int box = Math.Max(80, Math.Min(w, h) / 5);
        long t0 = Stopwatch.GetTimestamp(), end = t0 + (long)(seconds * Stopwatch.Frequency);
        long frame = 0;
        using (var tick = new PreciseTicker(fps))
        {
            while (!ct.IsCancellationRequested)
            {
                long now = Stopwatch.GetTimestamp();
                if (now >= end) break;
                double t = (now - t0) / (double)Stopwatch.Frequency;
                float off = (float)(t * speed % (bandW * bands / 2));
                for (int i = -1; i < bands; i++)
                {
                    float x = i * bandW - off;
                    if (x > w || x + bandW < 0) continue;
                    g.FillRectangle(brushes[((i % bands) + bands) % bands], x, 0, bandW + 1, h);
                }
                // horizontal tear/judder detector: bouncing box (triangle wave)
                double bx = Tri(t / 3.0) * (w - box), by = Tri(t / 2.2) * (h - box);
                g.FillRectangle(white, (float)bx, (float)by, box, box);
                var label = $"#{frame:D6}  {DateTime.Now:HH:mm:ss.fff}";
                var sz = g.MeasureString(label, font);
                g.FillRectangle(black, 10, 10, sz.Width + 10, sz.Height + 6);
                g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceOver; // text needs blending
                g.DrawString(label, font, white, 15, 13);
                g.CompositingMode = System.Drawing.Drawing2D.CompositingMode.SourceCopy;
                buf.Render(g0);
                stamps.Add(Stopwatch.GetTimestamp());
                frame++;
                if (frame == 1) { end = Stopwatch.GetTimestamp() + (long)(seconds * Stopwatch.Frequency); started?.Invoke(); }
                tick.Wait();
            }
        }
        foreach (var b in brushes) b.Dispose();
        return TickReport.From("anim", fps, stamps);
    }

    private static double Tri(double x) { var f = x - Math.Floor(x); return f < 0.5 ? f * 2 : 2 - f * 2; }

    private static Color Hsv(double hDeg, double s, double v)
    {
        double c = v * s, hp = hDeg / 60, x = c * (1 - Math.Abs(hp % 2 - 1)), m = v - c;
        (double r, double g, double b) = hp switch
        {
            < 1 => (c, x, 0d), < 2 => (x, c, 0d), < 3 => (0d, c, x), < 4 => (0d, x, c), < 5 => (x, 0d, c), _ => (c, 0d, x),
        };
        return Color.FromArgb((int)((r + m) * 255), (int)((g + m) * 255), (int)((b + m) * 255));
    }
}
