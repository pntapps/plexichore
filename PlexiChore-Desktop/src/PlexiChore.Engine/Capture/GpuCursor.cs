using System.Runtime.InteropServices;
using Vortice.Direct3D;
using Vortice.Direct3D11;
using Vortice.DXGI;

namespace PlexiChore.Engine.Capture;

/// Cursor compositing entirely on the GPU (no readback, so the capture thread never waits for the GPU / encoder):
/// the pixels under the cursor are saved with CopySubresourceRegion, the cursor is drawn as one textured triangle
/// covering a viewport the size of the cursor (premultiplied alpha), inverting pixels get a second pass with an
/// "invert destination" blend. Shaders are compiled at start-up with the OS d3dcompiler_47.dll.
internal sealed unsafe class GpuCursor : IDisposable
{
    private const string Hlsl = @"
struct VO { float4 pos : SV_Position; float2 uv : TEXCOORD0; };
VO VS(uint id : SV_VertexID)
{
    VO o;
    float2 uv = float2((id << 1) & 2, id & 2);
    o.uv = uv;
    o.pos = float4(uv * float2(2, -2) + float2(-1, 1), 0, 1);
    return o;
}
Texture2D tex : register(t0);
SamplerState smp : register(s0);
float4 PS(VO i) : SV_Target { return tex.Sample(smp, i.uv); }
";

    private readonly ID3D11Device _dev;
    private readonly ID3D11DeviceContext _ctx;
    private readonly ID3D11VertexShader _vs;
    private readonly ID3D11PixelShader _ps;
    private readonly ID3D11BlendState _premul, _invert;
    private readonly ID3D11SamplerState _point;
    private readonly ID3D11RasterizerState _raster;

    private ID3D11Texture2D? _patch;
    private int _patchW, _patchH;
    private int _sx, _sy, _sw, _sh;            // saved rect (sw == 0: nothing to restore)
    private ID3D11Texture2D? _rtTex;
    private ID3D11RenderTargetView? _rtv;
    private CursorImage? _img;
    private ID3D11Texture2D? _colorTex, _maskTex;
    private ID3D11ShaderResourceView? _colorSrv, _maskSrv;

    private GpuCursor(ID3D11Device dev, ID3D11DeviceContext ctx, byte[] vs, byte[] ps)
    {
        _dev = dev; _ctx = ctx;
        fixed (byte* p = vs) _vs = dev.CreateVertexShader(p, (nuint)vs.Length, null);
        fixed (byte* p = ps) _ps = dev.CreatePixelShader(p, (nuint)ps.Length, null);

        var premul = new BlendDescription();
        premul.RenderTarget[0] = new RenderTargetBlendDescription
        {
            BlendEnable = true,
            SourceBlend = Blend.One, DestinationBlend = Blend.InverseSourceAlpha, BlendOperation = BlendOperation.Add,
            SourceBlendAlpha = Blend.Zero, DestinationBlendAlpha = Blend.One, BlendOperationAlpha = BlendOperation.Add,
            RenderTargetWriteMask = ColorWriteEnable.Red | ColorWriteEnable.Green | ColorWriteEnable.Blue,
        };
        _premul = dev.CreateBlendState(premul);
        // out = mask * (1 - dst) + dst * (1 - mask): inverts where the mask is white, leaves the rest alone
        var invert = new BlendDescription();
        invert.RenderTarget[0] = new RenderTargetBlendDescription
        {
            BlendEnable = true,
            SourceBlend = Blend.InverseDestinationColor, DestinationBlend = Blend.InverseSourceColor, BlendOperation = BlendOperation.Add,
            SourceBlendAlpha = Blend.Zero, DestinationBlendAlpha = Blend.One, BlendOperationAlpha = BlendOperation.Add,
            RenderTargetWriteMask = ColorWriteEnable.Red | ColorWriteEnable.Green | ColorWriteEnable.Blue,
        };
        _invert = dev.CreateBlendState(invert);
        _point = dev.CreateSamplerState(new SamplerDescription
        {
            Filter = Filter.MinMagMipPoint, AddressU = TextureAddressMode.Clamp, AddressV = TextureAddressMode.Clamp,
            AddressW = TextureAddressMode.Clamp, ComparisonFunc = ComparisonFunction.Never, MaxLOD = float.MaxValue,
        });
        _raster = dev.CreateRasterizerState(new RasterizerDescription(CullMode.None, FillMode.Solid) { DepthClipEnable = false, ScissorEnable = false });
    }

