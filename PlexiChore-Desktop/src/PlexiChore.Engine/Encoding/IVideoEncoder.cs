using Vortice.Direct3D11;

namespace PlexiChore.Engine.Codecs;

/// Encoded output callback: pts (µs), protocol VIDEO flags, payload bytes (Annex-B or JPEG).
internal delegate void EncodedOutput(long ptsMicros, byte flags, ReadOnlySpan<byte> data);

internal interface IVideoEncoder : IDisposable
{
    string Codec { get; }          // "h264" | "mjpeg"
    string Name { get; }           // human readable, e.g. "hw:NVIDIA H.264 Encoder MFT"
    bool IsHardware { get; }
    /// Texture format the encoder wants from the VideoConverter (NV12 for H.264, BGRA for MJPEG).
    Vortice.DXGI.Format InputFormat { get; }
    /// How many converter output textures may be in flight (async HW encoders keep references).
    int InputRingSize { get; }
    void Encode(ID3D11Texture2D frame, long ptsTicks100ns, bool forceKeyframe);
}
