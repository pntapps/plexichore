using System.Runtime.InteropServices;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace PlexiChore.Engine.Capture;

/// A mouse cursor as per-pixel ops on BGRA: dst = dst * (255 - a) / 255 + premul; dst ^= xor.
/// This one representation covers DDA colour (alpha), masked-colour and monochrome (AND/XOR, inverting) shapes,
/// and HCURSORs rasterised by GDI.
internal sealed class CursorImage
{
    public int Width, Height, HotX, HotY;
    public uint[] Premul = Array.Empty<uint>(); // BGRA, colour premultiplied, A = coverage
    public uint[] Xor = Array.Empty<uint>();    // BGR xor mask (0 when none)
    public bool HasXor;

    private const uint DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME = 1, DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR = 2,
        DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR = 4;

    /// Builds an image from a GetFramePointerShape buffer (already at the size Windows uses on that output's DPI).
    public static unsafe CursorImage? FromDda(byte* buf, uint type, int width, int height, int pitch, int hotX, int hotY)
    {
        if (width <= 0 || height <= 0) return null;
        bool mono = type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MONOCHROME;
        int h = mono ? height / 2 : height;
        if (h <= 0 || width > 1024 || h > 1024) return null;
        var img = new CursorImage { Width = width, Height = h, HotX = hotX, HotY = hotY, Premul = new uint[width * h], Xor = new uint[width * h] };
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < width; x++)
            {
                uint p = 0, xr = 0;
                if (mono)
                {
                    int and = (buf[y * pitch + x / 8] >> (7 - x % 8)) & 1;
                    int xo = (buf[(y + h) * pitch + x / 8] >> (7 - x % 8)) & 1;
                    if (and == 0) p = xo == 0 ? 0xFF000000u : 0xFFFFFFFFu;  // opaque black / white
                    else if (xo == 1) xr = 0x00FFFFFFu;                         // invert screen
                }
                else
                {
                    uint c = *(uint*)(buf + y * pitch + x * 4);
                    uint a = c >> 24;
                    if (type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_MASKED_COLOR)
                    {
                        if (a == 0) p = c | 0xFF000000u;   // replace
                        else xr = c & 0x00FFFFFFu;          // xor with colour
                    }
                    else if (type == DXGI_OUTDUPL_POINTER_SHAPE_TYPE_COLOR)
                    {
                        uint b = (c & 0xFF) * a / 255, g = ((c >> 8) & 0xFF) * a / 255, r = ((c >> 16) & 0xFF) * a / 255;
                        p = (a << 24) | (r << 16) | (g << 8) | b;
                    }
                }
                img.Premul[y * width + x] = p;
                img.Xor[y * width + x] = xr;
                if (xr != 0) img.HasXor = true;
            }
        }
        return img;
    }

    /// Rasterises an HCURSOR with DrawIconEx at the given size by drawing it on black and on white:
    /// coverage = 255 - (white - black), colour = black result, inverted pixels show up as black->white / white->black.
    public static unsafe CursorImage? FromHCursor(IntPtr hCursor, double scale)
    {
        if (!Gdi.GetIconInfo(hCursor, out var ii)) return null;
        int bw = 32, bh = 32;
        try
        {
            var hbm = ii.hbmColor != IntPtr.Zero ? ii.hbmColor : ii.hbmMask;
            if (hbm != IntPtr.Zero && Gdi.GetObject(hbm, Marshal.SizeOf<Gdi.BITMAP>(), out var bm) != 0)
            {
                bw = bm.bmWidth;
                bh = ii.hbmColor != IntPtr.Zero ? bm.bmHeight : bm.bmHeight / 2;
            }
        }
        finally
        {
            if (ii.hbmMask != IntPtr.Zero) Gdi.DeleteObject(ii.hbmMask);
            if (ii.hbmColor != IntPtr.Zero) Gdi.DeleteObject(ii.hbmColor);
        }
        int w = Math.Clamp((int)Math.Round(bw * scale), 1, 512), h = Math.Clamp((int)Math.Round(bh * scale), 1, 512);
        var black = Render(hCursor, w, h, 0x00);
        var white = Render(hCursor, w, h, 0xFF);
        if (black == null || white == null) return null;
        var img = new CursorImage
        {
            Width = w, Height = h, HotX = (int)Math.Round(ii.xHotspot * (double)w / bw), HotY = (int)Math.Round(ii.yHotspot * (double)h / bh),
            Premul = new uint[w * h], Xor = new uint[w * h],
        };
        for (int i = 0; i < w * h; i++)
        {
            uint b = black[i] & 0xFFFFFF, wt = white[i] & 0xFFFFFF;
            int bl = Luma(b), wl = Luma(wt);
            if (wl < bl - 64) { img.Xor[i] = 0x00FFFFFF; img.HasXor = true; continue; } // inverting pixel
            int a = Math.Clamp(255 - (wl - bl), 0, 255);
            img.Premul[i] = a == 0 ? 0 : ((uint)a << 24) | b;
        }
        return img;
    }

    private static int Luma(uint c) => (int)(((c >> 16) & 0xFF) + ((c >> 8) & 0xFF) * 2 + (c & 0xFF)) / 4;

    private static unsafe uint[]? Render(IntPtr hCursor, int w, int h, byte fill)
    {
        IntPtr dc = Gdi.CreateCompatibleDC(IntPtr.Zero);
        if (dc == IntPtr.Zero) return null;
        var bi = new Gdi.BITMAPINFOHEADER { biSize = Marshal.SizeOf<Gdi.BITMAPINFOHEADER>(), biWidth = w, biHeight = -h, biPlanes = 1, biBitCount = 32 };
        IntPtr bmp = Gdi.CreateDIBSection(dc, ref bi, 0, out var bits, IntPtr.Zero, 0);
        if (bmp == IntPtr.Zero) { Gdi.DeleteDC(dc); return null; }
        var old = Gdi.SelectObject(dc, bmp);
        try
        {
            new Span<byte>((void*)bits, w * h * 4).Fill(fill);
            Gdi.DrawIconEx(dc, 0, 0, hCursor, w, h, 0, IntPtr.Zero, 0x3 /* DI_NORMAL */);
            Gdi.GdiFlush();
            return new ReadOnlySpan<uint>((void*)bits, w * h).ToArray();
        }
        finally
        {
            Gdi.SelectObject(dc, old);
            Gdi.DeleteObject(bmp);
            Gdi.DeleteDC(dc);
        }
    }
}

