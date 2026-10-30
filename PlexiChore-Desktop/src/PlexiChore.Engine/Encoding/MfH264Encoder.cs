using System.Runtime.InteropServices;
using Microsoft.Extensions.Logging;
using PlexiChore.Engine.Capture;
using PlexiChore.Engine.Protocol;
using SharpGen.Runtime;
using Vortice.Direct3D11;
using Vortice.DXGI;
using Vortice.MediaFoundation;

namespace PlexiChore.Engine.Codecs;

/// H.264 encoder on a Media Foundation Transform. Hardware MFTs (NVENC / QuickSync / AMF, usually async)
/// get D3D11 NV12 textures via IMFDXGIDeviceManager; the Microsoft software MFT gets system-memory NV12.
/// Output is Annex-B; SPS/PPS are emitted as a separate codec-config VIDEO message before every IDR.
internal sealed unsafe class MfH264Encoder : IVideoEncoder
{
    // ---- HRESULTs ----
    private const int MF_E_TRANSFORM_NEED_MORE_INPUT = unchecked((int)0xC00D6D72);
    private const int MF_E_TRANSFORM_STREAM_CHANGE = unchecked((int)0xC00D6D61);
    private const int MF_E_NOTACCEPTING = unchecked((int)0xC00D36B5);

    // ---- MFTEnumEx flags ----
    private const uint MFT_ENUM_FLAG_SYNCMFT = 0x1, MFT_ENUM_FLAG_ASYNCMFT = 0x2, MFT_ENUM_FLAG_HARDWARE = 0x4,
        MFT_ENUM_FLAG_LOCALMFT = 0x10, MFT_ENUM_FLAG_SORTANDFILTER = 0x40;

    private const int MFT_OUTPUT_STREAM_PROVIDES_SAMPLES = 0x100, MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES = 0x200;

    // ---- CODECAPI / attribute GUIDs (codecapi.h, mfapi.h) ----
    private static readonly Guid IID_ICodecAPI = new("901db4c7-31ce-41a2-85dc-8fa0bf41b8da");
    private static readonly Guid IID_IMFShutdown = new("97ec2ea4-0e42-4937-97ac-9d6d328824e1");
    private static readonly Guid CODECAPI_AVLowLatencyMode = new("9c27891a-ed7a-40e1-88e8-b22727a024ee"); // == MF_LOW_LATENCY
    private static readonly Guid CODECAPI_AVEncCommonRateControlMode = new("1c0608e9-370c-4710-8a58-cb6181c42423");
    private static readonly Guid CODECAPI_AVEncCommonMeanBitRate = new("f7222374-2144-4815-b550-a37f8e12ee52");
    private static readonly Guid CODECAPI_AVEncCommonQualityVsSpeed = new("98332df8-03cd-476b-89fa-3f9e442dec9f");
    private static readonly Guid CODECAPI_AVEncMPVGOPSize = new("95f31b26-95a4-41aa-9303-246a7fc6eef1");
    private static readonly Guid CODECAPI_AVEncMPVDefaultBPictureCount = new("8d390aac-dc5c-4200-b57f-814d04babab2");
    private static readonly Guid CODECAPI_AVEncVideoForceKeyFrame = new("398c1b98-8353-475a-9ef2-8f265d260345");
    private static readonly Guid CODECAPI_AVEncCommonBufferSize = new("0db96574-b6a4-4c8b-8106-3773de0310cd");
    private static readonly Guid CODECAPI_AVEncCommonMaxBitRate = new("9651eae4-39b9-4ebf-85ef-d7f444ec7465");
    private static readonly Guid CODECAPI_AVEncH264CABACEnable = new("ee6cad62-d305-4248-a50e-e1b255f7caf8");
    private static readonly Guid CODECAPI_AVEncSliceControlMode = new("e9e782ef-5f18-44c9-a90b-e9c3c2c17b0b");
    private static readonly Guid CODECAPI_AVEncSliceControlSize = new("92f51df3-07a5-4172-aefe-c69ca3b60e35");
    private static readonly Guid CODECAPI_AVEncVideoMaxNumRefFrame = new("964829ed-94f9-43b4-b74d-ef40944b69a0");

    private const ushort VT_UI4 = 19, VT_BOOL = 11;

    [StructLayout(LayoutKind.Explicit, Size = 24)]
    private struct VARIANT
    {
        [FieldOffset(0)] public ushort vt;
        [FieldOffset(8)] public uint ulVal;
        [FieldOffset(8)] public short boolVal;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MFT_OUTPUT_DATA_BUFFER
    {
        public uint dwStreamID;
        public IntPtr pSample;
        public uint dwStatus;
        public IntPtr pEvents;
    }

