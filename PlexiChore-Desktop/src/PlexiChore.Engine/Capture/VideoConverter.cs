using Vortice.Direct3D11;
using Vortice.DXGI;

namespace PlexiChore.Engine.Capture;

/// GPU scale + colour conversion (BGRA -> NV12 or BGRA) using ID3D11VideoProcessor.
/// Writes into a small ring of output textures so an async encoder can still hold the previous ones.
internal sealed class VideoConverter : IDisposable
{
    private readonly ID3D11VideoDevice _vdev;
    private readonly ID3D11VideoContext _vctx;
    private readonly ID3D11VideoProcessorEnumerator _enum;
    private readonly ID3D11VideoProcessor _vp;
    private readonly ID3D11Texture2D[] _outputs;
    private readonly ID3D11VideoProcessorOutputView[] _outViews;
    private readonly Dictionary<IntPtr, ID3D11VideoProcessorInputView> _inViews = new();
    private int _next;

    public int OutWidth { get; }
    public int OutHeight { get; }
    public Format OutFormat { get; }

    public VideoConverter(ID3D11Device device, ID3D11DeviceContext context, int inW, int inH, int outW, int outH, Format outFormat, int ring, int fps)
    {
        OutWidth = outW; OutHeight = outH; OutFormat = outFormat;
        _vdev = device.QueryInterface<ID3D11VideoDevice>();
        _vctx = context.QueryInterface<ID3D11VideoContext>();
        var desc = new VideoProcessorContentDescription
        {
            InputFrameFormat = VideoFrameFormat.Progressive,
            InputFrameRate = new Rational((uint)fps, 1),
            InputWidth = (uint)inW, InputHeight = (uint)inH,
            OutputFrameRate = new Rational((uint)fps, 1),
            OutputWidth = (uint)outW, OutputHeight = (uint)outH,
            Usage = VideoUsage.OptimalSpeed,
        };
        _enum = _vdev.CreateVideoProcessorEnumerator(desc);
        _vp = _vdev.CreateVideoProcessor(_enum, 0);

        _outputs = new ID3D11Texture2D[ring];
        _outViews = new ID3D11VideoProcessorOutputView[ring];
        for (int i = 0; i < ring; i++)
        {
            _outputs[i] = device.CreateTexture2D(new Texture2DDescription
            {
                Width = (uint)outW, Height = (uint)outH, MipLevels = 1, ArraySize = 1, Format = outFormat,
                SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Default,
                BindFlags = BindFlags.RenderTarget | (outFormat == Format.B8G8R8A8_UNorm ? BindFlags.ShaderResource : BindFlags.None),
            });
            _outViews[i] = _vdev.CreateVideoProcessorOutputView(_outputs[i], _enum, new VideoProcessorOutputViewDescription
            {
                ViewDimension = VideoProcessorOutputViewDimension.Texture2D,
                Texture2D = new Texture2DVideoProcessorOutputView { MipSlice = 0 },
            });
        }

        // Full-range RGB in; BT.709 limited-range YCbCr out (or full-range RGB for BGRA output).
        var inCs = new VideoProcessorColorSpace { Usage = 0, RGB_Range = 0, YCbCr_Matrix = 1, Nominal_Range = 2 };
        var outCs = outFormat == Format.NV12
            ? new VideoProcessorColorSpace { Usage = 0, RGB_Range = 0, YCbCr_Matrix = 1, Nominal_Range = 1 }
            : new VideoProcessorColorSpace { Usage = 0, RGB_Range = 0, YCbCr_Matrix = 1, Nominal_Range = 2 };
        _vctx.VideoProcessorSetStreamColorSpace(_vp, 0, inCs);
        _vctx.VideoProcessorSetOutputColorSpace(_vp, outCs);
        _vctx.VideoProcessorSetStreamFrameFormat(_vp, 0, VideoFrameFormat.Progressive);
        _vctx.VideoProcessorSetStreamAutoProcessingMode(_vp, 0, false);
        _vctx.VideoProcessorSetStreamSourceRect(_vp, 0, true, new Vortice.RawRect(0, 0, inW, inH));
        _vctx.VideoProcessorSetStreamDestRect(_vp, 0, true, new Vortice.RawRect(0, 0, outW, outH));
        _vctx.VideoProcessorSetOutputTargetRect(_vp, true, new Vortice.RawRect(0, 0, outW, outH));
    }

    public ID3D11Texture2D Convert(ID3D11Texture2D input)
    {
        if (!_inViews.TryGetValue(input.NativePointer, out var inView))
        {
            inView = _vdev.CreateVideoProcessorInputView(input, _enum, new VideoProcessorInputViewDescription
            {
                FourCC = 0,
                ViewDimension = VideoProcessorInputViewDimension.Texture2D,
                Texture2D = new Texture2DVideoProcessorInputView { MipSlice = 0, ArraySlice = 0 },
            });
            _inViews[input.NativePointer] = inView;
        }
        int i = _next;
        _next = (_next + 1) % _outputs.Length;
        var streams = new[] { new VideoProcessorStream { Enable = true, InputSurface = inView } };
        _vctx.VideoProcessorBlt(_vp, _outViews[i], 0, 1, streams).CheckError();
        return _outputs[i];
    }

    public void Dispose()
    {
        foreach (var v in _inViews.Values) v.Dispose();
        _inViews.Clear();
        foreach (var v in _outViews) v?.Dispose();
        foreach (var t in _outputs) t?.Dispose();
        _vp.Dispose(); _enum.Dispose(); _vctx.Dispose(); _vdev.Dispose();
    }
}

/// CPU readback via a staging texture (used by the software H.264 path and MJPEG).
internal sealed class StagingReader : IDisposable
{
    private readonly ID3D11DeviceContext _ctx;
    private readonly ID3D11Texture2D _staging;
    public StagingReader(ID3D11Device device, ID3D11DeviceContext ctx, int w, int h, Format fmt)
    {
        _ctx = ctx;
        _staging = device.CreateTexture2D(new Texture2DDescription
        {
            Width = (uint)w, Height = (uint)h, MipLevels = 1, ArraySize = 1, Format = fmt,
            SampleDescription = new SampleDescription(1, 0), Usage = ResourceUsage.Staging,
            CPUAccessFlags = CpuAccessFlags.Read, BindFlags = BindFlags.None,
        });
    }

    /// Copies src into staging, maps it and invokes the callback with (data pointer, row pitch).
    public void Read(ID3D11Texture2D src, Action<IntPtr, int> onMapped)
    {
        _ctx.CopyResource(_staging, src);
        var mapped = _ctx.Map(_staging, 0, MapMode.Read, Vortice.Direct3D11.MapFlags.None);
        try { onMapped(mapped.DataPointer, (int)mapped.RowPitch); }
        finally { _ctx.Unmap(_staging, 0); }
    }

    public void Dispose() => _staging.Dispose();
}
