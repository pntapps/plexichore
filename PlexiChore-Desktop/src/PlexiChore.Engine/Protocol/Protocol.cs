using System.Buffers.Binary;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.Json.Serialization;

namespace PlexiChore.Engine.Protocol;

/// Message types of PlexiChore protocol v1 (see PROTOCOL.md).
public enum MessageType : byte
{
    Hello = 0x01,
    Config = 0x02,
    Video = 0x03,
    Input = 0x04,
    Key = 0x05,
    Ping = 0x06,
    Pong = 0x07,
    RequestKeyframe = 0x08,
    Settings = 0x09,
    Bye = 0x0A,
    Stats = 0x0B,
    Pairing = 0x0C,
}

public static class VideoFlags
{
    public const byte Keyframe = 0x01;
    public const byte CodecConfig = 0x02;
}

public static class Wire
{
    public const int HeaderSize = 5;
    public const int MaxPayload = 16 * 1024 * 1024;

    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        PropertyNameCaseInsensitive = true,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        NumberHandling = JsonNumberHandling.AllowReadingFromString,
    };

    public static byte[] Frame(MessageType type, ReadOnlySpan<byte> payload)
    {
        var buf = new byte[HeaderSize + payload.Length];
        buf[0] = (byte)type;
        BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(1), (uint)payload.Length);
        payload.CopyTo(buf.AsSpan(HeaderSize));
        return buf;
    }

    public static byte[] FrameJson<T>(MessageType type, T value) =>
        Frame(type, JsonSerializer.SerializeToUtf8Bytes(value, Json));

    public static byte[] FrameText(MessageType type, string text) => Frame(type, Encoding.UTF8.GetBytes(text));

    /// Builds a complete VIDEO message: header | u64 pts | u8 flags | data.
    public static byte[] VideoFrame(long ptsMicros, byte flags, ReadOnlySpan<byte> data)
    {
        var buf = new byte[HeaderSize + 9 + data.Length];
        buf[0] = (byte)MessageType.Video;
        BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(1), (uint)(9 + data.Length));
        BinaryPrimitives.WriteUInt64BigEndian(buf.AsSpan(5), (ulong)ptsMicros);
        buf[13] = flags;
        data.CopyTo(buf.AsSpan(14));
        return buf;
    }

    public static byte[] VideoFrame(long ptsMicros, byte flags, ReadOnlySpan<byte> a, ReadOnlySpan<byte> b)
    {
        var buf = new byte[HeaderSize + 9 + a.Length + b.Length];
        buf[0] = (byte)MessageType.Video;
        BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(1), (uint)(9 + a.Length + b.Length));
        BinaryPrimitives.WriteUInt64BigEndian(buf.AsSpan(5), (ulong)ptsMicros);
        buf[13] = flags;
        a.CopyTo(buf.AsSpan(14));
        b.CopyTo(buf.AsSpan(14 + a.Length));
        return buf;
    }

    /// Reads one framed message. Returns null on clean EOF.
    public static async Task<(MessageType Type, byte[] Payload)?> ReadAsync(Stream s, CancellationToken ct)
    {
        var header = new byte[HeaderSize];
        int got = 0;
        while (got < HeaderSize)
        {
            int n = await s.ReadAsync(header.AsMemory(got), ct).ConfigureAwait(false);
            if (n == 0) return got == 0 ? null : throw new EndOfStreamException();
            got += n;
        }
        uint len = BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(1));
        if (len > MaxPayload) throw new InvalidDataException($"payload too large: {len}");
        var payload = len == 0 ? Array.Empty<byte>() : new byte[len];
        if (len > 0) await s.ReadExactlyAsync(payload, ct).ConfigureAwait(false);
        return ((MessageType)header[0], payload);
    }
}

// ---------------- JSON messages ----------------