    private readonly ILogger _log;
    private readonly IMFTransform _mft;
    private readonly IMFDXGIDeviceManager? _devMgr;
    private readonly IntPtr _codecApi;
    private readonly bool _async;
    private readonly bool _gpuInput;
    private readonly bool _providesSamples;
    private readonly int _outBufSize;
    private readonly int _w, _h, _fps;
    private readonly EncodedOutput _output;
    private readonly StagingReader? _staging;
    private readonly object _outLock = new();
    private readonly SemaphoreSlim _needInput = new(0, int.MaxValue);
    private readonly Thread? _eventThread;
    private readonly IMFMediaEventGenerator? _events;
    private volatile bool _disposed;
    private volatile bool _stopEvents;               // set after the drain; the event loop keeps servicing the MFT until then
    private readonly ManualResetEventSlim _drained = new(false);
    private IMFActivate? _activate;
    private volatile bool _eventThreadOwnsRelease; // Dispose gave up waiting: the event thread frees the MFT on exit
    private int _released;
    /// How long the MFT stays alive after shutdown before the last reference goes. The NVIDIA MFT keeps work items on
    /// its own RTWorkQ serial queue that can still run after Shutdown and touch the object (crash dump 2026-10-30:
    /// access violation in nvEncMFTH264x from RTWorkQ!CSerialWorkQueue after a tablet disconnected).
    private static readonly TimeSpan ReleaseDelay = TimeSpan.FromSeconds(5);
    private byte[]? _paramSets;      // cached SPS+PPS (Annex-B)
    private bool _checkedSeqHeader;
    private long _lastInputPts;
    private bool _forceSupported;
    private int _framesSinceForce = -1;
    private uint _qvs;
    private bool _loggedSlice;
    private static bool _loggedCaps;

    /// slice_type % 5 of a slice NAL (0 P, 1 B, 2 I), -1 if unparsable. Reads first_mb_in_slice and slice_type ue(v).
    private static int SliceType(byte[] d, AnnexB.Nal n)
    {
        int sc = d[n.Offset + 2] == 1 ? 3 : 4;
        int bitPos = (n.Offset + sc + 1) * 8, end = (n.Offset + n.Length) * 8;
        int ReadUe()
        {
            int zeros = 0;
            while (bitPos < end && ((d[bitPos >> 3] >> (7 - (bitPos & 7))) & 1) == 0) { zeros++; bitPos++; if (zeros > 31) return -1; }
            bitPos++;
            int v = 0;
            for (int i = 0; i < zeros && bitPos < end; i++, bitPos++) v = (v << 1) | ((d[bitPos >> 3] >> (7 - (bitPos & 7))) & 1);
            return (1 << zeros) - 1 + v;
        }
        if (ReadUe() < 0) return -1;
        int t = ReadUe();
        return t < 0 ? -1 : t % 5;
    }
    /// Sizes at which this machine's hardware encoder was too slow for the requested fps at a slower preset;
    /// later encoders at that size start directly at the fastest preset (no slow first seconds on reconnect).
    private static readonly System.Collections.Concurrent.ConcurrentDictionary<(int, int, int), byte> LearnedFast = new();

    public uint QualityVsSpeed => _qvs;

    /// Encoder knobs. Defaults are the shipped settings; PLEXI_ENC (e.g. "cabac=0,slices=4,qvs=0,profile=77,rc=0,
    /// vbv=1,lowlat=1,refs=1") overrides them for experiments (tools\EngineHost --encbench sweeps them).
    internal sealed record EncoderTuning(uint? Qvs = null, bool? Cabac = null, uint Slices = 0, bool LowLatency = true,
        uint RateControl = 0, uint? MaxRefFrames = null, uint? Profile = null, double BufferFrames = 2)
    {
        public static EncoderTuning Parse(string? spec, EncoderTuning? baseline = null)
        {
            var t = baseline ?? new EncoderTuning();
            if (string.IsNullOrWhiteSpace(spec)) return t;
            foreach (var part in spec.Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                var kv = part.Split('=', 2);
                if (kv.Length != 2) continue;
                string k = kv[0].ToLowerInvariant(), v = kv[1];
                uint.TryParse(v, out var u);
                t = k switch
                {
                    "qvs" => t with { Qvs = u },
                    "cabac" => t with { Cabac = v is "1" or "true" },
                    "slices" => t with { Slices = u },
                    "lowlat" => t with { LowLatency = v is "1" or "true" },
                    "rc" => t with { RateControl = u },
                    "refs" => t with { MaxRefFrames = u },
                    "profile" => t with { Profile = u },
                    "vbv" => t with { BufferFrames = double.TryParse(v, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var d) ? d : 2 },
                    _ => t,
                };
            }
            return t;
        }

        public override string ToString() =>
            $"qvs={Qvs?.ToString() ?? "auto"} cabac={Cabac?.ToString() ?? "default"} slices={Slices} lowlat={LowLatency} rc={RateControl} refs={MaxRefFrames?.ToString() ?? "default"} profile={Profile?.ToString() ?? "tablet"} vbv={BufferFrames}";
    }

    /// Process-wide tuning used by new encoder instances.
    internal static EncoderTuning Tuning { get; set; } = EncoderTuning.Parse(Environment.GetEnvironmentVariable("PLEXI_ENC"));