/// Draws a <see cref="CursorImage"/> onto a BGRA frame texture without touching the rest of the frame:
/// only the cursor rectangle is read back (tiny staging copy), blended on the CPU and written back, and the
/// pixels underneath are kept so the next pointer-only frame can restore them (no full-frame copy per move).
internal sealed class CursorOverlay : IDisposable
{
    private readonly ID3D11Device _dev;
    private readonly ID3D11DeviceContext _ctx;
    private ID3D11Texture2D? _staging;
    private int _stW, _stH;
    private uint[] _saved = Array.Empty<uint>();
    private uint[] _work = Array.Empty<uint>();
    private int _sx, _sy, _sw, _sh;   // saved (restorable) rect on the frame, sw == 0 when none

    private readonly GpuCursor? _gpu;
    public string Mode => _gpu != null ? "GPU" : "CPU";
    public string? GpuError { get; }

    public CursorOverlay(ID3D11Device dev, ID3D11DeviceContext ctx)
    {
        _dev = dev; _ctx = ctx;
        string? err = "disabled (PLEXI_CPU_CURSOR)";
        if (Environment.GetEnvironmentVariable("PLEXI_CPU_CURSOR") == null) _gpu = GpuCursor.TryCreate(dev, ctx, out err);
        GpuError = _gpu == null ? err : null;
    }

    /// Call when the frame texture was overwritten by a new desktop image (nothing to restore any more).
    public void Invalidate() { _sw = 0; _gpu?.Invalidate(); }

    /// Restores the pixels under the previously drawn cursor.
    public unsafe void Restore(ID3D11Texture2D frame)
    {
        if (_gpu != null) { _gpu.Restore(frame); return; }
        if (_sw == 0) return;
        fixed (uint* p = _saved)
        {
            var box = new Vortice.Mathematics.Box(_sx, _sy, 0, _sx + _sw, _sy + _sh, 1);
            _ctx.UpdateSubresource(frame, 0, box, (IntPtr)p, (uint)(_sw * 4), 0);
        }
        _sw = 0;
    }