    private static byte[]? _vsCode, _psCode;
    private static string? _compileError;
    private static readonly object CompileLock = new();

    /// Compiles the shaders once per process (~1 s cold: loads d3dcompiler_47); called from the engine warm-up so the
    /// first frame of the first session does not pay for it.
    public static bool Precompile(out string? error)
    {
        lock (CompileLock)
        {
            if (_vsCode == null && _compileError == null)
            {
                _vsCode = Compile("VS", "vs_4_0", out _compileError);
                if (_vsCode != null) _psCode = Compile("PS", "ps_4_0", out _compileError);
                if (_psCode == null) _vsCode = null;
            }
            error = _compileError;
            return _vsCode != null;
        }
    }

    public static GpuCursor? TryCreate(ID3D11Device dev, ID3D11DeviceContext ctx, out string? error)
    {
        error = null;
        try
        {
            if (dev.FeatureLevel < FeatureLevel.Level_10_0) { error = "feature level < 10"; return null; }
            if (!Precompile(out error)) return null;
            var vs = _vsCode; var ps = _psCode;
            if (vs == null || ps == null) return null;
            return new GpuCursor(dev, ctx, vs, ps);
        }
        catch (Exception ex) { error = ex.Message; return null; }
    }

    /// Call when the frame texture was overwritten by a new desktop image.
    public void Invalidate() => _sw = 0;

    public void Restore(ID3D11Texture2D frame)
    {
        if (_sw == 0 || _patch == null) return;
        _ctx.CopySubresourceRegion(frame, 0, (uint)_sx, (uint)_sy, 0, _patch, 0, new Vortice.Mathematics.Box(0, 0, 0, _sw, _sh, 1));
        _sw = 0;
    }

    public void Draw(ID3D11Texture2D frame, int frameW, int frameH, CursorImage img, int x, int y)
    {
        int x0 = Math.Max(0, x), y0 = Math.Max(0, y);
        int x1 = Math.Min(frameW, x + img.Width), y1 = Math.Min(frameH, y + img.Height);
        int w = x1 - x0, h = y1 - y0;
        if (w <= 0 || h <= 0) return;

        EnsureImage(img);
        EnsurePatch(w, h, frame.Description.Format);
        if (!ReferenceEquals(_rtTex, frame))
        {
            _rtv?.Dispose();
            _rtv = _dev.CreateRenderTargetView(frame, null);
            _rtTex = frame;
        }

        // keep what is underneath for the next pointer-only frame
        _ctx.CopySubresourceRegion(_patch!, 0, 0, 0, 0, frame, 0, new Vortice.Mathematics.Box(x0, y0, 0, x1, y1, 1));
        _sx = x0; _sy = y0; _sw = w; _sh = h;

        _ctx.OMSetRenderTargets(_rtv!, null);
        _ctx.RSSetViewport(new Vortice.Mathematics.Viewport(x, y, img.Width, img.Height, 0f, 1f));
        _ctx.RSSetState(_raster);
        _ctx.IASetInputLayout(null);
        _ctx.IASetPrimitiveTopology(PrimitiveTopology.TriangleList);
        _ctx.VSSetShader(_vs, null, 0);
        _ctx.PSSetShader(_ps, null, 0);
        _ctx.PSSetSampler(0, _point);
        _ctx.PSSetShaderResource(0, _colorSrv!);
        _ctx.OMSetBlendState(_premul, null, 0xFFFFFFFF);
        _ctx.Draw(3, 0);
        if (_maskSrv != null)
        {
            _ctx.PSSetShaderResource(0, _maskSrv);
            _ctx.OMSetBlendState(_invert, null, 0xFFFFFFFF);
            _ctx.Draw(3, 0);
        }
        // unbind so the video processor can read the frame
        _ctx.PSSetShaderResource(0, null!);
        _ctx.OMSetRenderTargets((ID3D11RenderTargetView)null!, null);
    }

