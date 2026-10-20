using System.Drawing;
using Microsoft.Extensions.Logging;
using PlexiChore.Engine.Native;
using SharpGen.Runtime;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;
using static PlexiChore.Engine.Native.NativeMethods;

namespace PlexiChore.Engine.Capture;

internal sealed record DxgiMonitor(int Index, string DeviceName, Rectangle Bounds, bool IsPrimary, int AdapterIndex, int OutputIndex);

internal static class Monitors
{
    /// Enumerates desktop-attached DXGI outputs. Index 0 = primary, the rest in adapter/output order.
    public static List<DxgiMonitor> Enumerate()
    {
        var raw = new List<DxgiMonitor>();
        using (new DpiScope(true))
        using (var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>())
        {
            for (uint a = 0; factory.EnumAdapters1(a, out var adapter).Success; a++)
            {
                using (adapter)
                {
                    for (uint o = 0; adapter.EnumOutputs(o, out var output).Success; o++)
                    {
                        using (output)
                        {
                            var d = output.Description;
                            if (!d.AttachedToDesktop) continue;
                            var r = d.DesktopCoordinates;
                            var rect = Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
                            raw.Add(new DxgiMonitor(0, d.DeviceName, rect, r.Left == 0 && r.Top == 0, (int)a, (int)o));
                        }
                    }
                }
            }
        }
        var ordered = raw.OrderByDescending(m => m.IsPrimary).ToList();
        return ordered.Select((m, i) => m with { Index = i }).ToList();
    }
}

internal enum AcquireResult { Timeout, NewFrame, PointerOnly, Lost }

/// DXGI Desktop Duplication of one output, with cursor compositing into a GDI-compatible BGRA texture.
internal sealed class DesktopCapture : IDisposable
{
    private const int DXGI_ERROR_WAIT_TIMEOUT = unchecked((int)0x887A0027);
    private const int DXGI_ERROR_ACCESS_LOST = unchecked((int)0x887A0026);

    private readonly ILogger _log;
    private readonly string _deviceName;
    private IDXGIAdapter1? _adapter;
    private IDXGIOutput1? _output;
    private IDXGIOutputDuplication? _dup;
    private ID3D11Texture2D? _frame;         // latest desktop image; the cursor is drawn into it in place
    private CursorOverlay? _overlay;
    private byte[] _shapeBuf = new byte[64 * 64 * 4];
    private CursorImage? _ddaShape, _gdiShape, _drawnImg;
    private IntPtr _gdiHandle;
    private bool _ddaSeen, _ddaVisible, _loggedShape;
    private int _ddaX, _ddaY, _drawnX, _drawnY, _shapeVersion, _drawnVersion;
    private bool _hasFrame;
    private long _nextRecreateTick;
    private long _lastCursorLog;

    public ID3D11Device Device { get; private set; } = null!;
    public ID3D11DeviceContext Context { get; private set; } = null!;
    public string DeviceName => _deviceName;
    public Rectangle DesktopBounds { get; private set; }
    public int Width => DesktopBounds.Width;
    public int Height => DesktopBounds.Height;
    public bool HasFrame => _hasFrame;
    public string AdapterName { get; private set; } = "";
    /// Set when the output resolution changed after a re-creation; the pipeline restarts on this.
    public bool SizeChanged { get; private set; }
    /// Draw the standard arrow at the cursor position even when Windows hides the cursor (e.g. no mouse attached).
    public bool DrawArrowWhenHidden { get; set; }

    private DesktopCapture(string deviceName, ILogger log) { _deviceName = deviceName; _log = log; }

    public static DesktopCapture Create(string deviceName, ILogger log, TimeSpan waitForOutput)
    {
        var cap = new DesktopCapture(deviceName, log);
        try
        {
            cap.Init(waitForOutput);
            return cap;
        }
        catch
        {
            cap.Dispose();
            throw;
        }
    }

    private void Init(TimeSpan waitForOutput)
    {
        var tsw = System.Diagnostics.Stopwatch.StartNew();
        var deadline = DateTime.UtcNow + waitForOutput;
        while (true)
        {
            if (FindOutput(out var adapter, out var output))
            {
                _adapter = adapter;
                _output = output;
                break;
            }
            if (DateTime.UtcNow > deadline) throw new InvalidOperationException($"Display output {_deviceName} not found");
            Thread.Sleep(40);
        }
        AdapterName = _adapter!.Description1.Description;
        var r = _output!.Description.DesktopCoordinates;
        DesktopBounds = Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);