public sealed class RequestedSettings
{
    public string Mode { get; set; } = "mirror";
    public int MonitorIndex { get; set; }
    public double ResolutionScale { get; set; } = 1.0;
    public int Fps { get; set; } = 60;
    public int BitrateKbps { get; set; } = 20000;
    public string Quality { get; set; } = "balanced";
    public string Codec { get; set; } = "h264";
    public string TouchMode { get; set; } = "touch";
    public string Position { get; set; } = "right";
    /// Additive: Windows display scale for the virtual monitor (extend/primary). 0 = auto, else 100..300 (see DisplayScale).
    public int ScalePercent { get; set; }
    /// Additive: how the tablet is held, "landscape" (default) or "portrait". Extend/primary build the virtual monitor
    /// in that orientation (when the display driver has such a mode). Mirror ignores it.
    public string Orientation { get; set; } = "landscape";

    public RequestedSettings Clone() => (RequestedSettings)MemberwiseClone();

    /// Applies a partial JSON object (SETTINGS message) on top of this instance, returning a new instance.
    public RequestedSettings Merge(byte[] partialJson)
    {
        var baseNode = JsonSerializer.SerializeToNode(this, Wire.Json)!.AsObject();
        var partial = JsonNode.Parse(partialJson)?.AsObject();
        if (partial != null)
        {
            // case-insensitive key match
            foreach (var kv in partial)
            {
                var key = baseNode.Select(p => p.Key).FirstOrDefault(k => string.Equals(k, kv.Key, StringComparison.OrdinalIgnoreCase)) ?? kv.Key;
                baseNode[key] = kv.Value?.DeepClone();
            }
        }
        return baseNode.Deserialize<RequestedSettings>(Wire.Json) ?? Clone();
    }

    public void Sanitize()
    {
        Mode = Mode?.Trim().ToLowerInvariant() switch { "extend" => "extend", "primary" => "primary", _ => "mirror" };
        ResolutionScale = double.IsFinite(ResolutionScale) ? Math.Clamp(ResolutionScale, 0.25, 1.0) : 1.0;
        Fps = Fps <= 0 ? 60 : Math.Clamp(Fps, 5, 120);
        BitrateKbps = BitrateKbps <= 0 ? 20000 : Math.Clamp(BitrateKbps, 500, 200_000);
        Codec = string.Equals(Codec, "mjpeg", StringComparison.OrdinalIgnoreCase) ? "mjpeg" : "h264";
        TouchMode = TouchMode?.ToLowerInvariant() switch { "mouse" => "mouse", "none" => "none", _ => "touch" };
        Position = Position?.ToLowerInvariant() switch { "left" => "left", "top" => "top", "bottom" => "bottom", _ => "right" };
        Quality ??= "balanced";
        if (MonitorIndex < 0) MonitorIndex = 0;
        ScalePercent = DisplayScale.SanitizeRequest(ScalePercent);
        Orientation = string.Equals(Orientation?.Trim(), "portrait", StringComparison.OrdinalIgnoreCase) ? "portrait" : "landscape";
    }
}

public sealed class HelloMessage
{
    public int Protocol { get; set; } = 1;
    public string DeviceId { get; set; } = "";
    public string DeviceName { get; set; } = "Tablet";
    public string Model { get; set; } = "";
    public int WidthPx { get; set; } = 1920;
    public int HeightPx { get; set; } = 1080;
    public int DensityDpi { get; set; }
    public int RefreshHz { get; set; } = 60;
    public List<string> Codecs { get; set; } = new() { "h264", "mjpeg" };
    public int MaxDecodeWidth { get; set; } = 3840;
    public int MaxDecodeHeight { get; set; } = 2160;
    public bool Touch { get; set; } = true;
    public bool Pen { get; set; }
    /// Additive decode capabilities (tablets that send them): sizes the decoder handles (landscape) with their max fps.
    /// The host never exceeds them. Older tablets only send MaxDecodeWidth/Height.
    public List<DecodeModeDto>? DecodeModes { get; set; }
    /// Additive: H.264 profiles the decoder supports, best first ("high", "main", "baseline").
    public List<string>? H264Profiles { get; set; }
    /// Additive: highest H.264 level, e.g. "5.1".
    public string? H264MaxLevel { get; set; }
    /// Additive: orientation at connect time ("landscape" / "portrait") and the display window size.
    public string? Orientation { get; set; }
    public int ViewportWidthPx { get; set; }
    public int ViewportHeightPx { get; set; }
    public RequestedSettings Requested { get; set; } = new();
}