    /// Switches a running encoder to the fastest preset (CODECAPI_AVEncCommonQualityVsSpeed = 0). Returns false
    /// when already there or the encoder rejects the change.
    public bool SpeedUp()
    {
        if (_disposed || _qvs == 0) return false;
        bool ok = SetCodecValue(CODECAPI_AVEncCommonQualityVsSpeed, VT_UI4, 0);
        LearnedFast[(_w, _h, _fps)] = 0;
        if (ok) _qvs = 0;
        return ok;
    }

    private readonly long[] _inputTicks = new long[64];
    private readonly char[] _inputTag = new char[64];
    /// Diagnostics only: kind of the next submitted frame (R real change, P push/repeat, K keep-alive).
    public char NextFrameTag { get; set; } = (char)82;
    private long _statRealN;
    private long _statBusy, _statWaitTicks, _statLatTicks, _statLatMax, _statOut;

    /// (busy drops, avg wait for NeedInput ms, avg input->output latency of real frames ms, max, real frames out) since last call.
    public (long busy, double waitMs, double latMs, double latMaxMs, long outs) TakeEncoderStats()
    {
        double f = 1000.0 / System.Diagnostics.Stopwatch.Frequency;
        long outs = Interlocked.Exchange(ref _statOut, 0), real = Interlocked.Exchange(ref _statRealN, 0);
        long lat = Interlocked.Exchange(ref _statLatTicks, 0), max = Interlocked.Exchange(ref _statLatMax, 0);
        long wait = Interlocked.Exchange(ref _statWaitTicks, 0);
        return (Interlocked.Exchange(ref _statBusy, 0), outs > 0 ? wait * f / outs : 0, real > 0 ? lat * f / real : 0, max * f, real);
    }

    public string Codec => "h264";
    public string Name { get; }
    public bool IsHardware { get; }
    public Format InputFormat => Format.NV12;
    public int InputRingSize => _gpuInput ? 6 : 1;

    /// Fires on the thread that produced the output (capture thread for sync MFTs, event thread for async).
    public event Action<string>? Error;

