using System.Collections.Concurrent;
using System.Drawing;
using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using PlexiChore.Engine.Protocol;
using static PlexiChore.Engine.Native.NativeMethods;

namespace PlexiChore.Engine.Input;

/// Maps tablet pointer events (normalized to the video frame) onto the captured monitor and injects them:
/// touch / pen via synthetic pointer devices (Win10 1809+), mouse mode + scroll via SendInput, KEY via SendInput.
/// Runs on its own thread with per-monitor-v2 DPI awareness so all coordinates are physical pixels.
internal sealed unsafe class InputInjector : IDisposable
{
    private readonly ILogger _log;
    private readonly BlockingCollection<object> _queue = new(new ConcurrentQueue<object>(), 512);
    private readonly Thread _thread;
    private volatile Func<Rectangle>? _bounds;
    private volatile string _touchMode = "touch";

    private IntPtr _touchDev, _penDev;
    private bool _touchDevFailed, _penDevFailed;
    private readonly Dictionary<int, POINT> _activeTouches = new();
    private int _primaryTouch = -1;
    private bool _penInRange, _penInContact;
    private POINT _penLast;
    private int _mouseTouchId = -1;
    private byte _mouseButtons;
    private float _wheelAccY, _wheelAccX;
    private int _injectErrors;

    public InputInjector(ILogger log)
    {
        _log = log;
        _thread = new Thread(Run) { IsBackground = true, Name = "PlexiChore input", Priority = ThreadPriority.Highest };
        _thread.Start();
    }

    public void SetTarget(Func<Rectangle> bounds, string touchMode)
    {
        _bounds = bounds;
        _touchMode = touchMode;
    }

    public void Post(PointerSample[] samples) { if (samples.Length > 0) _queue.TryAdd(samples); }
    public void Post(KeyMessage key) => _queue.TryAdd(key);

    private void Run()
    {
        SetThreadDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
        try
        {
            foreach (var item in _queue.GetConsumingEnumerable())
            {
                try
                {
                    if (item is PointerSample[] ps) Handle(ps);
                    else if (item is KeyMessage k) HandleKey(k);
                }
                catch (Exception ex) { _log.LogDebug("input: {Msg}", ex.Message); }
            }
        }
        finally
        {
            ReleaseAll();
            if (_touchDev != IntPtr.Zero) DestroySyntheticPointerDevice(_touchDev);
            if (_penDev != IntPtr.Zero) DestroySyntheticPointerDevice(_penDev);
        }
    }

    private POINT Map(float nx, float ny)
    {
        var b = _bounds?.Invoke() ?? Rectangle.Empty;
        if (b.Width <= 0 || b.Height <= 0) return default;
        nx = float.IsFinite(nx) ? Math.Clamp(nx, 0f, 1f) : 0f;
        ny = float.IsFinite(ny) ? Math.Clamp(ny, 0f, 1f) : 0f;
        return new POINT
        {
            X = b.Left + Math.Min(b.Width - 1, (int)MathF.Round(nx * (b.Width - 1))),
            Y = b.Top + Math.Min(b.Height - 1, (int)MathF.Round(ny * (b.Height - 1))),
        };
    }

    /// Synthetic pointer input (touch/pen) is placed relative to the virtual-desktop origin rather than in true screen
    /// coordinates: when a monitor sits left of / above the primary (primary mode moves the user's monitor to -2560,0)
    /// every contact lands shifted by that origin. Measured on Windows 11 26200; compensate before injecting.
    private static POINT ToSynthetic(POINT pt) => new()
    {
        X = pt.X - GetSystemMetrics(SM_XVIRTUALSCREEN),
        Y = pt.Y - GetSystemMetrics(SM_YVIRTUALSCREEN),
    };

    private void Handle(PointerSample[] ps)
    {
        var touches = new List<PointerSample>();
        foreach (var p in ps)
        {
            switch (p.Kind)
            {
                case 0: touches.Add(p); break;
                case 1: HandlePen(p); break;
                case 2: HandleMouse(p); break;
                case 3: HandleScroll(p); break;
            }
        }
        if (touches.Count == 0) return;
        switch (_touchMode)
        {
            case "none": return;
            case "mouse": HandleTouchAsMouse(touches); return;
            default: HandleTouch(touches); return;
        }
    }