    private void EnsureImage(CursorImage img)
    {
        if (ReferenceEquals(img, _img)) return;
        _img = img;
        _colorSrv?.Dispose(); _colorTex?.Dispose(); _maskSrv?.Dispose(); _maskTex?.Dispose();
        _colorSrv = null; _colorTex = null; _maskSrv = null; _maskTex = null;
        _colorTex = CreateImmutable(img.Width, img.Height, img.Premul);
        _colorSrv = _dev.CreateShaderResourceView(_colorTex, null);
        if (img.HasXor)
        {
            var mask = new uint[img.Xor.Length];
            for (int i = 0; i < mask.Length; i++) mask[i] = img.Xor[i] != 0 ? 0xFFFFFFFFu : 0xFF000000u;
            _maskTex = CreateImmutable(img.Width, img.Height, mask);
            _maskSrv = _dev.CreateShaderResourceView(_maskTex, null);
        }
    }

    private ID3D11Texture2D CreateImmutable(int w, int h, uint[] pixels)
    {
        fixed (uint* p = pixels)
        {
            var init = new SubresourceData((IntPtr)p, (uint)(w * 4), 0);
            return _dev.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)w, Height = (uint)h, MipLevels = 1, ArraySize = 1, Format = Format.B8G8R8A8_UNorm,
                SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Immutable, BindFlags = BindFlags.ShaderResource,
            }, new[] { init });
        }
    }

    private void EnsurePatch(int w, int h, Format fmt)
    {
        if (_patch != null && _patchW >= w && _patchH >= h) return;
        _patch?.Dispose();
        _patchW = Math.Max(w, 64); _patchH = Math.Max(h, 64);
        _patch = _dev.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)_patchW, Height = (uint)_patchH, MipLevels = 1, ArraySize = 1, Format = fmt,
            SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Default, BindFlags = BindFlags.ShaderResource,
        });
        _sw = 0;
    }

    public void Dispose()
    {
        _colorSrv?.Dispose(); _colorTex?.Dispose(); _maskSrv?.Dispose(); _maskTex?.Dispose();
        _rtv?.Dispose(); _patch?.Dispose();
        _vs.Dispose(); _ps.Dispose(); _premul.Dispose(); _invert.Dispose(); _point.Dispose(); _raster.Dispose();
    }

    // ---- runtime HLSL compile via the OS compiler (d3dcompiler_47.dll ships with Windows 10) ----
    [DllImport("d3dcompiler_47.dll", CharSet = CharSet.Ansi)]
    private static extern int D3DCompile(byte[] src, nuint size, string? name, IntPtr defines, IntPtr include,
        string entry, string target, uint flags1, uint flags2, out IntPtr code, out IntPtr errors);

    private static byte[]? Compile(string entry, string target, out string? error)
    {
        error = null;
        var src = System.Text.Encoding.ASCII.GetBytes(Hlsl);
        int hr = D3DCompile(src, (nuint)src.Length, "cursor", IntPtr.Zero, IntPtr.Zero, entry, target, 1u << 15 /* OPTIMIZATION_LEVEL3 */, 0, out var code, out var errs);
        try
        {
            if (hr < 0 || code == IntPtr.Zero)
            {
                error = errs != IntPtr.Zero ? Marshal.PtrToStringAnsi(BlobPtr(errs)) : $"D3DCompile 0x{hr:X8}";
                return null;
            }
            var bytes = new byte[(int)BlobSize(code)];
            Marshal.Copy(BlobPtr(code), bytes, 0, bytes.Length);
            return bytes;
        }
        finally
        {
            if (code != IntPtr.Zero) Marshal.Release(code);
            if (errs != IntPtr.Zero) Marshal.Release(errs);
        }
    }

    private static IntPtr BlobPtr(IntPtr blob) => ((delegate* unmanaged[Stdcall]<IntPtr, IntPtr>)(*(void***)blob)[3])(blob);
    private static nuint BlobSize(IntPtr blob) => ((delegate* unmanaged[Stdcall]<IntPtr, nuint>)(*(void***)blob)[4])(blob);
}