    private MfH264Encoder(ILogger log, IMFTransform mft, string name, bool hardware, ID3D11Device device, ID3D11DeviceContext ctx,
        int w, int h, int fps, int bitrateKbps, string quality, EncodedOutput output, uint h264Profile = 100)
    {
        _log = log; _mft = mft; Name = name; IsHardware = hardware; _w = w; _h = h; _fps = fps; _output = output;

        var attrs = mft.Attributes;
        _async = TryGetU32(attrs, TransformAttributeKeys.TransformAsync) != 0;
        if (_async) attrs.Set(TransformAttributeKeys.TransformAsyncUnlock, 1u);
        try { attrs.Set(CODECAPI_AVLowLatencyMode, 1u); } catch { }
        bool d3d11Aware = TryGetU32(attrs, TransformAttributeKeys.D3D11Aware) != 0;

        if (d3d11Aware)
        {
            try
            {
                _devMgr = MediaFactory.MFCreateDXGIDeviceManager();
                _devMgr.ResetDevice(device).CheckError();
                mft.ProcessMessage(TMessageType.MessageSetD3DManager, (UIntPtr)(ulong)_devMgr.NativePointer);
                _gpuInput = true;
            }
            catch (Exception ex)
            {
                _log.LogDebug("SET_D3D_MANAGER rejected by {Name}: {Msg}", name, ex.Message);
                _devMgr?.Dispose(); _devMgr = null;
                if (hardware) throw;
            }
        }

        // ICodecAPI: low latency, CBR, no B-frames, long GOP (IDRs are forced explicitly).
        var tune = Tuning;
        Marshal.QueryInterface(mft.NativePointer, in IID_ICodecAPI, out _codecApi);
        if (_codecApi != IntPtr.Zero)
        {
            SetCodecValue(CODECAPI_AVLowLatencyMode, VT_BOOL, 0, tune.LowLatency);
            SetCodecValue(CODECAPI_AVEncCommonRateControlMode, VT_UI4, tune.RateControl /* 0 = eAVEncCommonRateControlMode_CBR */);
            SetCodecValue(CODECAPI_AVEncCommonMeanBitRate, VT_UI4, (uint)bitrateKbps * 1000);
            // VBV buffer of ~N frames: also caps the size of an IDR (big IDRs clog adb tunnels / Wi-Fi bursts)
            SetCodecValue(CODECAPI_AVEncCommonBufferSize, VT_UI4, (uint)(bitrateKbps * 1000.0 / Math.Max(1, fps) * tune.BufferFrames));
            if (tune.RateControl != 0) SetCodecValue(CODECAPI_AVEncCommonMaxBitRate, VT_UI4, (uint)bitrateKbps * 1000);
            SetCodecValue(CODECAPI_AVEncMPVDefaultBPictureCount, VT_UI4, 0);
            SetCodecValue(CODECAPI_AVEncMPVGOPSize, VT_UI4, (uint)(fps * 10));
            _qvs = quality switch { "quality" => 70u, "performance" => 0u, _ => 33u };
            if (hardware && LearnedFast.ContainsKey((w, h, fps))) _qvs = 0; // this GPU could not keep up before
            if (tune.Qvs is uint q) _qvs = q;
            SetCodecValue(CODECAPI_AVEncCommonQualityVsSpeed, VT_UI4, _qvs);
            if (tune.Cabac is bool cabac) SetCodecValue(CODECAPI_AVEncH264CABACEnable, VT_BOOL, 0, cabac);
            if (tune.MaxRefFrames is uint refs) SetCodecValue(CODECAPI_AVEncVideoMaxNumRefFrame, VT_UI4, refs);
            if (tune.Slices > 1)
            {
                // slice control mode 2 = slices per frame given as MB rows; split the frame into N row bands
                uint mbRows = (uint)((h + 15) / 16);
                if (SetCodecValue(CODECAPI_AVEncSliceControlMode, VT_UI4, 2))
                    SetCodecValue(CODECAPI_AVEncSliceControlSize, VT_UI4, Math.Max(1, (mbRows + tune.Slices - 1) / tune.Slices));
            }
            _forceSupported = IsSupported(CODECAPI_AVEncVideoForceKeyFrame);
            if (!_loggedCaps)
            {
                _loggedCaps = true;
                _log.LogDebug("{Name} ICodecAPI support: qvs={Q} cabac={C} sliceMode={S} refs={R} maxBitrate={M} bufferSize={B} lowLatency={L}; tuning {T}", name,
                    IsSupported(CODECAPI_AVEncCommonQualityVsSpeed), IsSupported(CODECAPI_AVEncH264CABACEnable), IsSupported(CODECAPI_AVEncSliceControlMode),
                    IsSupported(CODECAPI_AVEncVideoMaxNumRefFrame), IsSupported(CODECAPI_AVEncCommonMaxBitRate), IsSupported(CODECAPI_AVEncCommonBufferSize),
                    IsSupported(CODECAPI_AVLowLatencyMode), tune);
            }
        }
        if (tune.Profile is uint forced) h264Profile = forced;

        // Output type must be set before input type for encoders.
        using (var outType = MediaFactory.MFCreateMediaType())
        {
            outType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            outType.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.H264);
            outType.Set(MediaTypeAttributeKeys.AvgBitrate, (uint)bitrateKbps * 1000);
            MediaFactory.MFSetAttributeSize(outType, MediaTypeAttributeKeys.FrameSize, (uint)w, (uint)h);
            MediaFactory.MFSetAttributeRatio(outType, MediaTypeAttributeKeys.FrameRate, (uint)fps, 1);
            MediaFactory.MFSetAttributeRatio(outType, MediaTypeAttributeKeys.PixelAspectRatio, 1, 1);
            outType.Set(MediaTypeAttributeKeys.InterlaceMode, 2u /* progressive */);
            outType.Set(MediaTypeAttributeKeys.Mpeg2Profile, h264Profile is 66u or 77u or 100u ? h264Profile : 100u); // High unless the tablet decoder lacks it
            SetColorimetry(outType);
            mft.SetOutputType(0, outType, 0);
        }
        using (var inType = MediaFactory.MFCreateMediaType())
        {
            inType.Set(MediaTypeAttributeKeys.MajorType, MediaTypeGuids.Video);
            inType.Set(MediaTypeAttributeKeys.Subtype, VideoFormatGuids.NV12);
            MediaFactory.MFSetAttributeSize(inType, MediaTypeAttributeKeys.FrameSize, (uint)w, (uint)h);
            MediaFactory.MFSetAttributeRatio(inType, MediaTypeAttributeKeys.FrameRate, (uint)fps, 1);
            MediaFactory.MFSetAttributeRatio(inType, MediaTypeAttributeKeys.PixelAspectRatio, 1, 1);
            inType.Set(MediaTypeAttributeKeys.InterlaceMode, 2u);
            SetColorimetry(inType);
            mft.SetInputType(0, inType, 0);
        }

        var osi = mft.GetOutputStreamInfo(0);
        _providesSamples = (osi.Flags & (MFT_OUTPUT_STREAM_PROVIDES_SAMPLES | MFT_OUTPUT_STREAM_CAN_PROVIDE_SAMPLES)) != 0;
        _outBufSize = Math.Max(osi.Size, w * h * 3 / 2);

        if (!_gpuInput) _staging = new StagingReader(device, ctx, w, h, Format.NV12);

        mft.ProcessMessage(TMessageType.MessageNotifyBeginStreaming, UIntPtr.Zero);
        mft.ProcessMessage(TMessageType.MessageNotifyStartOfStream, UIntPtr.Zero);

        if (_async)
        {
            _events = mft.QueryInterface<IMFMediaEventGenerator>();
            _eventThread = new Thread(EventLoop) { IsBackground = true, Name = "PlexiChore MFT events", Priority = ThreadPriority.AboveNormal };
            _eventThread.Start();
        }
        _log.LogInformation("H.264 encoder: {Name} ({Kind}, {Mode}, input={Input}) {W}x{H}@{Fps} {Kbps} kbps, forceKeyFrame={Force}",
            name, hardware ? "hardware" : "software", _async ? "async" : "sync", _gpuInput ? "D3D11" : "system memory", w, h, fps, bitrateKbps, _forceSupported);
    }

