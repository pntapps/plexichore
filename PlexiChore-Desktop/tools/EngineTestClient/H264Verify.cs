using System.Runtime.InteropServices;
using SharpGen.Runtime;
using Vortice.MediaFoundation;
using Vortice.WIC;

namespace EngineTestClient;

/// Decodes the received Annex-B stream with the Media Foundation H.264 decoder MFT and writes the last frame as JPEG.
internal static unsafe class H264Verify
{
    private const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
    private const int MF_E_TRANSFORM_STREAM_CHANGE = unchecked((int)0xC00D6D61);
    private const int MF_E_NOTACCEPTING = unchecked((int)0xC00D36B5);

    [StructLayout(LayoutKind.Sequential)]
    private struct MFT_OUTPUT_DATA_BUFFER { public uint dwStreamID; public IntPtr pSample; public uint dwStatus; public IntPtr pEvents; }

    public static (int decoded, int errors) DecodeToJpeg(List<byte[]> units, int width, int height, string jpgPath)
    {
        MediaFactory.MFStartup(true).CheckError();
        var input = new RegisterTypeInfo { GuidMajorType = MediaTypeGuids.Video, GuidSubtype = VideoFormatGuids.H264 };
        IMFTransform? mft = null;
        using (var coll = MediaFactory.MFTEnumEx(TransformCategoryGuids.VideoDecoder, 0x1 | 0x10 | 0x40, input, null))
            foreach (var a in coll) { mft = a.ActivateObject<IMFTransform>(); break; }
        if (mft == null) throw new InvalidOperationException("no H.264 decoder MFT");

        using (var t = MediaFactory.MFCreateMediaType())
        {
            t.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            t.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.H264);
            MediaFactory.MFSetAttributeSize(t, MediaTypeAttributeKeys.FrameSize, (uint)width, (uint)height);
            mft.SetInputType(0, t, 0);
        }
        SelectNv12(mft);
        mft.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
        mft.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);

        int decoded = 0, errors = 0;
        byte[]? lastFrame = null; int lastW = 0, lastH = 0, lastStride = 0;
        void Pull()
        {
            while (true)
            {
                var info = mft.GetOutputStreamInfo(0);
                using var s = MediaFactory.MFCreateSample();
                using (var b = MediaFactory.MFCreateMemoryBuffer(Math.Max(info.Size, width * height * 2))) s.AddBuffer(b);
                var odb = new MFT_OUTPUT_DATA_BUFFER { pSample = s.NativePointer };
                uint status;
                var p = mft.NativePointer;
                var fn = (delegate* unmanaged[Stdcall]<IntPtr, uint, uint, MFT_OUTPUT_DATA_BUFFER*, uint*, int>)(*(void***)p)[25];
                int hr = fn(p, 0, 1, &odb, &status);
                if (odb.pEvents != IntPtr.Zero) Marshal.Release(odb.pEvents);
                if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return;
                if (hr == MF_E_TRANSFORM_STREAM_CHANGE) { SelectNv12(mft); continue; }
                if (hr < 0) { errors++; return; }
                decoded++;
                using var cur = mft.GetOutputCurrentType(0);
                MediaFactory.MFGetAttributeSize(cur, MediaTypeAttributeKeys.FrameSize, out uint ow, out uint oh);
                uint stride = ow;
                try { stride = cur.GetUInt32(MediaTypeAttributeKeys.DefaultStride); } catch { }
                using var buf = s.ConvertToContiguousBuffer();
                buf.Lock(out var ptr, out _, out var len);
                lastFrame = new ReadOnlySpan<byte>((void*)ptr, len).ToArray();
                buf.Unlock();
                lastW = (int)ow; lastH = (int)oh; lastStride = (int)stride;
            }
        }

        long ts = 0;
        byte[]? pendingConfig = null;
        foreach (var u in units)
        {
            // codec-config messages (SPS/PPS only) are prepended to the next access unit
            bool onlyParams = IsParamsOnly(u);
            if (onlyParams) { pendingConfig = pendingConfig == null ? u : pendingConfig.Concat(u).ToArray(); continue; }
            var au = pendingConfig == null ? u : pendingConfig.Concat(u).ToArray();
            pendingConfig = null;
            using var sample = MediaFactory.MFCreateSample();
            using (var b = MediaFactory.MFCreateMemoryBuffer(au.Length))
            {
                b.Lock(out var dst, out _, out _);
                Marshal.Copy(au, 0, dst, au.Length);
                b.Unlock();
                b.CurrentLength = au.Length;
                sample.AddBuffer(b);
            }
            sample.SampleTime = ts; sample.SampleDuration = 166_666; ts += 166_666;
            for (int attempt = 0; attempt < 2; attempt++)
            {
                try { mft.ProcessInput(0, sample, 0); break; }
                catch (SharpGenException ex) when (ex.HResult == MF_E_NOTACCEPTING) { Pull(); }
                catch (SharpGenException) { errors++; break; }
            }
            Pull();
        }
        mft.ProcessMessage(TMessageType.MessageCommandDrain, UIntPtr.Zero);
        Pull();
        mft.Dispose();

        if (lastFrame != null) SaveNv12AsJpeg(lastFrame, lastW, lastH, lastStride, Math.Min(width, lastW), Math.Min(height, lastH), jpgPath);
        return (decoded, errors);
    }

    private static bool IsParamsOnly(byte[] d)
    {
        bool any = false;
        for (int i = 0; i + 3 < d.Length; i++)
            if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) { int t = d[i + 3] & 0x1F; if (t is not (7 or 8)) return false; any = true; i += 3; }
        return any;
    }

    private static void SelectNv12(IMFTransform mft)
    {
        for (int i = 0; ; i++)
        {
            IMFMediaType t;
            try { t = mft.GetOutputAvailableType(0, i); } catch { throw new InvalidOperationException("decoder offers no NV12 output"); }
            using (t)
            {
                if (t.GetGUID(MediaTypeAttributeKeys.Subtype) == VideoFormatGuids.NV12) { mft.SetOutputType(0, t, 0); return; }
            }
        }
    }

    private static void SaveNv12AsJpeg(byte[] nv12, int fw, int fh, int stride, int w, int h, string path)
    {
        var bgr = new byte[w * h * 3];
        int uvBase = stride * fh;
        for (int y = 0; y < h; y++)
        {
            for (int x = 0; x < w; x++)
            {
                double Y = nv12[y * stride + x];
                int uvi = uvBase + (y / 2) * stride + (x & ~1);
                double U = nv12[uvi] - 128.0, V = nv12[uvi + 1] - 128.0;
                double c = (Y - 16) * 1.164;
                // BT.709 limited range
                int r = (int)(c + 1.793 * V), g = (int)(c - 0.213 * U - 0.533 * V), b = (int)(c + 2.112 * U);
                int o = (y * w + x) * 3;
                bgr[o] = (byte)Math.Clamp(b, 0, 255); bgr[o + 1] = (byte)Math.Clamp(g, 0, 255); bgr[o + 2] = (byte)Math.Clamp(r, 0, 255);
            }
        }
        using var wic = new IWICImagingFactory();
        using var fs = File.Create(path);
        using var enc = wic.CreateEncoder(ContainerFormat.Jpeg, fs, BitmapEncoderCacheOption.NoCache);
        using var frame = enc.CreateNewFrame(out var props);
        frame.Initialize(props);
        frame.SetSize((uint)w, (uint)h);
        var fmt = PixelFormat.Format24bppBGR;
        frame.SetPixelFormat(ref fmt);
        fixed (byte* p = bgr) frame.WritePixels((uint)h, (uint)(w * 3), (uint)bgr.Length, p);
        frame.Commit();
        enc.Commit();
    }
}