public sealed class DecodeModeDto
{
    public int Width { get; set; }
    public int Height { get; set; }
    public int MaxFps { get; set; }
}

public sealed class MonitorInfoDto
{
    public int Index { get; set; }
    public string Name { get; set; } = "";
    public int Width { get; set; }
    public int Height { get; set; }
}

public sealed class ConfigMessage
{
    public string Codec { get; set; } = "h264";
    public int Width { get; set; }
    public int Height { get; set; }
    public int Fps { get; set; }
    public int BitrateKbps { get; set; }
    public string Mode { get; set; } = "mirror";
    public string HostName { get; set; } = "";
    public string HostOs { get; set; } = "windows";
    public List<MonitorInfoDto> Monitors { get; set; } = new();
    public bool VirtualDisplayAvailable { get; set; }
    /// Additive (not in PROTOCOL v1 table, ignored by tablets that don't know it): encoder in use, e.g. "hw:NVIDIA H.264 Encoder MFT".
    public string? Encoder { get; set; }
    /// Additive: Windows display scale applied to the virtual monitor (percent); 0 = not applicable (mirror) / unknown.
    public int ScalePercent { get; set; }
    /// Additive: physical path of this session as the host sees it: "usb-cable", "usb-wireless-adb" (adb reverse over
    /// wireless debugging) or "wifi"; omitted when unknown.
    public string? Link { get; set; }
}

public sealed class PairingMessage
{
    public string Status { get; set; } = "waiting";
    public string? Code { get; set; }
}

public sealed class StatsMessage
{
    public double CaptureFps { get; set; }
    public double EncodeMs { get; set; }
    public int BitrateKbps { get; set; }
}

public sealed class KeyMessage
{
    public string Action { get; set; } = "down";
    public int KeyCode { get; set; }
    public string? Text { get; set; }
}

/// One pointer from an INPUT message.
public struct PointerSample
{
    public byte Kind;      // 0 touch 1 pen 2 mouse 3 scroll
    public byte Action;    // 0 down 1 move 2 up 3 cancel 4 hover-move 5 hover-exit
    public byte PointerId;
    public byte Buttons;   // bit0 primary, bit1 secondary/barrel, bit2 eraser
    public float X, Y, Pressure, TiltX, TiltY;

    public const int Size = 4 + 5 * 4;

    public static PointerSample[] Parse(ReadOnlySpan<byte> p)
    {
        if (p.Length < 1) return Array.Empty<PointerSample>();
        int count = Math.Min(p[0], (p.Length - 1) / Size);
        var arr = new PointerSample[count];
        for (int i = 0; i < count; i++)
        {
            var s = p.Slice(1 + i * Size, Size);
            arr[i] = new PointerSample
            {
                Kind = s[0], Action = s[1], PointerId = s[2], Buttons = s[3],
                X = BinaryPrimitives.ReadSingleBigEndian(s.Slice(4)),
                Y = BinaryPrimitives.ReadSingleBigEndian(s.Slice(8)),
                Pressure = BinaryPrimitives.ReadSingleBigEndian(s.Slice(12)),
                TiltX = BinaryPrimitives.ReadSingleBigEndian(s.Slice(16)),
                TiltY = BinaryPrimitives.ReadSingleBigEndian(s.Slice(20)),
            };
        }
        return arr;
    }
}
