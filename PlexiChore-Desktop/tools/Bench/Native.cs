using System.Diagnostics;
using System.Runtime.InteropServices;

namespace PlexiBench;

internal static unsafe class Native
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string szDevice;
    }

    public delegate bool MonitorEnumProc(IntPtr hMonitor, IntPtr hdc, ref RECT rc, IntPtr data);

    [DllImport("user32.dll")] public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr clip, MonitorEnumProc cb, IntPtr data);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern bool GetMonitorInfoW(IntPtr hMon, ref MONITORINFOEX mi);
    [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
    [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
    [DllImport("user32.dll")] public static extern IntPtr SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern IntPtr GetThreadDpiAwarenessContext();
    [DllImport("user32.dll")] public static extern int GetAwarenessFromDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint ms);
    [DllImport("winmm.dll")] public static extern uint timeEndPeriod(uint ms);
    [DllImport("dwmapi.dll")] public static extern int DwmFlush();

    [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    public static extern IntPtr CreateWaitableTimerExW(IntPtr attrs, string? name, uint flags, uint access);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetWaitableTimer(IntPtr h, ref long due, int periodMs, IntPtr cb, IntPtr arg, bool resume);
    [DllImport("kernel32.dll")] public static extern uint WaitForSingleObject(IntPtr h, uint ms);
    [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);

    public static readonly IntPtr HWND_TOPMOST = new(-1);
    public const uint SWP_NOACTIVATE = 0x10, SWP_SHOWWINDOW = 0x40;
    public static readonly IntPtr DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2 = new(-4);

    public static void EnsurePerMonitorDpi()
    {
        // Manifest already requests PMv2; this is a belt-and-braces call (fails harmlessly if already set).
        SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }

    public static string DpiAwarenessName() => GetAwarenessFromDpiAwarenessContext(GetThreadDpiAwarenessContext()) switch
    {
        0 => "unaware", 1 => "system", 2 => "per-monitor", _ => "?",
    };
}

/// High-resolution periodic ticker (CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, Win10 1803+) with a
/// drift-free absolute schedule: tick n is due at start + n*period. Falls back to Sleep(1)+spin.
internal sealed class PreciseTicker : IDisposable
{
    private const uint CREATE_WAITABLE_TIMER_HIGH_RESOLUTION = 0x2, TIMER_ALL_ACCESS = 0x1F0003;
    private readonly IntPtr _timer;
    private readonly long _periodTicks;
    private readonly long _start;
    private long _n;

    public PreciseTicker(double hz)
    {
        _periodTicks = (long)(Stopwatch.Frequency / hz);
        _timer = Native.CreateWaitableTimerExW(IntPtr.Zero, null, CREATE_WAITABLE_TIMER_HIGH_RESOLUTION, TIMER_ALL_ACCESS);
        if (_timer == IntPtr.Zero) Native.timeBeginPeriod(1);
        _start = Stopwatch.GetTimestamp();
    }

    public bool HighResolution => _timer != IntPtr.Zero;

    /// Blocks until the next tick is due; returns the tick index (skips ticks if we fell behind).
    public long Wait()
    {
        _n++;
        long due = _start + _n * _periodTicks;
        long now = Stopwatch.GetTimestamp();
        if (now > due + _periodTicks) // fell behind by >1 period: resync instead of bursting
        {
            _n = (now - _start) / _periodTicks + 1;
            due = _start + _n * _periodTicks;
        }
        long remain = due - Stopwatch.GetTimestamp();
        if (remain > Stopwatch.Frequency / 2000) // > 0.5 ms: sleep on the timer, leaving ~0.3 ms to spin
        {
            long hns = -(long)((remain - Stopwatch.Frequency * 3 / 10000) * 10_000_000.0 / Stopwatch.Frequency);
            if (_timer != IntPtr.Zero && hns < 0 && Native.SetWaitableTimer(_timer, ref hns, 0, IntPtr.Zero, IntPtr.Zero, false))
                Native.WaitForSingleObject(_timer, 1000);
            else
                while (due - Stopwatch.GetTimestamp() > Stopwatch.Frequency / 1000) Thread.Sleep(1);
        }
        while (Stopwatch.GetTimestamp() < due) Thread.SpinWait(20);
        return _n;
    }

    public void Dispose()
    {
        if (_timer != IntPtr.Zero) Native.CloseHandle(_timer); else Native.timeEndPeriod(1);
    }
}