    // ---------------- touch ----------------
    private void HandleTouch(List<PointerSample> touches)
    {
        if (_touchDev == IntPtr.Zero && !_touchDevFailed)
        {
            _touchDev = CreateSyntheticPointerDevice(PT_TOUCH, 10, POINTER_FEEDBACK_DEFAULT);
            if (_touchDev == IntPtr.Zero)
            {
                _touchDevFailed = true;
                _log.LogWarning("CreateSyntheticPointerDevice(touch) failed ({Err}); touch will be sent as mouse", Marshal.GetLastWin32Error());
            }
        }
        if (_touchDev == IntPtr.Zero) { HandleTouchAsMouse(touches); return; }

        var frame = new List<POINTER_TYPE_INFO>(10);
        var seen = new HashSet<int>();
        var removed = new List<int>();
        foreach (var t in touches)
        {
            int id = t.PointerId;
            if (!seen.Add(id)) continue;
            var pt = Map(t.X, t.Y);
            bool active = _activeTouches.ContainsKey(id);
            uint flags;
            switch (t.Action)
            {
                case 0: case 1:
                    flags = active ? POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT
                                   : POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT;
                    if (!active && _activeTouches.Count == 0) _primaryTouch = id;
                    _activeTouches[id] = pt;
                    break;
                case 2:
                    if (!active) continue;
                    flags = POINTER_FLAG_UP;
                    pt = _activeTouches[id];
                    removed.Add(id);
                    break;
                case 3:
                    if (!active) continue;
                    flags = POINTER_FLAG_UP | POINTER_FLAG_CANCELED;
                    pt = _activeTouches[id];
                    removed.Add(id);
                    break;
                default: continue; // touch hover not applicable
            }
            frame.Add(TouchInfo(id, pt, flags, t.Pressure));
        }
        // Windows requires every active contact in each frame.
        foreach (var kv in _activeTouches)
            if (!seen.Contains(kv.Key))
                frame.Add(TouchInfo(kv.Key, kv.Value, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT, 0.5f));

        foreach (var id in removed) _activeTouches.Remove(id);
        if (_activeTouches.Count == 0) _primaryTouch = -1;
        if (frame.Count == 0) return;
        InjectFrame(_touchDev, frame, onFail: () => { _activeTouches.Clear(); _primaryTouch = -1; });
    }

    private POINTER_TYPE_INFO TouchInfo(int id, POINT pt, uint flags, float pressure)
    {
        if (id == _primaryTouch) flags |= POINTER_FLAG_PRIMARY;
        flags |= POINTER_FLAG_CONFIDENCE;
        var info = new POINTER_TYPE_INFO { type = PT_TOUCH };
        info.touchInfo.pointerInfo.pointerType = PT_TOUCH;
        info.touchInfo.pointerInfo.pointerId = (uint)id;
        info.touchInfo.pointerInfo.pointerFlags = flags;
        pt = ToSynthetic(pt);
        info.touchInfo.pointerInfo.ptPixelLocation = pt;
        info.touchInfo.touchMask = TOUCH_MASK_CONTACTAREA | TOUCH_MASK_PRESSURE;
        info.touchInfo.rcContact = new RECT { left = pt.X - 2, top = pt.Y - 2, right = pt.X + 2, bottom = pt.Y + 2 };
        uint pr = (uint)Math.Clamp((int)(pressure * 1024), 0, 1024);
        info.touchInfo.pressure = (flags & POINTER_FLAG_UP) != 0 ? 0 : (pr == 0 ? 512u : pr);
        return info;
    }

    private void InjectFrame(IntPtr dev, List<POINTER_TYPE_INFO> frame, Action onFail)
    {
        var arr = frame.ToArray();
        fixed (POINTER_TYPE_INFO* p = arr)
        {
            if (!InjectSyntheticPointerInput(dev, p, (uint)arr.Length))
            {
                int err = Marshal.GetLastWin32Error();
                if (_injectErrors++ < 20) _log.LogDebug("InjectSyntheticPointerInput failed: {Err}", err);
                onFail();
            }
        }
    }

