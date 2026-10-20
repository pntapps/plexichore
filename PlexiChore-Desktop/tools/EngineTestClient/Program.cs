// PlexiChore protocol test client (acts like the tablet). Independent implementation of PROTOCOL.md framing.
// Usage: EngineTestClient [--host 127.0.0.1] [--port 47800] [--seconds 6] [--codec h264|mjpeg|both]
//                         [--w 2560] [--h 1600] [--fps 60] [--kbps 20000] [--mode mirror|extend]
//                         [--settings] [--input] [--out DIR] [--no-decode]
using System.Buffers.Binary;
using System.Diagnostics;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using EngineTestClient;

string host = "127.0.0.1", codecArg = "both", outDir = Directory.GetCurrentDirectory(), mode = "mirror";
int port = 47800, seconds = 6, w = 2560, h = 1600, fps = 60, kbps = 20000;
bool testSettings = false, testInput = false, decode = true;
for (int i = 0; i < args.Length; i++)
{
    switch (args[i])
    {
        case "--host": host = args[++i]; break;
        case "--port": port = int.Parse(args[++i]); break;
        case "--seconds": seconds = int.Parse(args[++i]); break;
        case "--codec": codecArg = args[++i]; break;
        case "--w": w = int.Parse(args[++i]); break;
        case "--h": h = int.Parse(args[++i]); break;
        case "--fps": fps = int.Parse(args[++i]); break;
        case "--kbps": kbps = int.Parse(args[++i]); break;
        case "--mode": mode = args[++i]; break;
        case "--settings": testSettings = true; break;
        case "--input": testInput = true; break;
        case "--out": outDir = args[++i]; break;
        case "--no-decode": decode = false; break;
        case "--motion": TestSession.Motion = true; break;
        case "--touchmode": TestSession.TouchMode = args[++i]; break;
    }
}
Native.SetProcessDpiAwarenessContext(new IntPtr(-4));
Native.timeBeginPeriod(1);
Directory.CreateDirectory(outDir);

bool allOk = true;
var codecs = codecArg == "both" ? new[] { "h264", "mjpeg" } : new[] { codecArg };
foreach (var c in codecs)
{
    var r = await new TestSession(host, port, c, seconds, w, h, fps, kbps, mode, testSettings, testInput, outDir, decode).RunAsync();
    allOk &= r;
}
Console.WriteLine(allOk ? "\nRESULT: PASS" : "\nRESULT: FAIL");
return allOk ? 0 : 1;

namespace EngineTestClient
{
    internal static class Native
    {
        [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out POINT p);
        [DllImport("winmm.dll")] public static extern uint timeBeginPeriod(uint p);
        [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
    }

    internal sealed class TestSession
    {
        private readonly string _host, _codec, _mode, _outDir;
        private readonly int _port, _seconds, _w, _h, _fps, _kbps;
        private readonly bool _testSettings, _testInput, _decode;
        public static bool Motion;
        public static string TouchMode = "touch";
        private readonly SemaphoreSlim _writeLock = new(1, 1);
        private NetworkStream _s = null!;
        private readonly Stopwatch _clock = Stopwatch.StartNew();

        // results
        private readonly List<JsonObject> _configs = new();
        private readonly Dictionary<int, int> _nalCounts = new();
        private readonly List<byte[]> _units = new();
        private int _frames, _keyframes, _configMsgs, _badFlags, _stats;
        private long _videoBytes;
        private double _firstFrameT = -1, _lastFrameT;
        private double _keyReqT = -1, _keyRespMs = -1;
        private double _rttMs = -1;
        private int _jpegOk, _jpegBad;
        private byte[]? _savedJpeg;
        private string? _bye;
        private (int w, int h)? _spsDims;
        private int _configsAfterSettings;
        private double _settingsT = -1;

        public TestSession(string host, int port, string codec, int seconds, int w, int h, int fps, int kbps, string mode,
            bool settings, bool input, string outDir, bool decode)
        {
            _host = host; _port = port; _codec = codec; _seconds = seconds; _w = w; _h = h; _fps = fps; _kbps = kbps; _mode = mode;
            _testSettings = settings; _testInput = input; _outDir = outDir; _decode = decode;
        }

        private double Now => _clock.Elapsed.TotalSeconds;