    /// Tries hardware MFTs (when allowed) then the Microsoft software encoder.
    public static MfH264Encoder? TryCreate(ILogger log, ID3D11Device device, ID3D11DeviceContext ctx, int w, int h, int fps, int bitrateKbps,
        string quality, bool allowHardware, bool allowSoftware, EncodedOutput output, uint h264Profile = 100)
    {
        var input = new RegisterTypeInfo { GuidMajorType = MediaTypeGuids.Video, GuidSubtype = VideoFormatGuids.NV12 };
        var outp = new RegisterTypeInfo { GuidMajorType = MediaTypeGuids.Video, GuidSubtype = VideoFormatGuids.H264 };
        var passes = new List<(uint flags, bool hw)>();
        if (allowHardware) passes.Add((MFT_ENUM_FLAG_HARDWARE | MFT_ENUM_FLAG_ASYNCMFT | MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_SORTANDFILTER, true));
        if (allowSoftware) passes.Add((MFT_ENUM_FLAG_SYNCMFT | MFT_ENUM_FLAG_LOCALMFT | MFT_ENUM_FLAG_SORTANDFILTER, false));

        foreach (var (flags, hw) in passes)
        {
            IMFActivateCollection coll;
            try { coll = MediaFactory.MFTEnumEx(TransformCategoryGuids.VideoEncoder, flags, input, outp); }
            catch (Exception ex) { log.LogDebug("MFTEnumEx failed: {Msg}", ex.Message); continue; }
            using (coll)
            {
                foreach (var act in coll)
                {
                    string name = "H.264 MFT";
                    try { name = act.GetString(TransformAttributeKeys.MftFriendlyNameAttribute); } catch { }
                    IMFTransform? mft = null;
                    try
                    {
                        mft = act.ActivateObject<IMFTransform>();
                        var enc = new MfH264Encoder(log, mft, (hw ? "hw:" : "sw:") + name, hw, device, ctx, w, h, fps, bitrateKbps, quality, output, h264Profile);
                        // own reference: the collection releases its activates, and hardware MFTs must be shut down through it
                        enc._activate = act.QueryInterface<IMFActivate>();
                        return enc;
                    }
                    catch (Exception ex)
                    {
                        log.LogWarning("Encoder {Name} unusable: {Msg}", name, ex.Message);
                        try { mft?.Dispose(); } catch { }
                        try { act.ShutdownObject(); } catch { }
                    }
                }
            }
        }
        return null;
    }

    private static uint TryGetU32(IMFAttributes a, Guid key)
    {
        try { return a.GetUInt32(key, out var v).Success ? v : 0; } catch { return 0; }
    }

    private static void SetColorimetry(IMFMediaType t)
    {
        t.Set(MediaTypeAttributeKeys.YuvMatrix, 1u);          // MFVideoTransferMatrix_BT709
        t.Set(MediaTypeAttributeKeys.VideoPrimaries, 2u);     // MFVideoPrimaries_BT709
        t.Set(MediaTypeAttributeKeys.TransferFunction, 5u);   // MFVideoTransFunc_709
        t.Set(MediaTypeAttributeKeys.VideoNominalRange, 2u);  // MFNominalRange_16_235
    }