        _log.LogDebug("capture: output found after {Ms} ms", tsw.ElapsedMilliseconds);
        var (device, ctx) = DevicePool.Rent(_adapter, out bool pooled);
        Device = device;
        Context = ctx;

        // First duplication: retry a little (secure desktop / mode change in progress).
        _log.LogDebug("capture: D3D11 device ({Kind}) after {Ms} ms", pooled ? "pooled" : "new", tsw.ElapsedMilliseconds);
        var dupDeadline = DateTime.UtcNow + TimeSpan.FromSeconds(3);
        while (!TryDuplicate())
        {
            if (DateTime.UtcNow > dupDeadline) throw new InvalidOperationException($"DuplicateOutput failed for {_deviceName}");
            Thread.Sleep(40);
        }
        _log.LogInformation("Capture: {Dev} {W}x{H} at ({X},{Y}) on {Adapter}", _deviceName, Width, Height, DesktopBounds.X, DesktopBounds.Y, AdapterName);
    }

    private bool FindOutput(out IDXGIAdapter1? adapterOut, out IDXGIOutput1? outputOut)
    {
        adapterOut = null; outputOut = null;
        using var factory = DXGI.CreateDXGIFactory1<IDXGIFactory1>(); // fresh factory so new (virtual) outputs show up
        for (uint a = 0; factory.EnumAdapters1(a, out var adapter).Success; a++)
        {
            for (uint o = 0; adapter.EnumOutputs(o, out var output).Success; o++)
            {
                var d = output.Description;
                if (d.AttachedToDesktop && string.Equals(d.DeviceName, _deviceName, StringComparison.OrdinalIgnoreCase))
                {
                    adapterOut = adapter;
                    outputOut = output.QueryInterface<IDXGIOutput1>();
                    output.Dispose();
                    return true;
                }
                output.Dispose();
            }
            adapter.Dispose();
        }
        return false;
    }

    private bool TryDuplicate()
    {
        try
        {
            _dup?.Dispose();
            _dup = null;
            TrySwitchToInputDesktop();
            _dup = _output!.DuplicateOutput(Device);
            return true;
        }
        catch (SharpGenException ex)
        {
            _log.LogDebug("DuplicateOutput failed: 0x{Hr:X8}", ex.HResult);
            return false;
        }
    }

    private static void TrySwitchToInputDesktop()
    {
        var h = OpenInputDesktop(0, false, GENERIC_ALL);
        if (h != IntPtr.Zero)
        {
            SetThreadDesktop(h); // may fail if thread owns windows; harmless
            CloseDesktop(h);
        }
    }

    /// Re-creates the duplication after ACCESS_LOST (mode change, UAC/secure desktop, lock screen, fullscreen app).
    private void Recreate()
    {
        if (Environment.TickCount64 < _nextRecreateTick) return;
        _nextRecreateTick = Environment.TickCount64 + 250;
        var removed = Device.DeviceRemovedReason;
        if (removed.Failure)
        {
            // GPU reset / driver update / adapter change: this device is dead, the pipeline must start over.
            _log.LogWarning("D3D device removed (0x{Hr:X8}); restarting capture", removed.Code);
            SizeChanged = true;
            return;
        }
        _dup?.Dispose();
        _dup = null;

        // The output object can become stale after a mode change; look it up again on the same adapter.
        if (FindOutput(out var adapter, out var output))
        {
            var r = output!.Description.DesktopCoordinates;
            var bounds = Rectangle.FromLTRB(r.Left, r.Top, r.Right, r.Bottom);
            bool sameAdapter = adapter!.Description1.Luid.Equals(_adapter!.Description1.Luid);
            if (!sameAdapter)
            {
                _log.LogWarning("Output {Dev} moved to another adapter; restarting capture", _deviceName);
                adapter.Dispose(); output.Dispose();
                SizeChanged = true;
                return;
            }
            _output!.Dispose();
            _output = output;
            adapter.Dispose();
            if (bounds.Size != DesktopBounds.Size)
            {
                _log.LogInformation("Output {Dev} size changed {Old} -> {New}", _deviceName, DesktopBounds.Size, bounds.Size);
                SizeChanged = true;
            }
            DesktopBounds = bounds;
        }
        if (TryDuplicate()) _log.LogInformation("Desktop duplication re-created for {Dev}", _deviceName);
    }

    public AcquireResult Acquire(int timeoutMs)
    {
        if (_dup == null)
        {
            Recreate();
            if (_dup == null) { Thread.Sleep(Math.Min(timeoutMs, 50)); return AcquireResult.Lost; }
        }

        Result r;
        OutduplFrameInfo info;
        IDXGIResource? res;
        try
        {
            r = _dup.AcquireNextFrame((uint)Math.Max(0, timeoutMs), out info, out res);
        }
        catch (SharpGenException ex)
        {
            r = new Result(ex.HResult); info = default; res = null;
        }

        if (r.Code == DXGI_ERROR_WAIT_TIMEOUT)
            return CursorStateChanged() ? AcquireResult.PointerOnly : AcquireResult.Timeout;
        if (r.Failure)
        {
            if (r.Code != DXGI_ERROR_ACCESS_LOST) _log.LogDebug("AcquireNextFrame 0x{Hr:X8}", r.Code);
            _dup.Dispose();
            _dup = null;
            return AcquireResult.Lost;
        }

        var result = AcquireResult.Timeout;
        try
        {
            if (info.LastMouseUpdateTime != 0)
            {
                // DDA pointer data: position (relative to this output, top-left of the shape) and visibility.
                _ddaSeen = true;
                _ddaVisible = info.PointerPosition.Visible;
                _ddaX = info.PointerPosition.Position.X;
                _ddaY = info.PointerPosition.Position.Y;
                if (info.PointerShapeBufferSize > 0) ReadPointerShape(info.PointerShapeBufferSize);
            }
            if (info.LastPresentTime != 0 && res != null)
            {
                using var tex = res.QueryInterface<ID3D11Texture2D>();
                EnsureTextures(tex.Description);
                Context.CopyResource(_frame!, tex);
                _overlay?.Invalidate();
                _hasFrame = true;
                result = AcquireResult.NewFrame;
            }
        }
        finally
        {
            res?.Dispose();
            try { _dup.ReleaseFrame(); } catch (SharpGenException) { }
        }
        if (result == AcquireResult.Timeout && CursorStateChanged()) result = AcquireResult.PointerOnly;
        return result;
    }

    private unsafe void ReadPointerShape(uint size)
    {
        if (_shapeBuf.Length < size) _shapeBuf = new byte[size];
        fixed (byte* p = _shapeBuf)
        {
            var hr = _dup!.GetFramePointerShape(size, (IntPtr)p, out _, out OutduplPointerShapeInfo si);
            if (hr.Failure) return;
            var img = CursorImage.FromDda(p, (uint)si.Type, (int)si.Width, (int)si.Height, (int)si.Pitch, si.HotSpot.X, si.HotSpot.Y);
            if (img != null)
            {
                _ddaShape = img;
                _shapeVersion++;
                if (!_loggedShape)
                {
                    _loggedShape = true;
                    _log.LogInformation("Cursor: using DDA pointer shapes ({W}x{H} type {T}) on {Dev}", si.Width, si.Height, si.Type, _deviceName);
                }
            }
        }
    }

    /// What the cursor should look like right now on this output (null = nothing to draw) and its top-left in frame px.
    private (CursorImage? img, int x, int y) CurrentCursor()
    {
        if (_ddaSeen && _ddaVisible && _ddaShape != null) return (_ddaShape, _ddaX, _ddaY);

        // Fallback (no DDA pointer data, or DDA reports it hidden): the global cursor, if it is on this output.
        var ci = new CURSORINFO { cbSize = System.Runtime.InteropServices.Marshal.SizeOf<CURSORINFO>() };
        using var dpi = new DpiScope(true);
        if (!GetCursorInfo(ref ci)) return (null, 0, 0);
        var b = DesktopBounds;
        if (!b.Contains(ci.ptScreenPos.X, ci.ptScreenPos.Y)) return (null, 0, 0);
        bool showing = (ci.flags & CURSOR_SHOWING) != 0 && ci.hCursor != IntPtr.Zero;
        IntPtr h = ci.hCursor;
        if (!showing)
        {
            // Windows hides the cursor when no mouse is attached / after touch input; in tablet mouse mode the
            // user still needs to see where the pointer is.
            if (!DrawArrowWhenHidden) return (null, 0, 0);
            h = LoadCursor(IntPtr.Zero, IDC_ARROW);
            if (h == IntPtr.Zero) return (null, 0, 0);
        }
        if (_gdiShape == null || _gdiHandle != h)
        {
            _gdiShape = CursorImage.FromHCursor(h, MonitorCursorScale());
            _gdiHandle = h;
            _shapeVersion++;
        }
        if (_gdiShape == null) return (null, 0, 0);
        return (_gdiShape, ci.ptScreenPos.X - b.Left - _gdiShape.HotX, ci.ptScreenPos.Y - b.Top - _gdiShape.HotY);
    }

    /// Cursor scale for GDI-rasterised cursors: Windows sizes cursors by the DPI of the monitor they are on.
    private double MonitorCursorScale()
    {
        try
        {
            var c = DesktopBounds;
            var mon = Gdi.MonitorFromPoint(new Gdi.POINT { X = c.Left + c.Width / 2, Y = c.Top + c.Height / 2 }, 2);
            if (Gdi.GetDpiForMonitor(mon, 0, out var dx, out _) == 0 && dx > 0)
            {
                uint sys = Gdi.GetDpiForSystem();
                return sys > 0 ? (double)dx / sys : 1.0;
            }
        }
        catch { }
        return 1.0;
    }

    private bool CursorStateChanged()
    {
        if (!_hasFrame) return false;
        var (img, x, y) = CurrentCursor();
        return img != _drawnImg || (img != null && (x != _drawnX || y != _drawnY || _shapeVersion != _drawnVersion));
    }

    private void EnsureTextures(Texture2DDescription src)
    {
        if (_frame != null)
        {
            var d = _frame.Description;
            if (d.Width == src.Width && d.Height == src.Height && d.Format == src.Format) return;
            _frame.Dispose();
            _frame = null;
        }
        var desc = new Texture2DDescription
        {
            Width = src.Width, Height = src.Height, MipLevels = 1, ArraySize = 1, Format = src.Format,
            SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Default,
            BindFlags = BindFlags.ShaderResource | BindFlags.RenderTarget,
        };
        _frame = Device.CreateTexture2D(desc);
        _overlay?.Invalidate();
        if (src.Format != Format.B8G8R8A8_UNorm)
            _log.LogWarning("Desktop format {Fmt} is not BGRA8; cursor compositing disabled", src.Format);
    }

    /// Returns the latest desktop image with the mouse cursor drawn on it. Only the cursor rectangle is touched:
    /// the pixels under the previous cursor position are restored first, so pointer-only updates cost a few KB.
    public ID3D11Texture2D? Compose(bool drawCursor = true)
    {
        if (!_hasFrame || _frame == null) return null;
        if (_frame.Description.Format != Format.B8G8R8A8_UNorm) return _frame;
        if (_overlay == null)
        {
            _overlay = new CursorOverlay(Device, Context);
            _log.LogInformation("Cursor overlay: {Mode}{Err}", _overlay.Mode, _overlay.GpuError != null ? " (GPU path: " + _overlay.GpuError + ")" : "");
        }
        _overlay.Restore(_frame);
        var (img, x, y) = drawCursor ? CurrentCursor() : (null, 0, 0);
        if (img != null) _overlay.Draw(_frame, Width, Height, img, x, y);
        _drawnImg = img; _drawnX = x; _drawnY = y; _drawnVersion = _shapeVersion;
        if (Environment.TickCount64 - _lastCursorLog > 5000)
        {
            _lastCursorLog = Environment.TickCount64;
            _log.LogDebug("cursor: dda seen={Seen} visible={Vis} pos=({X},{Y}) drawn={Drawn} at ({DX},{DY}) {W}x{H}",
                _ddaSeen, _ddaVisible, _ddaX, _ddaY, img != null, x, y, img?.Width ?? 0, img?.Height ?? 0);
        }
        return _frame;
    }

    public void Dispose()
    {
        _dup?.Dispose(); _dup = null;
        _overlay?.Dispose(); _frame?.Dispose();
        _output?.Dispose(); _adapter?.Dispose();
        if (Device != null && Context != null) DevicePool.Return(Device, Context);
    }
}