        private async Task SendAsync(byte type, byte[] payload)
        {
            var buf = new byte[5 + payload.Length];
            buf[0] = type;
            BinaryPrimitives.WriteUInt32BigEndian(buf.AsSpan(1), (uint)payload.Length);
            payload.CopyTo(buf, 5);
            await _writeLock.WaitAsync();
            try { await _s.WriteAsync(buf); } catch (IOException) { } catch (ObjectDisposedException) { } finally { _writeLock.Release(); }
        }

        private Task SendJson(byte type, object o) => SendAsync(type, JsonSerializer.SerializeToUtf8Bytes(o));

        public async Task<bool> RunAsync()
        {
            Console.WriteLine($"\n=== {_codec.ToUpperInvariant()} session: {_host}:{_port} HELLO {_w}x{_h} {_fps}fps {_kbps}kbps mode={_mode} ===");
            using var tcp = new TcpClient { NoDelay = true };
            await tcp.ConnectAsync(_host, _port);
            _s = tcp.GetStream();

            await SendJson(0x01, new
            {
                protocol = 1, deviceId = "engine-test-client", deviceName = "EngineTestClient", model = "TEST",
                widthPx = _w, heightPx = _h, densityDpi = 274, refreshHz = 120,
                codecs = _codec == "mjpeg" ? new[] { "mjpeg" } : new[] { "h264", "mjpeg" },
                maxDecodeWidth = 3840, maxDecodeHeight = 2160, touch = true, pen = true,
                requested = new
                {
                    mode = _mode, monitorIndex = 0, resolutionScale = 1.0, fps = _fps, bitrateKbps = _kbps,
                    quality = "balanced", codec = _codec, touchMode = TouchMode, position = "right",
                },
            });

            using var cts = new CancellationTokenSource();
            var reader = ReadLoop(cts.Token);
            var start = Now;
            bool keyReqSent = false, settingsSent = false, inputDone = false;
            string inputResult = "skipped";
            using var motionCts = new CancellationTokenSource();
            var motion = Motion ? MotionLoop(motionCts.Token) : Task.CompletedTask;
            while (!reader.IsCompleted && (_firstFrameT < 0 ? Now - start < 300 : Now - _firstFrameT < _seconds))
            {
                await Task.Delay(250);
                var ping = new byte[8];
                BinaryPrimitives.WriteUInt64BigEndian(ping, (ulong)(Now * 1e6));
                await SendAsync(0x06, ping);
                double t = _firstFrameT < 0 ? 0 : Now - _firstFrameT;
                if (!keyReqSent && t > _seconds * 0.4 && _frames > 0)
                {
                    keyReqSent = true; _keyReqT = Now;
                    await SendAsync(0x08, Array.Empty<byte>());
                }
                if (_testSettings && !settingsSent && t > _seconds * 0.6 && _frames > 0)
                {
                    settingsSent = true; _settingsT = Now;
                    await SendJson(0x09, new { fps = 30, bitrateKbps = 8000 });
                    Console.WriteLine("  -> SETTINGS {fps:30, bitrateKbps:8000}");
                }
                if (_testInput && !inputDone && t > 1.0 && _frames > 0)
                {
                    inputDone = true;
                    inputResult = await InputTest();
                }
            }
            motionCts.Cancel(); try { await motion; } catch { }
            await SendAsync(0x0A, Encoding.UTF8.GetBytes("test done"));
            await Task.Delay(200);
            cts.Cancel();
            tcp.Close();
            try { await reader; } catch { }
            return Report(inputResult);
        }

        private async Task MotionLoop(CancellationToken ct)
        {
            // moves the cursor in a small circle (via INPUT mouse hover) so the screen keeps changing at ~60 Hz
            while (_frames == 0 && !ct.IsCancellationRequested) await Task.Delay(50, CancellationToken.None);
            double a = 0;
            while (!ct.IsCancellationRequested)
            {
                a += 0.12;
                await SendAsync(0x04, Pointer(2, 4, 0, 0, 0.5f + 0.1f * (float)Math.Cos(a), 0.5f + 0.1f * (float)Math.Sin(a), 0));
                var due = Stopwatch.GetTimestamp() + Stopwatch.Frequency / 125;
                while (Stopwatch.GetTimestamp() < due && !ct.IsCancellationRequested) Thread.Sleep(1);
            }
        }