    /// Draws the cursor with its top-left at (x, y) in frame pixels (clipped to the frame).
    public unsafe void Draw(ID3D11Texture2D frame, int frameW, int frameH, CursorImage img, int x, int y)
    {
        if (_gpu != null) { _gpu.Draw(frame, frameW, frameH, img, x, y); return; }
        int x0 = Math.Max(0, x), y0 = Math.Max(0, y);
        int x1 = Math.Min(frameW, x + img.Width), y1 = Math.Min(frameH, y + img.Height);
        int w = x1 - x0, h = y1 - y0;
        if (w <= 0 || h <= 0) return;

        if (_staging == null || _stW < w || _stH < h)
        {
            _staging?.Dispose();
            _stW = Math.Max(w, 64); _stH = Math.Max(h, 64);
            _staging = _dev.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)_stW, Height = (uint)_stH, MipLevels = 1, ArraySize = 1, Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Staging, CPUAccessFlags = CpuAccessFlags.Read,
            });
        }
        if (_saved.Length < w * h) { _saved = new uint[w * h]; _work = new uint[w * h]; }

        _ctx.CopySubresourceRegion(_staging, 0, 0, 0, 0, frame, 0, new Vortice.Mathematics.Box(x0, y0, 0, x1, y1, 1));
        var m = _ctx.Map(_staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        try
        {
            for (int row = 0; row < h; row++)
                new ReadOnlySpan<uint>((byte*)m.DataPointer + row * m.RowPitch, w).CopyTo(_saved.AsSpan(row * w, w));
        }
        finally { _ctx.Unmap(_staging, 0); }

        for (int row = 0; row < h; row++)
        {
            int iy = y0 - y + row;
            for (int col = 0; col < w; col++)
            {
                int ix = x0 - x + col;
                uint d = _saved[row * w + col];
                uint s = img.Premul[iy * img.Width + ix];
                uint a = s >> 24;
                if (a != 0)
                {
                    uint ia = 255 - a;
                    uint b = (d & 0xFF) * ia / 255 + (s & 0xFF);
                    uint g = ((d >> 8) & 0xFF) * ia / 255 + ((s >> 8) & 0xFF);
                    uint r = ((d >> 16) & 0xFF) * ia / 255 + ((s >> 16) & 0xFF);
                    d = 0xFF000000u | (Math.Min(r, 255u) << 16) | (Math.Min(g, 255u) << 8) | Math.Min(b, 255u);
                }
                if (img.HasXor) d ^= img.Xor[iy * img.Width + ix];
                _work[row * w + col] = d;
            }
        }
        fixed (uint* p = _work)
            _ctx.UpdateSubresource(frame, 0, new Vortice.Mathematics.Box(x0, y0, 0, x1, y1, 1), (IntPtr)p, (uint)(w * 4), 0);
        _sx = x0; _sy = y0; _sw = w; _sh = h;
    }

    public void Dispose() { _staging?.Dispose(); _staging = null; _gpu?.Dispose(); }
}

internal static class Gdi
{
    [StructLayout(LayoutKind.Sequential)]
    public struct ICONINFO { public int fIcon, xHotspot, yHotspot; public IntPtr hbmMask, hbmColor; }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAP { public int bmType, bmWidth, bmHeight, bmWidthBytes; public ushort bmPlanes, bmBitsPixel; public IntPtr bmBits; }

    [StructLayout(LayoutKind.Sequential)]
    public struct BITMAPINFOHEADER
    {
        public int biSize, biWidth, biHeight; public short biPlanes, biBitCount; public int biCompression, biSizeImage,
            biXPelsPerMeter, biYPelsPerMeter, biClrUsed, biClrImportant;
    }

    [DllImport("user32.dll")] public static extern bool GetIconInfo(IntPtr hIcon, out ICONINFO info);
    [DllImport("user32.dll")] public static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr hIcon, int cx, int cy, int step, IntPtr brush, int flags);
    [DllImport("gdi32.dll")] public static extern int GetObject(IntPtr h, int size, out BITMAP bm);
    [DllImport("gdi32.dll")] public static extern IntPtr CreateCompatibleDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern bool DeleteDC(IntPtr hdc);
    [DllImport("gdi32.dll")] public static extern IntPtr SelectObject(IntPtr hdc, IntPtr h);
    [DllImport("gdi32.dll")] public static extern bool DeleteObject(IntPtr h);
    [DllImport("gdi32.dll")] public static extern bool GdiFlush();
    [DllImport("gdi32.dll")] public static extern IntPtr CreateDIBSection(IntPtr hdc, ref BITMAPINFOHEADER bmi, uint usage, out IntPtr bits, IntPtr section, uint offset);

    [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT pt, uint flags);
    [DllImport("shcore.dll")] public static extern int GetDpiForMonitor(IntPtr hmon, int type, out uint dpiX, out uint dpiY);
    [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
}