    private void HandleTouchAsMouse(List<PointerSample> touches)
    {
        PointerSample? t = null;
        foreach (var x in touches) if (_mouseTouchId < 0 ? x.Action == 0 || x.Action == 1 : x.PointerId == _mouseTouchId) { t = x; break; }
        if (t == null) return;
        var s = t.Value;
        var pt = Map(s.X, s.Y);
        switch (s.Action)
        {
            case 0: case 1:
                MouseMove(pt);
                if (_mouseTouchId < 0) { _mouseTouchId = s.PointerId; MouseButton(MOUSEEVENTF_LEFTDOWN); }
                break;
            case 2: case 3:
                if (_mouseTouchId >= 0) { MouseMove(pt); MouseButton(MOUSEEVENTF_LEFTUP); _mouseTouchId = -1; }
                break;
        }
    }

    // ---------------- pen ----------------
    private void HandlePen(PointerSample p)
    {
        if (_penDev == IntPtr.Zero && !_penDevFailed)
        {
            _penDev = CreateSyntheticPointerDevice(PT_PEN, 1, POINTER_FEEDBACK_DEFAULT);
            if (_penDev == IntPtr.Zero)
            {
                _penDevFailed = true;
                _log.LogWarning("CreateSyntheticPointerDevice(pen) failed ({Err}); pen will be sent as mouse", Marshal.GetLastWin32Error());
            }
        }
        if (_penDev == IntPtr.Zero)
        {
            // degrade to mouse
            var pt0 = Map(p.X, p.Y);
            MouseMove(pt0);
            if (p.Action == 0) MouseButton(MOUSEEVENTF_LEFTDOWN);
            else if (p.Action is 2 or 3) MouseButton(MOUSEEVENTF_LEFTUP);
            return;
        }

        var pt = Map(p.X, p.Y);
        switch (p.Action)
        {
            case 0: // down
                if (!_penInRange) InjectPen(pt, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE, p, contact: false);
                InjectPen(pt, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_FIRSTBUTTON, p, contact: true);
                _penInRange = true; _penInContact = true;
                break;
            case 1: // move
                if (_penInContact) InjectPen(pt, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_FIRSTBUTTON, p, contact: true);
                else if ((p.Buttons & 1) != 0 || p.Pressure > 0)
                {
                    if (!_penInRange) InjectPen(pt, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE, p, contact: false);
                    InjectPen(pt, POINTER_FLAG_DOWN | POINTER_FLAG_INRANGE | POINTER_FLAG_INCONTACT | POINTER_FLAG_FIRSTBUTTON, p, contact: true);
                    _penInContact = true;
                }
                else InjectPen(pt, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE, p, contact: false);
                _penInRange = true;
                break;
            case 2: // up -> still hovering
                if (_penInContact) InjectPen(pt, POINTER_FLAG_UP | POINTER_FLAG_INRANGE, p, contact: false);
                _penInContact = false; _penInRange = true;
                break;
            case 3: // cancel
                if (_penInContact || _penInRange) InjectPen(_penLast, POINTER_FLAG_UP | POINTER_FLAG_CANCELED, p, contact: false);
                _penInContact = false; _penInRange = false;
                break;
            case 4: // hover move
                if (_penInContact) { InjectPen(pt, POINTER_FLAG_UP | POINTER_FLAG_INRANGE, p, contact: false); _penInContact = false; }
                InjectPen(pt, POINTER_FLAG_UPDATE | POINTER_FLAG_INRANGE, p, contact: false);
                _penInRange = true;
                break;
            case 5: // hover exit
                if (_penInContact) { InjectPen(pt, POINTER_FLAG_UP | POINTER_FLAG_INRANGE, p, contact: false); _penInContact = false; }
                if (_penInRange) InjectPen(pt, POINTER_FLAG_UPDATE, p, contact: false);
                _penInRange = false;
                break;
        }
    }