        private async Task<string> InputTest()
        {
            var cfg = _configs[0];
            int mw = cfg["monitors"]?[0]?["width"]?.GetValue<int>() ?? 0, mh = cfg["monitors"]?[0]?["height"]?.GetValue<int>() ?? 0;
            Native.GetCursorPos(out var orig);
            // mouse hover-move (no buttons) to 25%/25%
            await SendAsync(0x04, Pointer(2, 4, 0, 0, 0.25f, 0.25f, 0));
            await Task.Delay(150);
            Native.GetCursorPos(out var p1);
            int ex = (int)MathF.Round(0.25f * (mw - 1)), ey = (int)MathF.Round(0.25f * (mh - 1));
            // pen hover at 75%/60% then hover-exit
            await SendAsync(0x04, Pointer(1, 4, 0, 0, 0.75f, 0.60f, 0));
            await Task.Delay(150);
            Native.GetCursorPos(out var p2);
            await SendAsync(0x04, Pointer(1, 5, 0, 0, 0.75f, 0.60f, 0));
            int ex2 = (int)MathF.Round(0.75f * (mw - 1)), ey2 = (int)MathF.Round(0.60f * (mh - 1));
            // restore
            await Task.Delay(100);
            await SendAsync(0x04, Pointer(2, 4, 0, 0, orig.X / (float)Math.Max(1, mw - 1), orig.Y / (float)Math.Max(1, mh - 1), 0));
            bool mouseOk = Math.Abs(p1.X - ex) <= 2 && Math.Abs(p1.Y - ey) <= 2;
            bool penOk = Math.Abs(p2.X - ex2) <= 3 && Math.Abs(p2.Y - ey2) <= 3;
            return $"mouse hover expected ({ex},{ey}) got ({p1.X},{p1.Y}) {(mouseOk ? "OK" : "MISMATCH")}; " +
                   $"pen hover expected ({ex2},{ey2}) got ({p2.X},{p2.Y}) {(penOk ? "OK" : "MISMATCH")}";
        }

        private static byte[] Pointer(byte kind, byte action, byte id, byte buttons, float x, float y, float pressure)
        {
            var b = new byte[1 + 24];
            b[0] = 1; b[1] = kind; b[2] = action; b[3] = id; b[4] = buttons;
            BinaryPrimitives.WriteSingleBigEndian(b.AsSpan(5), x);
            BinaryPrimitives.WriteSingleBigEndian(b.AsSpan(9), y);
            BinaryPrimitives.WriteSingleBigEndian(b.AsSpan(13), pressure);
            return b;
        }

        private async Task ReadLoop(CancellationToken ct)
        {
            var header = new byte[5];
            try
            {
                while (!ct.IsCancellationRequested)
                {
                    await _s.ReadExactlyAsync(header, ct);
                    int len = (int)BinaryPrimitives.ReadUInt32BigEndian(header.AsSpan(1));
                    var p = new byte[len];
                    if (len > 0) await _s.ReadExactlyAsync(p, ct);
                    switch (header[0])
                    {
                        case 0x02:
                            var cfg = JsonNode.Parse(p)!.AsObject();
                            _configs.Add(cfg);
                            if (_settingsT > 0) _configsAfterSettings++;
                            Console.WriteLine($"  <- CONFIG #{_configs.Count}: {Encoding.UTF8.GetString(p)}");
                            break;
                        case 0x03: OnVideo(p); break;
                        case 0x06: await SendAsync(0x07, p); break;
                        case 0x07:
                            if (p.Length == 8) _rttMs = (Now - BinaryPrimitives.ReadUInt64BigEndian(p) / 1e6) * 1000;
                            break;
                        case 0x0B:
                            if (_stats++ % 2 == 0) Console.WriteLine($"  <- STATS {Encoding.UTF8.GetString(p)}");
                            break;
                        case 0x0C: Console.WriteLine($"  <- PAIRING {Encoding.UTF8.GetString(p)}"); break;
                        case 0x0A: _bye = Encoding.UTF8.GetString(p); Console.WriteLine($"  <- BYE {_bye}"); return;
                        default: Console.WriteLine($"  <- type 0x{header[0]:X2} ({len} bytes)"); break;
                    }
                }
            }
            catch (Exception) when (ct.IsCancellationRequested) { }
            catch (EndOfStreamException) { Console.WriteLine("  (connection closed)"); }
            catch (IOException) { Console.WriteLine("  (connection closed)"); }
        }