    private bool IsSupported(Guid api)
    {
        var fn = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, int>)(*(void***)_codecApi)[3];
        return fn(_codecApi, &api) == 0;
    }

    private bool SetCodecValue(Guid api, ushort vt, uint value, bool boolValue = false)
    {
        if (_codecApi == IntPtr.Zero) return false;
        var v = new VARIANT { vt = vt };
        if (vt == VT_BOOL) v.boolVal = (short)(boolValue ? -1 : 0); else v.ulVal = value;
        var fn = (delegate* unmanaged[Stdcall]<IntPtr, Guid*, VARIANT*, int>)(*(void***)_codecApi)[9];
        int hr = fn(_codecApi, &api, &v);
        if (hr != 0) _log.LogDebug("ICodecAPI.SetValue {Api} -> 0x{Hr:X8}", api, hr);
        return hr == 0;
    }

    private int ProcessInputRaw(IMFSample sample)
    {
        var p = _mft.NativePointer;
        var fn = (delegate* unmanaged[Stdcall]<IntPtr, uint, IntPtr, uint, int>)(*(void***)p)[24];
        return fn(p, 0, sample.NativePointer, 0);
    }

    private int ProcessOutputRaw(ref MFT_OUTPUT_DATA_BUFFER odb)
    {
        var p = _mft.NativePointer;
        uint status;
        var fn = (delegate* unmanaged[Stdcall]<IntPtr, uint, uint, MFT_OUTPUT_DATA_BUFFER*, uint*, int>)(*(void***)p)[25];
        fixed (MFT_OUTPUT_DATA_BUFFER* pb = &odb) return fn(p, 0, 1, pb, &status);
    }

    public void Encode(ID3D11Texture2D frame, long ptsTicks100ns, bool forceKeyframe)
    {
        if (_disposed) return;
        if (forceKeyframe)
        {
            if (_forceSupported) SetCodecValue(CODECAPI_AVEncVideoForceKeyFrame, VT_UI4, 1);
            _framesSinceForce = 0;
        }

        using var sample = MediaFactory.MFCreateSample();
        IMFMediaBuffer buffer;
        if (_gpuInput)
        {
            buffer = MediaFactory.MFCreateDXGISurfaceBuffer(typeof(ID3D11Texture2D).GUID, frame, 0, false);
            using (var b2 = buffer.QueryInterface<IMF2DBuffer>()) buffer.CurrentLength = b2.ContiguousLength;
        }
        else
        {
            int size = _w * _h * 3 / 2;
            buffer = MediaFactory.MFCreateMemoryBuffer(size);
            buffer.Lock(out var dst, out _, out _);
            try
            {
                _staging!.Read(frame, (src, pitch) =>
                {
                    byte* s = (byte*)src, d = (byte*)dst;
                    for (int y = 0; y < _h; y++) Buffer.MemoryCopy(s + (long)y * pitch, d + (long)y * _w, _w, _w);
                    byte* sUv = s + (long)pitch * _h, dUv = d + (long)_w * _h;
                    for (int y = 0; y < _h / 2; y++) Buffer.MemoryCopy(sUv + (long)y * pitch, dUv + (long)y * _w, _w, _w);
                });
            }
            finally { buffer.Unlock(); }
            buffer.CurrentLength = size;
        }
        sample.AddBuffer(buffer);
        buffer.Dispose();
        sample.SampleTime = ptsTicks100ns;
        sample.SampleDuration = 10_000_000L / _fps;
        _lastInputPts = ptsTicks100ns;

        if (_async)
        {
            // Offer the frame right away instead of strictly waiting for METransformNeedInput (the NVIDIA MFT keeps the
            // last frame until the next input arrives; a strict credit wait could only add delay). The MFT either takes
            // it or answers MF_E_NOTACCEPTING, the documented "full" answer; only then do we wait for a slot (max 100 ms,
            // then the frame is dropped rather than stalling capture).
            long w0 = System.Diagnostics.Stopwatch.GetTimestamp();
            int slot = (int)((ptsTicks100ns / 10000) & 63);
            _inputTicks[slot] = w0;
            _inputTag[slot] = NextFrameTag;
            _needInput.Wait(0); // consume a pending credit if there is one (keeps the count bounded)
            int hr = ProcessInputRaw(sample);
            while (hr == MF_E_NOTACCEPTING)
            {
                long left = 100 - (System.Diagnostics.Stopwatch.GetTimestamp() - w0) * 1000 / System.Diagnostics.Stopwatch.Frequency;
                if (left <= 0 || !_needInput.Wait((int)left)) { Interlocked.Increment(ref _statBusy); _inputTicks[slot] = 0; _log.LogDebug("Encoder busy, frame dropped"); return; }
                _inputTicks[slot] = System.Diagnostics.Stopwatch.GetTimestamp();
                hr = ProcessInputRaw(sample);
            }
            if (hr < 0) throw new COMException("ProcessInput failed", hr);
            Interlocked.Add(ref _statWaitTicks, System.Diagnostics.Stopwatch.GetTimestamp() - w0);
            _lastSubmitTick = System.Diagnostics.Stopwatch.GetTimestamp();
        }
        else
        {
            int hr = ProcessInputRaw(sample);
            if (hr == MF_E_NOTACCEPTING)
            {
                DrainSync();
                hr = ProcessInputRaw(sample);
            }
            if (hr < 0) throw new COMException("ProcessInput failed", hr);
            DrainSync();
        }
    }

    private void DrainSync()
    {
        while (!_disposed)
        {
            if (!PullOneOutput()) break;
        }
    }

    /// Calls ProcessOutput once. Returns false when the MFT needs more input.
    private bool PullOneOutput()
    {
        lock (_outLock)
        {
            IMFSample? own = null;
            var odb = new MFT_OUTPUT_DATA_BUFFER { dwStreamID = 0 };
            if (!_providesSamples)
            {
                own = MediaFactory.MFCreateSample();
                using var b = MediaFactory.MFCreateMemoryBuffer(_outBufSize);
                own.AddBuffer(b);
                odb.pSample = own.NativePointer;
            }
            try
            {
                int hr = ProcessOutputRaw(ref odb);
                if (odb.pEvents != IntPtr.Zero) Marshal.Release(odb.pEvents);
                if (hr == MF_E_TRANSFORM_NEED_MORE_INPUT) return false;
                if (hr == MF_E_TRANSFORM_STREAM_CHANGE)
                {
                    using var t = _mft.GetOutputAvailableType(0, 0);
                    _mft.SetOutputType(0, t, 0);
                    _paramSets = null; _checkedSeqHeader = false;
                    return true;
                }
                if (hr < 0) throw new COMException("ProcessOutput failed", hr);

                if (_providesSamples)
                {
                    if (odb.pSample == IntPtr.Zero) return true;
                    using var s = new IMFSample(odb.pSample); // we own the returned reference
                    HandleSample(s);
                }
                else HandleSample(own!);
                return true;
            }
            finally { own?.Dispose(); }
        }
    }

    private void HandleSample(IMFSample s)
    {
        byte[] data;
        using (var buf = s.ConvertToContiguousBuffer())
        {
            buf.Lock(out var p, out _, out var len);
            try { data = new ReadOnlySpan<byte>((void*)p, len).ToArray(); }
            finally { buf.Unlock(); }
        }
        long pts;
        try { pts = s.SampleTime; } catch { pts = _lastInputPts; }
        if (data.Length == 0 || _disposed) return; // output drained during teardown is dropped
        int slot = (int)((pts / 10000) & 63);
        long tin = _inputTicks[slot];
        if (tin != 0)
        {
            // latency statistics cover real content frames only (repeats / keep-alives are identical images)
            long lat = System.Diagnostics.Stopwatch.GetTimestamp() - tin;
            char tag = _inputTag[slot];
            Interlocked.Increment(ref _statOut);
            if (tag == 'R')
            {
                Interlocked.Add(ref _statLatTicks, lat);
                Interlocked.Increment(ref _statRealN);
                if (lat > Interlocked.Read(ref _statLatMax)) Interlocked.Exchange(ref _statLatMax, lat);
            }
            if (EvLogOn)
                _log.LogDebug("frame {Tag} pts {Pts} ms latency {Lat:F1} ms", tag, pts / 10000, lat * 1000.0 / System.Diagnostics.Stopwatch.Frequency);
        }

        if (!_checkedSeqHeader)
        {
            _checkedSeqHeader = true;
            try
            {
                using var t = _mft.GetOutputCurrentType(0);
                var blob = t.GetBlob(MediaTypeAttributeKeys.MpegSequenceHeader);
                if (blob is { Length: > 0 }) _paramSets ??= ExtractParamSets(blob, out _);
            }
            catch { /* not provided */ }
        }
        EmitAnnexB(data, pts / 10);
    }

    private void EmitAnnexB(byte[] data, long ptsMicros)
    {
        var nals = AnnexB.Split(data);
        bool idr = false, hasParams = false;
        foreach (var n in nals)
        {
            if (n.Type == 5) idr = true;
            if (n.Type is 7 or 8) hasParams = true;
            if (n.Type is 1 or 5 && !_loggedSlice) { int st = SliceType(data, n); if (st == 1) { _loggedSlice = true; _log.LogWarning("Encoder emits B-slices (adds reorder latency)"); } }
        }
        if (hasParams) _paramSets = ExtractParamSets(data, out _);

        if (idr)
        {
            if (_framesSinceForce >= 0) _framesSinceForce = -1;
            if (_paramSets != null) _output(ptsMicros, Protocol.VideoFlags.CodecConfig, _paramSets);
            if (hasParams)
            {
                // Remove SPS/PPS from the IDR access unit (they were sent as codec-config just before).
                using var ms = new MemoryStream(data.Length);
                foreach (var n in nals) if (n.Type is not (7 or 8)) ms.Write(data, n.Offset, n.Length);
                _output(ptsMicros, Protocol.VideoFlags.Keyframe, ms.GetBuffer().AsSpan(0, (int)ms.Length));
            }
            else _output(ptsMicros, Protocol.VideoFlags.Keyframe, data);
        }
        else
        {
            if (_framesSinceForce >= 0 && ++_framesSinceForce > 3 && _forceSupported)
            {
                // Encoder ignored the force request for a few frames; ask again.
                SetCodecValue(CODECAPI_AVEncVideoForceKeyFrame, VT_UI4, 1);
                _framesSinceForce = 0;
            }
            if (hasParams && nals.All(n => n.Type is 7 or 8)) return; // param-set-only output, already cached
            _output(ptsMicros, 0, data);
        }
    }

    private static byte[]? ExtractParamSets(byte[] data, out int count)
    {
        count = 0;
        using var ms = new MemoryStream();
        foreach (var n in AnnexB.Split(data))
        {
            if (n.Type is 7 or 8)
            {
                ms.Write(data, n.Offset, n.Length);
                count++;
            }
        }
        return count >= 2 ? ms.ToArray() : null;
    }

    private long _lastSubmitTick;
    private static readonly bool EvLogOn = Environment.GetEnvironmentVariable("PLEXI_LATLOG") != null;
    private void EvLog(string what)
    {
        if (!EvLogOn) return;
        _log.LogDebug("mft {What} +{Ms:F1} ms after last input", what, (System.Diagnostics.Stopwatch.GetTimestamp() - _lastSubmitTick) * 1000.0 / System.Diagnostics.Stopwatch.Frequency);
    }

    private void EventLoop()
    {
        try { EventLoopCore(); }
        finally
        {
            _drained.Set();
            if (_eventThreadOwnsRelease) ReleaseLater();
        }
    }

    private void EventLoopCore()
    {
        while (!_stopEvents)
        {
            IMFMediaEvent ev;
            try { ev = _events!.GetEvent(0); }
            catch (Exception ex)
            {
                if (!_disposed) { _log.LogWarning("MFT event loop ended: {Msg}", ex.Message); Error?.Invoke(ex.Message); }
                return;
            }
            using (ev)
            {
                try
                {
                    switch (ev.EventType)
                    {
                        case MediaEventTypes.TransformNeedInput: _needInput.Release(); EvLog("NeedInput"); break;
                        case MediaEventTypes.TransformHaveOutput: EvLog("HaveOutput"); PullOneOutput(); break;
                        case MediaEventTypes.TransformDrainComplete: EvLog("DrainComplete"); _drained.Set(); break;
                        default: EvLog("event " + ev.EventType); break;
                    }
                }
                catch (Exception ex)
                {
                    if (!_disposed) { _log.LogWarning("Async encoder output failed: {Msg}", ex.Message); Error?.Invoke(ex.Message); }
                    return;
                }
            }
        }
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        if (_async)
        {
            // Documented async MFT teardown: flush, end of stream, drain, and keep answering HaveOutput until
            // METransformDrainComplete, so the MFT has no frame in flight when it is shut down.
            try { _mft.ProcessMessage(TMessageType.MessageCommandFlush, UIntPtr.Zero); } catch { }
            try { _mft.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero); } catch { }
            try
            {
                _mft.ProcessMessage(TMessageType.MessageCommandDrain, UIntPtr.Zero);
                if (!_drained.Wait(1000)) _log.LogDebug("{Name}: no DrainComplete within 1 s", Name);
            }
            catch { }
            try { _mft.ProcessMessage(TMessageType.MessageNotifyEndStreaming, UIntPtr.Zero); } catch { }
            _stopEvents = true;
            // IMFShutdown::Shutdown unblocks GetEvent in the event thread.
            Marshal.QueryInterface(_mft.NativePointer, in IID_IMFShutdown, out var shut);
            if (shut != IntPtr.Zero)
            {
                var fn = (delegate* unmanaged[Stdcall]<IntPtr, int>)(*(void***)shut)[3];
                fn(shut);
                Marshal.Release(shut);
            }
            // Never free the MFT under a live event thread (it may be inside GetEvent / ProcessOutput or the output
            // callback): that was a native access violation in ntdll after sessions ended and after warm-up.
            if (_eventThread != null && !_eventThread.Join(5000))
            {
                _eventThreadOwnsRelease = true;
                if (_eventThread.IsAlive)
                {
                    _log.LogWarning("MFT event thread still busy after 5 s; it releases the encoder when it ends");
                    return;
                }
            }
            ReleaseLater();
            return;
        }
        try { _mft.ProcessMessage(TMessageType.MessageNotifyEndOfStream, UIntPtr.Zero); } catch { }
        try { _mft.ProcessMessage(TMessageType.MessageNotifyEndStreaming, UIntPtr.Zero); } catch { }
        ReleaseNative();
    }

    /// Frees the async MFT only after ReleaseDelay, so work items the MFT queued internally before Shutdown finish
    /// against a live object. Encoders are created per session, so this keeps at most a few idle MFTs around briefly.
    private void ReleaseLater()
    {
        if (Volatile.Read(ref _released) != 0) return;
        _ = Task.Delay(ReleaseDelay).ContinueWith(_ =>
        {
            try { ReleaseNative(); }
            catch (Exception ex) { _log.LogDebug("Encoder release: {Msg}", ex.Message); }
        }, TaskScheduler.Default);
    }

    private void ReleaseNative()
    {
        if (Interlocked.Exchange(ref _released, 1) != 0) return;
        lock (_outLock)
        {
            try { _events?.Dispose(); } catch { }
            if (_codecApi != IntPtr.Zero) Marshal.Release(_codecApi);
            try { _activate?.ShutdownObject(); } catch { } // documented teardown for activated (hardware) MFTs
            _mft.Dispose();
            _activate?.Dispose();
            _devMgr?.Dispose();
            _staging?.Dispose();
        }
    }
}

internal static class AnnexB
{
    public readonly record struct Nal(int Offset, int Length, int Type); // Offset/Length include the start code

    public static List<Nal> Split(ReadOnlySpan<byte> d)
    {
        var starts = new List<(int pos, int scLen)>();
        for (int i = 0; i + 3 <= d.Length; i++)
        {
            if (d[i] == 0 && d[i + 1] == 0)
            {
                if (d[i + 2] == 1) { starts.Add((i, 3)); i += 2; }
                else if (i + 4 <= d.Length && d[i + 2] == 0 && d[i + 3] == 1) { starts.Add((i, 4)); i += 3; }
            }
        }
        var list = new List<Nal>(starts.Count);
        for (int k = 0; k < starts.Count; k++)
        {
            int begin = starts[k].pos;
            int end = k + 1 < starts.Count ? starts[k + 1].pos : d.Length;
            int hdr = begin + starts[k].scLen;
            int type = hdr < d.Length ? d[hdr] & 0x1F : 0;
            list.Add(new Nal(begin, end - begin, type));
        }
        return list;
    }
}