    private void InjectPen(POINT pt, uint flags, PointerSample p, bool contact)
    {
        _penLast = pt;
        var info = new POINTER_TYPE_INFO { type = PT_PEN };
        info.penInfo.pointerInfo.pointerType = PT_PEN;
        info.penInfo.pointerInfo.pointerId = 1;
        bool barrel = (p.Buttons & 2) != 0, eraser = (p.Buttons & 4) != 0;
        if (barrel) flags |= POINTER_FLAG_SECONDBUTTON;
        info.penInfo.pointerInfo.pointerFlags = flags | POINTER_FLAG_PRIMARY | POINTER_FLAG_CONFIDENCE;
        info.penInfo.pointerInfo.ptPixelLocation = ToSynthetic(pt);
        uint penFlags = 0;
        if (barrel) penFlags |= PEN_FLAG_BARREL;
        if (eraser) penFlags |= PEN_FLAG_INVERTED | (contact ? PEN_FLAG_ERASER : 0);
        info.penInfo.penFlags = penFlags;
        info.penInfo.penMask = PEN_MASK_PRESSURE | PEN_MASK_TILT_X | PEN_MASK_TILT_Y;
        info.penInfo.pressure = contact ? (uint)Math.Clamp((int)(p.Pressure * 1024), 1, 1024) : 0;
        info.penInfo.tiltX = float.IsFinite(p.TiltX) ? Math.Clamp((int)MathF.Round(p.TiltX), -90, 90) : 0;
        info.penInfo.tiltY = float.IsFinite(p.TiltY) ? Math.Clamp((int)MathF.Round(p.TiltY), -90, 90) : 0;
        InjectFrame(_penDev, new List<POINTER_TYPE_INFO>(1) { info }, onFail: () => { });
    }

    // ---------------- mouse / scroll ----------------
    private void HandleMouse(PointerSample p)
    {
        var pt = Map(p.X, p.Y);
        MouseMove(pt);
        byte b = p.Action is 2 or 3 ? (byte)0 : p.Buttons;
        if (p.Action == 0 && b == 0) b = 1;
        byte changed = (byte)(b ^ _mouseButtons);
        if ((changed & 1) != 0) MouseButton((b & 1) != 0 ? MOUSEEVENTF_LEFTDOWN : MOUSEEVENTF_LEFTUP);
        if ((changed & 2) != 0) MouseButton((b & 2) != 0 ? MOUSEEVENTF_RIGHTDOWN : MOUSEEVENTF_RIGHTUP);
        if ((changed & 4) != 0) MouseButton((b & 4) != 0 ? MOUSEEVENTF_MIDDLEDOWN : MOUSEEVENTF_MIDDLEUP);
        _mouseButtons = b;
    }

    private void HandleScroll(PointerSample p)
    {
        _wheelAccY += float.IsFinite(p.Y) ? p.Y * 120f : 0;
        _wheelAccX += float.IsFinite(p.X) ? p.X * 120f : 0;
        int dy = (int)_wheelAccY, dx = (int)_wheelAccX;
        _wheelAccY -= dy; _wheelAccX -= dx;
        if (dy != 0) SendMouse(0, 0, MOUSEEVENTF_WHEEL, dy);
        if (dx != 0) SendMouse(0, 0, MOUSEEVENTF_HWHEEL, dx);
    }

    private void MouseMove(POINT pt)
    {
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = Math.Max(2, GetSystemMetrics(SM_CXVIRTUALSCREEN)), vh = Math.Max(2, GetSystemMetrics(SM_CYVIRTUALSCREEN));
        int ax = (int)Math.Round((pt.X - vx) * 65535.0 / (vw - 1));
        int ay = (int)Math.Round((pt.Y - vy) * 65535.0 / (vh - 1));
        SendMouse(ax, ay, MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, 0);
    }

    private static void MouseButton(uint flag) => SendMouse(0, 0, flag, 0);

    private static void SendMouse(int dx, int dy, uint flags, int data)
    {
        var inp = new INPUT { type = INPUT_MOUSE };
        inp.mi.dx = dx; inp.mi.dy = dy; inp.mi.dwFlags = flags; inp.mi.mouseData = data;
        SendInput(1, &inp, sizeof(INPUT));
    }