        private void OnVideo(byte[] p)
        {
            long pts = (long)BinaryPrimitives.ReadUInt64BigEndian(p);
            byte flags = p[8];
            var data = p.AsSpan(9);
            _videoBytes += p.Length + 5;
            bool cfg = (flags & 2) != 0, key = (flags & 1) != 0;
            if (cfg) _configMsgs++;
            else
            {
                _frames++;
                if (_firstFrameT < 0) _firstFrameT = Now;
                _lastFrameT = Now;
                if (key) _keyframes++;
            }

            if (_codec == "h264")
            {
                var types = Nal.Types(data);
                foreach (var t in types) _nalCounts[t] = _nalCounts.GetValueOrDefault(t) + 1;
                if (cfg && types.Any(t => t is not (7 or 8))) _badFlags++;
                if (key && !types.Contains(5)) _badFlags++;
                if (!key && !cfg && types.Contains(5)) _badFlags++;
                if (cfg && _spsDims == null) _spsDims = Nal.ParseSpsDims(data);
                if (key && _keyReqT > 0 && _keyRespMs < 0) _keyRespMs = (Now - _keyReqT) * 1000;
                if (_settingsT < 0) _units.Add(data.ToArray()); // only the first configuration goes to out.h264
            }
            else
            {
                bool ok = data.Length > 4 && data[0] == 0xFF && data[1] == 0xD8 && data[^2] == 0xFF && data[^1] == 0xD9;
                if (ok) _jpegOk++; else _jpegBad++;
                if (ok && (_savedJpeg == null || Now - _firstFrameT < 1.5)) _savedJpeg = data.ToArray();
            }
        }

        private bool Report(string inputResult)
        {
            double dur = Math.Max(0.001, _lastFrameT - _firstFrameT);
            Console.WriteLine($"--- {_codec} results ---");
            if (_configs.Count == 0) { Console.WriteLine("  FAIL: no CONFIG received"); return false; }
            var c0 = _configs[0];
            Console.WriteLine($"  configs={_configs.Count} codec={c0["codec"]} {c0["width"]}x{c0["height"]} mode={c0["mode"]} encoder={c0["encoder"]}");
            Console.WriteLine($"  frames={_frames} keyframes={_keyframes} codec-config msgs={_configMsgs} over {dur:F2}s -> {(_frames - 1) / dur:F1} fps, {_videoBytes * 8 / 1000.0 / Math.Max(dur, 0.001):F0} kbps avg");
            Console.WriteLine($"  RTT={_rttMs:F1} ms, REQUEST_KEYFRAME -> IDR in {(_keyRespMs < 0 ? "n/a" : _keyRespMs.ToString("F0") + " ms")}");
            if (_testInput) Console.WriteLine($"  input: {inputResult}");
            bool ok = _frames > 0 && _configs.Count > 0;
            if (_codec == "h264")
            {
                Console.WriteLine($"  NAL types: {string.Join(", ", _nalCounts.OrderBy(k => k.Key).Select(k => $"{k.Key}({NalName(k.Key)})x{k.Value}"))}");
                Console.WriteLine($"  SPS dims: {(_spsDims is { } d ? $"{d.w}x{d.h}" : "?")}, flag errors: {_badFlags}");
                bool nalOk = _nalCounts.ContainsKey(7) && _nalCounts.ContainsKey(8) && _nalCounts.ContainsKey(5);
                ok &= nalOk && _badFlags == 0;
                var path = Path.Combine(_outDir, "out.h264");
                using (var f = File.Create(path)) foreach (var u in _units) f.Write(u);
                Console.WriteLine($"  wrote {path} ({new FileInfo(path).Length} bytes); SPS/PPS/IDR present: {nalOk}");
                if (_decode)
                {
                    try
                    {
                        int cw = c0["width"]!.GetValue<int>(), ch = c0["height"]!.GetValue<int>();
                        var jpg = Path.Combine(_outDir, "h264_decoded.jpg");
                        var (decoded, errs) = H264Verify.DecodeToJpeg(_units, cw, ch, jpg);
                        Console.WriteLine($"  MF decoder: {decoded} frames decoded, {errs} errors; last frame -> {jpg}");
                        ok &= decoded > 0;
                    }
                    catch (Exception ex) { Console.WriteLine($"  MF decode failed: {ex.Message}"); ok = false; }
                }
            }
            else
            {
                Console.WriteLine($"  JPEG frames valid={_jpegOk} invalid={_jpegBad}");
                ok &= _jpegOk > 0 && _jpegBad == 0;
                if (_savedJpeg != null)
                {
                    var path = Path.Combine(_outDir, "frame.jpg");
                    File.WriteAllBytes(path, _savedJpeg);
                    Console.WriteLine($"  wrote {path} ({_savedJpeg.Length} bytes)");
                }
            }
            if (_testSettings)
            {
                bool sOk = _configsAfterSettings >= 1 && _configs[^1]["fps"]?.GetValue<int>() == 30;
                Console.WriteLine($"  SETTINGS -> new CONFIG: {(sOk ? "OK" : "MISSING")} ({_configs[^1].ToJsonString()})");
                ok &= sOk;
            }
            Console.WriteLine(ok ? "  => PASS" : "  => FAIL");
            return ok;
        }

