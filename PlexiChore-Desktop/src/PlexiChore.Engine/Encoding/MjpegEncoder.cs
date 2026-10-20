using PlexiChore.Engine.Capture;
using PlexiChore.Engine.Protocol;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.WIC;

namespace PlexiChore.Engine.Codecs;

/// Motion-JPEG fallback: GPU-scaled BGRA frame -> staging readback -> WIC JPEG encoder.
internal sealed unsafe class MjpegEncoder : IVideoEncoder
{
    private readonly IWICImagingFactory _wic = new();
    private readonly StagingReader _reader;
    private readonly int _w, _h;
    private readonly float _quality;
    private readonly EncodedOutput _output;
    private readonly byte[] _bgr;
    private readonly MemoryStream _ms = new();

    public string Codec => "mjpeg";
    public string Name => "sw:WIC JPEG";
    public bool IsHardware => false;
    public Format InputFormat => Format.B8G8R8A8_UNorm;
    public int InputRingSize => 1;

    public MjpegEncoder(ID3D11Device device, ID3D11DeviceContext ctx, int w, int h, string quality, EncodedOutput output)
    {
        _w = w; _h = h; _output = output;
        _quality = quality switch { "performance" => 0.6f, "quality" => 0.9f, _ => 0.75f };
        _reader = new StagingReader(device, ctx, w, h, Format.B8G8R8A8_UNorm);
        _bgr = new byte[w * h * 3];
    }

    public void Encode(ID3D11Texture2D frame, long ptsTicks100ns, bool forceKeyframe)
    {
        int stride = _w * 3;
        _reader.Read(frame, (ptr, pitch) =>
        {
            fixed (byte* dst0 = _bgr)
            {
                for (int y = 0; y < _h; y++)
                {
                    byte* s = (byte*)ptr + (long)y * pitch;
                    byte* d = dst0 + (long)y * stride;
                    for (int x = 0; x < _w; x++)
                    {
                        d[0] = s[0]; d[1] = s[1]; d[2] = s[2];
                        s += 4; d += 3;
                    }
                }
            }
        });

        _ms.SetLength(0);
        using (var enc = _wic.CreateEncoder(ContainerFormat.Jpeg, _ms, BitmapEncoderCacheOption.NoCache))
        {
            using var frameEnc = enc.CreateNewFrame(out var props);
            try { props.Set("ImageQuality", _quality); } catch { /* keep default */ }
            frameEnc.Initialize(props);
            props.Dispose();
            frameEnc.SetSize((uint)_w, (uint)_h);
            var fmt = PixelFormat.Format24bppBGR;
            frameEnc.SetPixelFormat(ref fmt);
            if (fmt != PixelFormat.Format24bppBGR) throw new InvalidOperationException("WIC JPEG encoder rejected 24bppBGR");
            fixed (byte* p = _bgr) frameEnc.WritePixels((uint)_h, (uint)stride, (uint)_bgr.Length, p);
            frameEnc.Commit();
            enc.Commit();
        }
        _output(ptsTicks100ns / 10, VideoFlags.Keyframe, _ms.GetBuffer().AsSpan(0, (int)_ms.Length));
    }

    public void Dispose()
    {
        _reader.Dispose();
        _wic.Dispose();
    }
}