    private void ReleaseAll()
    {
        try
        {
            if (_activeTouches.Count > 0 && _touchDev != IntPtr.Zero)
            {
                var frame = _activeTouches.Select(kv => TouchInfo(kv.Key, kv.Value, POINTER_FLAG_UP | POINTER_FLAG_CANCELED, 0)).ToList();
                InjectFrame(_touchDev, frame, () => { });
                _activeTouches.Clear();
            }
            if (_penInContact && _penDev != IntPtr.Zero) InjectPen(_penLast, POINTER_FLAG_UP | POINTER_FLAG_CANCELED, default, false);
            if (_mouseTouchId >= 0 || (_mouseButtons & 1) != 0) MouseButton(MOUSEEVENTF_LEFTUP);
            if ((_mouseButtons & 2) != 0) MouseButton(MOUSEEVENTF_RIGHTUP);
        }
        catch { }
    }

    // ---------------- keyboard ----------------
    private void HandleKey(KeyMessage k)
    {
        bool down = !string.Equals(k.Action, "up", StringComparison.OrdinalIgnoreCase);
        if (!string.IsNullOrEmpty(k.Text))
        {
            if (!down) return;
            foreach (char c in k.Text)
            {
                if (c == '\n') { SendVk(0x0D, true); SendVk(0x0D, false); continue; }
                SendUnicode(c, true); SendUnicode(c, false);
            }
            return;
        }
        ushort vk = MapAndroidKey(k.KeyCode);
        if (vk != 0) SendVk(vk, down);
    }

    private static void SendUnicode(char c, bool down)
    {
        var inp = new INPUT { type = INPUT_KEYBOARD };
        inp.ki.wScan = c;
        inp.ki.dwFlags = KEYEVENTF_UNICODE | (down ? 0 : KEYEVENTF_KEYUP);
        SendInput(1, &inp, sizeof(INPUT));
    }

    private static void SendVk(ushort vk, bool down)
    {
        var inp = new INPUT { type = INPUT_KEYBOARD };
        inp.ki.wVk = vk;
        bool ext = vk is 0x21 or 0x22 or 0x23 or 0x24 or 0x25 or 0x26 or 0x27 or 0x28 or 0x2D or 0x2E or 0xA3 or 0xA5;
        inp.ki.dwFlags = (down ? 0 : KEYEVENTF_KEYUP) | (ext ? KEYEVENTF_EXTENDEDKEY : 0);
        SendInput(1, &inp, sizeof(INPUT));
    }

    /// Android KeyEvent keycodes -> Windows virtual keys (basic set).
    private static ushort MapAndroidKey(int code) => code switch
    {
        >= 7 and <= 16 => (ushort)(0x30 + code - 7),      // 0-9
        >= 29 and <= 54 => (ushort)(0x41 + code - 29),    // A-Z
        >= 131 and <= 142 => (ushort)(0x70 + code - 131), // F1-F12
        19 => 0x26, 20 => 0x28, 21 => 0x25, 22 => 0x27,   // dpad arrows
        61 => 0x09, 62 => 0x20, 66 => 0x0D, 67 => 0x08,   // tab, space, enter, del(backspace)
        111 => 0x1B, 112 => 0x2E, 122 => 0x24, 123 => 0x23, // esc, forward del, home, end
        92 => 0x21, 93 => 0x22, 124 => 0x2D,              // page up/down, insert
        59 => 0xA0, 60 => 0xA1, 113 => 0xA2, 114 => 0xA3, 57 => 0xA4, 58 => 0xA5, // shift/ctrl/alt
        117 => 0x5B, 118 => 0x5C,                         // meta -> win
        55 => 0xBC, 56 => 0xBE, 69 => 0xBD, 70 => 0xBB, 76 => 0xBF, 74 => 0xBA, 75 => 0xDE, 71 => 0xDB, 72 => 0xDD, 73 => 0xDC, 68 => 0xC0,
        _ => 0,
    };

    public void Dispose()
    {
        _queue.CompleteAdding();
        _thread.Join(1000);
    }
}
