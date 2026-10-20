// FakeHost: minimal PlexiChore protocol v1 host for testing the Android client.
//
//   dotnet run -- [--codec mjpeg|h264] [--h264 file.h264] [--size 1280x800] [--fps 30] [--pair]
//                 [--beacon] [--bye-after 0]
//
// Listens on TCP 47800, answers HELLO with CONFIG, streams an animated MJPEG test pattern (frame
// counter + markers at the last INPUT positions) or replays a raw Annex-B H.264 file, logs INPUT.
// --pair: sends PAIRING waiting/approved (2 s) before CONFIG. --beacon: UDP beacons on 47801.

using System.Buffers.Binary;
using System.Diagnostics;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

static class FakeHost
{
    static string codec = "mjpeg";
    static string? h264Path;
    static int width = 1280, height = 800, fps = 30;
    static bool pair, beacon;
    static int byeAfter;
    static readonly string HostId = "fakehost-" + Environment.MachineName.ToLowerInvariant();

    static async Task Main(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--codec": codec = args[++i]; break;
                case "--h264": h264Path = args[++i]; codec = "h264"; break;
                case "--size":
                    var p = args[++i].Split('x'); width = int.Parse(p[0]); height = int.Parse(p[1]); break;
                case "--fps": fps = int.Parse(args[++i]); break;
                case "--pair": pair = true; break;
                case "--beacon": beacon = true; break;
                case "--bye-after": byeAfter = int.Parse(args[++i]); break;
            }
        }
        if (codec == "h264" && h264Path == null) { Console.Error.WriteLine("--codec h264 needs --h264 <file>"); return; }

        var listener = new TcpListener(IPAddress.Any, 47800);
        listener.Server.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        listener.Start();
        Log($"Listening on :47800 codec={codec} {width}x{height}@{fps} pair={pair}");
        if (beacon) _ = Task.Run(BeaconLoop);
        while (true)
        {
            var client = await listener.AcceptTcpClientAsync();
            _ = Task.Run(() => HandleClient(client));
        }
    }

    static void Log(string s) => Console.WriteLine($"{DateTime.Now:HH:mm:ss.fff} {s}");

    static async Task BeaconLoop()
    {
        using var udp = new UdpClient();
        udp.EnableBroadcast = true;
        udp.Client.SetSocketOption(SocketOptionLevel.Socket, SocketOptionName.ReuseAddress, true);
        var payload = Encoding.UTF8.GetBytes(JsonSerializer.Serialize(new
        {
            svc = "plexichore", v = 1, id = HostId, name = Environment.MachineName + " (fake)",
            os = "windows", port = 47800, virtualDisplay = false,
        }));
        while (true)
        {
            try { await udp.SendAsync(payload, payload.Length, new IPEndPoint(IPAddress.Broadcast, 47801)); }
            catch (Exception e) { Log("beacon: " + e.Message); }
            await Task.Delay(1000);
        }
    }

    sealed class Conn
    {
        public required NetworkStream Stream;
        public readonly object WriteLock = new();
        public volatile bool Closed;
        public volatile bool KeyframeRequested = true;
        public volatile string Codec = codec;
        public readonly List<(float x, float y, int kind, int action)> Pointers = new();
        public long InputCount;

        public void Send(byte type, ReadOnlySpan<byte> payload)
        {
            Span<byte> hdr = stackalloc byte[5];
            hdr[0] = type;
            BinaryPrimitives.WriteUInt32BigEndian(hdr[1..], (uint)payload.Length);
            lock (WriteLock)
            {
                Stream.Write(hdr);
                Stream.Write(payload);
            }
        }

        public void SendJson(byte type, object o) => Send(type, Encoding.UTF8.GetBytes(JsonSerializer.Serialize(o)));
    }

    static byte[] ReadExact(NetworkStream s, int n)
    {
        var b = new byte[n];
        int off = 0;
        while (off < n)
        {
            int r = s.Read(b, off, n - off);
            if (r <= 0) throw new EndOfStreamException();
            off += r;
        }
        return b;
    }

    static void HandleClient(TcpClient client)
    {
        var remote = client.Client.RemoteEndPoint;
        client.NoDelay = true;
        var stream = client.GetStream();
        var conn = new Conn { Stream = stream };
        try
        {
            // First message must be HELLO; connect-and-close probes end here quietly.
            byte[] hdr;
            try { hdr = ReadExact(stream, 5); }
            catch (Exception) { Log($"probe from {remote} (closed without HELLO)"); return; }
            int len = (int)BinaryPrimitives.ReadUInt32BigEndian(hdr.AsSpan(1));
            var hello = Encoding.UTF8.GetString(ReadExact(stream, len));
            if (hdr[0] != 0x01) { Log($"expected HELLO, got 0x{hdr[0]:X2}"); return; }
            Log($"HELLO from {remote}: {hello}");
            var req = JsonNode.Parse(hello)?["requested"];
            var reqCodec = req?["codec"]?.GetValue<string>();
            if (h264Path == null) conn.Codec = "mjpeg";
            else if (reqCodec == "mjpeg") conn.Codec = "mjpeg";

            var reader = new Thread(() => ReadLoop(conn)) { IsBackground = true };
            reader.Start();

            if (pair)
            {
                conn.SendJson(0x0C, new { status = "waiting", code = "4821" });
                Log("PAIRING waiting 4821");
                Thread.Sleep(2500);
                conn.SendJson(0x0C, new { status = "approved", code = "4821" });
                Log("PAIRING approved");
            }
            SendConfig(conn);

            var pinger = new Thread(() =>
            {
                while (!conn.Closed)
                {
                    var b = new byte[8];
                    BinaryPrimitives.WriteInt64BigEndian(b, Stopwatch.GetTimestamp() * 1_000_000 / Stopwatch.Frequency);
                    try { conn.Send(0x06, b); } catch { break; }
                    Thread.Sleep(1000);
                }
            }) { IsBackground = true };
            pinger.Start();

            StreamLoop(conn);
        }
        catch (Exception e)
        {
            Log($"client {remote} ended: {e.GetType().Name} {e.Message}");
        }
        finally
        {
            conn.Closed = true;
            client.Close();
            Log($"client {remote} closed, inputs received: {conn.InputCount}");
        }
    }

    static void SendConfig(Conn conn)
    {
        var (w, h) = (width, height); // for --h264, pass --size matching the file
        conn.SendJson(0x02, new
        {
            codec = conn.Codec, width = w, height = h, fps, bitrateKbps = 8000, mode = "mirror",
            hostName = Environment.MachineName + " (fake)", hostOs = "windows",
            monitors = new[] { new { index = 0, name = "Primary", width = 1920, height = 1080 } },
            virtualDisplayAvailable = false,
        });
        conn.KeyframeRequested = true;
        Log($"CONFIG {conn.Codec} {w}x{h}");
    }

    static void ReadLoop(Conn conn)
    {
        try
        {
            while (!conn.Closed)
            {
                var hdr = ReadExact(conn.Stream, 5);
                int len = (int)BinaryPrimitives.ReadUInt32BigEndian(hdr.AsSpan(1));
                var p = len > 0 ? ReadExact(conn.Stream, len) : Array.Empty<byte>();
                switch (hdr[0])
                {
                    case 0x04: LogInput(conn, p); break;
                    case 0x06: conn.Send(0x07, p); break;
                    case 0x07:
                        break;
                    case 0x08: conn.KeyframeRequested = true; Log("REQUEST_KEYFRAME"); break;
                    case 0x09:
                        var s = Encoding.UTF8.GetString(p);
                        Log("SETTINGS " + s);
                        var c = JsonNode.Parse(s)?["codec"]?.GetValue<string>();
                        if (c != null && (c == "mjpeg" || h264Path != null) && c != conn.Codec) { conn.Codec = c; }
                        SendConfig(conn);
                        break;
                    case 0x0A: Log("BYE " + Encoding.UTF8.GetString(p)); conn.Closed = true; conn.Stream.Close(); return;
                    default: Log($"msg 0x{hdr[0]:X2} len {len}"); break;
                }
            }
        }
        catch (Exception e) when (!conn.Closed)
        {
            Log("reader: " + e.Message);
            conn.Closed = true;
        }
        catch { }
    }

    static readonly string[] Kinds = { "touch", "pen", "mouse", "scroll" };
    static readonly string[] Actions = { "down", "move", "up", "cancel", "hover", "hover-exit" };

    static void LogInput(Conn conn, byte[] p)
    {
        int count = p[0];
        var sb = new StringBuilder($"INPUT n={count}");
        lock (conn.Pointers)
        {
            conn.Pointers.Clear();
            for (int i = 0; i < count; i++)
            {
                var o = 1 + i * 24;
                int kind = p[o], action = p[o + 1], id = p[o + 2], buttons = p[o + 3];
                float x = BinaryPrimitives.ReadSingleBigEndian(p.AsSpan(o + 4));
                float y = BinaryPrimitives.ReadSingleBigEndian(p.AsSpan(o + 8));
                float pr = BinaryPrimitives.ReadSingleBigEndian(p.AsSpan(o + 12));
                float tx = BinaryPrimitives.ReadSingleBigEndian(p.AsSpan(o + 16));
                float ty = BinaryPrimitives.ReadSingleBigEndian(p.AsSpan(o + 20));
                sb.Append($" [{Kinds[Math.Min(kind, 3)]} {Actions[Math.Min(action, 5)]} id={id} btn={buttons} x={x:F3} y={y:F3} p={pr:F2} tilt={tx:F0},{ty:F0}]");
                if (action != 2 && action != 3 && action != 5) conn.Pointers.Add((x, y, kind, action));
            }
        }
        long n = Interlocked.Increment(ref conn.InputCount);
        // Log every non-move event and every 10th move to keep the console readable.
        bool isMove = sb.ToString().Contains(" move ") && !sb.ToString().Contains(" down ") && !sb.ToString().Contains(" up ");
        if (!isMove || n % 10 == 0) Log(sb.ToString());
    }

    static void StreamLoop(Conn conn)
    {
        var sw = Stopwatch.StartNew();
        long frame = 0;
        var interval = TimeSpan.FromSeconds(1.0 / fps);
        List<(byte[] data, byte flags)>? aus = null;
        int auIndex = 0;
        Bitmap? bmp = null;
        var jpegCodec = ImageCodecInfo.GetImageEncoders().First(e => e.FormatID == ImageFormat.Jpeg.Guid);
        var encParams = new EncoderParameters(1) { Param = { [0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 80L) } };
        string activeCodec = "";
        while (!conn.Closed)
        {
            var due = interval * frame;
            var wait = due - sw.Elapsed;
            if (wait > TimeSpan.Zero) Thread.Sleep(wait);
            long pts = (long)(sw.Elapsed.TotalMilliseconds * 1000);
            if (activeCodec != conn.Codec)
            {
                activeCodec = conn.Codec;
                if (activeCodec == "h264") { aus ??= LoadAccessUnits(h264Path!); auIndex = 0; }
                else { bmp?.Dispose(); bmp = new Bitmap(width, height, PixelFormat.Format24bppRgb); }
            }
            if (activeCodec == "h264")
            {
                if (conn.KeyframeRequested) { conn.KeyframeRequested = false; auIndex = 0; }
                // Send codec-config units together with the following frame.
                while (true)
                {
                    var (data, flags) = aus![auIndex];
                    auIndex = (auIndex + 1) % aus.Count;
                    SendVideo(conn, pts, flags, data);
                    if ((flags & 2) == 0) break;
                }
            }
            else
            {
                Draw(bmp!, frame, conn);
                using var ms = new MemoryStream();
                bmp!.Save(ms, jpegCodec, encParams);
                SendVideo(conn, pts, 1, ms.ToArray());
            }
            frame++;
            if (frame % (fps * 5) == 0) Log($"sent {frame} frames ({activeCodec})");
            if (byeAfter > 0 && sw.Elapsed.TotalSeconds > byeAfter)
            {
                conn.Send(0x0A, Encoding.UTF8.GetBytes("test finished"));
                Log("sent BYE");
                Thread.Sleep(200);
                return;
            }
        }
    }

    static void SendVideo(Conn conn, long pts, byte flags, byte[] data)
    {
        var payload = new byte[9 + data.Length];
        BinaryPrimitives.WriteInt64BigEndian(payload, pts);
        payload[8] = flags;
        data.CopyTo(payload, 9);
        conn.Send(0x03, payload);
    }

    static readonly Font Big = new("Consolas", 64, FontStyle.Bold);
    static readonly Font Small = new("Consolas", 20);

    static void Draw(Bitmap bmp, long frame, Conn conn)
    {
        using var g = Graphics.FromImage(bmp);
        g.SmoothingMode = SmoothingMode.AntiAlias;
        int w = bmp.Width, h = bmp.Height;
        using (var bg = new LinearGradientBrush(new Rectangle(0, 0, w, h), Color.FromArgb(20, 30, 70), Color.FromArgb(90, 20, 90), 30f))
            g.FillRectangle(bg, 0, 0, w, h);
        using var grid = new Pen(Color.FromArgb(60, 255, 255, 255));
        for (int x = 0; x <= w; x += w / 16) g.DrawLine(grid, x, 0, x, h);
        for (int y = 0; y <= h; y += h / 10) g.DrawLine(grid, 0, y, w, y);
        g.DrawRectangle(Pens.Yellow, 0, 0, w - 1, h - 1); // frame edge must be visible = no cropping
        int barX = (int)(frame * 8 % w);
        g.FillRectangle(Brushes.Orange, barX, 0, 12, h);
        g.DrawString($"#{frame}", Big, Brushes.White, 40, 40);
        g.DrawString($"{w}x{h} MJPEG  {DateTime.Now:HH:mm:ss.fff}  inputs={Interlocked.Read(ref conn.InputCount)}", Small, Brushes.White, 44, 140);
        lock (conn.Pointers)
        {
            foreach (var (x, y, kind, action) in conn.Pointers)
            {
                var color = kind == 1 ? Color.Lime : kind == 2 ? Color.Cyan : Color.Red;
                using var pen = new Pen(color, 4);
                int r = action == 4 ? 14 : 28;
                g.DrawEllipse(pen, x * w - r, y * h - r, 2 * r, 2 * r);
            }
        }
    }

    // ---- H.264 Annex-B replay --------------------------------------------------------------


    static List<(byte[] data, byte flags)> LoadAccessUnits(string path)
    {
        var bytes = File.ReadAllBytes(path);
        var nals = new List<(int start, int end)>();
        int i = 0, cur = -1;
        while (i + 3 <= bytes.Length)
        {
            int sc = 0;
            if (bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 1) sc = 3;
            else if (i + 4 <= bytes.Length && bytes[i] == 0 && bytes[i + 1] == 0 && bytes[i + 2] == 0 && bytes[i + 3] == 1) sc = 4;
            if (sc > 0)
            {
                if (cur >= 0) nals.Add((cur, i));
                cur = i;
                i += sc;
            }
            else i++;
        }
        if (cur >= 0) nals.Add((cur, bytes.Length));

        var aus = new List<(byte[], byte)>();
        var pending = new MemoryStream();
        var config = new MemoryStream();
        bool pendingKey = false, havePending = false;
        foreach (var (s, e) in nals)
        {
            int hdr = bytes[s + 2] == 1 ? s + 3 : s + 4;
            int type = bytes[hdr] & 0x1F;
            if (type == 7 || type == 8)
            {
                if (havePending) { aus.Add((pending.ToArray(), (byte)(pendingKey ? 1 : 0))); pending.SetLength(0); havePending = false; }
                config.Write(bytes, s, e - s);
                continue;
            }
            if (config.Length > 0) { aus.Add((config.ToArray(), (byte)2)); config.SetLength(0); }
            bool firstSlice = (type == 1 || type == 5) && (bytes[hdr + 1] & 0x80) != 0; // first_mb_in_slice == 0
            if (firstSlice && havePending)
            {
                aus.Add((pending.ToArray(), (byte)(pendingKey ? 1 : 0)));
                pending.SetLength(0);
                pendingKey = false;
            }
            pending.Write(bytes, s, e - s);
            if (type == 1 || type == 5) havePending = true;
            if (type == 5) pendingKey = true;
        }
        if (havePending) aus.Add((pending.ToArray(), (byte)(pendingKey ? 1 : 0)));
        Log($"Loaded {aus.Count} access units from {path} (config units: {aus.Count(a => a.Item2 == 2)}, IDR: {aus.Count(a => a.Item2 == 1)})");
        return aus;
    }
}