        private static string NalName(int t) => t switch
        {
            1 => "slice", 5 => "IDR", 6 => "SEI", 7 => "SPS", 8 => "PPS", 9 => "AUD", _ => "?",
        };
    }

    internal static class Nal
    {
        public static List<int> Types(ReadOnlySpan<byte> d)
        {
            var list = new List<int>();
            for (int i = 0; i + 3 < d.Length; i++)
            {
                if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1) { list.Add(d[i + 3] & 0x1F); i += 3; }
            }
            return list;
        }

        public static (int w, int h)? ParseSpsDims(ReadOnlySpan<byte> d)
        {
            for (int i = 0; i + 3 < d.Length; i++)
            {
                if (d[i] == 0 && d[i + 1] == 0 && d[i + 2] == 1 && (d[i + 3] & 0x1F) == 7)
                {
                    int end = i + 4;
                    while (end + 2 < d.Length && !(d[end] == 0 && d[end + 1] == 0 && (d[end + 2] == 1 || d[end + 2] == 0))) end++;
                    var rbsp = new List<byte>();
                    for (int k = i + 4; k < Math.Min(end + 2, d.Length); k++)
                    {
                        if (k >= i + 6 && d[k] == 3 && d[k - 1] == 0 && d[k - 2] == 0) continue; // emulation prevention
                        rbsp.Add(d[k]);
                    }
                    try { return Sps(rbsp.ToArray()); } catch { return null; }
                }
            }
            return null;
        }

        private static (int, int) Sps(byte[] b)
        {
            var r = new BitReader(b);
            int profile = r.Bits(8); r.Bits(8); r.Bits(8); r.Ue();
            int chroma = 1;
            if (profile is 100 or 110 or 122 or 244 or 44 or 83 or 86 or 118 or 128)
            {
                chroma = r.Ue(); if (chroma == 3) r.Bits(1);
                r.Ue(); r.Ue(); r.Bits(1);
                if (r.Bits(1) == 1) throw new NotSupportedException("scaling matrix");
            }
            r.Ue();
            int poc = r.Ue();
            if (poc == 0) r.Ue();
            else if (poc == 1) { r.Bits(1); r.Se(); r.Se(); int n = r.Ue(); for (int i = 0; i < n; i++) r.Se(); }
            r.Ue(); r.Bits(1);
            int wMbs = r.Ue() + 1, hMap = r.Ue() + 1;
            int frameMbsOnly = r.Bits(1);
            if (frameMbsOnly == 0) r.Bits(1);
            r.Bits(1);
            int cl = 0, cr = 0, ctop = 0, cb = 0;
            if (r.Bits(1) == 1) { cl = r.Ue(); cr = r.Ue(); ctop = r.Ue(); cb = r.Ue(); }
            int subW = chroma == 3 ? 1 : 2, subH = chroma == 1 ? 2 : 1;
            int width = wMbs * 16 - subW * (cl + cr);
            int height = (2 - frameMbsOnly) * hMap * 16 - subH * (2 - frameMbsOnly) * (ctop + cb);
            return (width, height);
        }

        private sealed class BitReader(byte[] b)
        {
            private int _pos;
            public int Bits(int n) { int v = 0; for (int i = 0; i < n; i++) { v = (v << 1) | ((b[_pos >> 3] >> (7 - (_pos & 7))) & 1); _pos++; } return v; }
            public int Ue() { int z = 0; while (Bits(1) == 0) z++; return (1 << z) - 1 + (z > 0 ? Bits(z) : 0); }
            public int Se() { int v = Ue(); return (v & 1) == 1 ? (v + 1) / 2 : -(v / 2); }
        }
    }
}
