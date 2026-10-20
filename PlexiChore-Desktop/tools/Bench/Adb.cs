using System.Diagnostics;
using System.Globalization;
using System.Text;

namespace PlexiBench;

public readonly record struct AdbResult(int ExitCode, string Output, string Error, double Ms)
{
    public bool Ok => ExitCode == 0;
    public string All => (Output + Error).Trim();
}

/// Thin adb.exe wrapper. Every device command goes through `-s <serial>` (two transports of one tablet are attached).
public sealed class Adb
{
    public static readonly string UsbSerial = Environment.GetEnvironmentVariable("PLEXI_USB_SERIAL") ?? "";
    public static readonly string WirelessSerial = Environment.GetEnvironmentVariable("PLEXI_WIRELESS_SERIAL") ?? "";
    public const string Package = "com.pntapps.plexichore";

    public string Path { get; }
    public Adb(string? path = null)
    {
        Path = path ?? Environment.GetEnvironmentVariable("PLEXI_BENCH_ADB")
            ?? System.IO.Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Android", "Sdk", "platform-tools", "adb.exe");
        if (!File.Exists(Path)) throw new FileNotFoundException("adb.exe not found", Path);
    }

    public AdbResult Global(string args, int timeoutMs = 15000) => Run(args, timeoutMs);
    public AdbResult Dev(string serial, string args, int timeoutMs = 15000) => Run($"-s {serial} {args}", timeoutMs);
    /// `adb -s serial shell "<cmd>"` – cmd is passed as ONE argument so the device shell parses it (no MSYS path mangling: we are not in bash).
    public AdbResult Shell(string serial, string cmd, int timeoutMs = 15000) => RunArgs(new[] { "-s", serial, "shell", cmd }, timeoutMs);

    public byte[] ExecOutBinary(string serial, string cmd, int timeoutMs = 20000)
    {
        var psi = Psi(new[] { "-s", serial, "exec-out", cmd });
        using var p = Process.Start(psi)!;
        using var ms = new MemoryStream();
        var copy = p.StandardOutput.BaseStream.CopyToAsync(ms);
        _ = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } }
        copy.Wait(2000);
        return ms.ToArray();
    }

    private AdbResult Run(string args, int timeoutMs)
    {
        var psi = new ProcessStartInfo(Path, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8 };
        return Exec(psi, timeoutMs);
    }

    private AdbResult RunArgs(string[] args, int timeoutMs) => Exec(Psi(args), timeoutMs);

    private ProcessStartInfo Psi(string[] args)
    {
        var psi = new ProcessStartInfo(Path) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in args) psi.ArgumentList.Add(a);
        return psi;
    }

    private static AdbResult Exec(ProcessStartInfo psi, int timeoutMs)
    {
        var sw = Stopwatch.StartNew();
        using var p = Process.Start(psi)!;
        var o = p.StandardOutput.ReadToEndAsync();
        var e = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(timeoutMs))
        {
            try { p.Kill(); } catch { } // only this client invocation, never the adb server
            return new AdbResult(-2, "", $"timeout after {timeoutMs} ms: {string.Join(' ', psi.ArgumentList)}{psi.Arguments}", sw.Elapsed.TotalMilliseconds);
        }
        Task.WaitAll(new Task[] { o, e }, 2000);
        return new AdbResult(p.ExitCode, o.IsCompletedSuccessfully ? o.Result : "", e.IsCompletedSuccessfully ? e.Result : "", sw.Elapsed.TotalMilliseconds);
    }

    /// serial -> state ("device", "offline", "unauthorized") from `adb devices`.
    public Dictionary<string, string> Devices()
    {
        var d = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        foreach (var line in Global("devices").Output.Split('\n').Skip(1))
        {
            var c = line.Trim().Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
            if (c.Length >= 2) d[c[0]] = c[1];
        }
        return d;
    }

    /// Estimates tablet-wall-clock minus PC-wall-clock (ms) from the min-RTT sample of N `echo $EPOCHREALTIME` round trips
    /// (mksh; falls back to toybox `date +%s.%N`). Accuracy ~ half the best RTT (a few ms over USB).
    public (double OffsetMs, double BestRttMs, string Method) ClockOffset(string serial, int samples = 9)
    {
        double best = double.MaxValue, offset = double.NaN; string method = "EPOCHREALTIME";
        for (int i = 0; i < samples; i++)
        {
            var t0 = DateTime.UtcNow;
            var r = Shell(serial, "echo $EPOCHREALTIME; date +%s.%N", 5000);
            var t1 = DateTime.UtcNow;
            var lines = r.Output.Split('\n').Select(s => s.Trim()).Where(s => s.Length > 0).ToArray();
            double tab = double.NaN;
            if (lines.Length > 0 && double.TryParse(lines[0], NumberStyles.Float, CultureInfo.InvariantCulture, out var e1) && e1 > 1e9) tab = e1;
            else if (lines.Length > 1 && double.TryParse(lines[^1], NumberStyles.Float, CultureInfo.InvariantCulture, out var e2) && e2 > 1e9) { tab = e2; method = "date %N"; }
            if (double.IsNaN(tab)) continue;
            double rtt = (t1 - t0).TotalMilliseconds;
            if (rtt < best)
            {
                best = rtt;
                double mid = (t0 + (t1 - t0) / 2 - DateTime.UnixEpoch).TotalMilliseconds;
                offset = tab * 1000 - mid;
            }
        }
        return (offset, best, method);
    }


    /// Same estimate over ONE long-lived `adb shell` (no per-sample process spawn / transport setup), so the round
    /// trip is ~1-3 ms on USB instead of ~60 ms. Falls back to the per-process method.
    public (double OffsetMs, double BestRttMs, string Method) ClockOffsetPersistent(string serial, int samples = 25)
    {
        try
        {
            using var sh = new PersistentShell(this, serial);
            sh.Exec("echo warm");
            double best = double.MaxValue, offset = double.NaN;
            for (int i = 0; i < samples; i++)
            {
                var t0 = DateTime.UtcNow;
                var line = sh.Exec("echo $EPOCHREALTIME");
                var t1 = DateTime.UtcNow;
                if (!double.TryParse(line, NumberStyles.Float, CultureInfo.InvariantCulture, out var tab) || tab < 1e9) continue;
                double rtt = (t1 - t0).TotalMilliseconds;
                if (rtt < best) { best = rtt; offset = tab * 1000 - (t0 + (t1 - t0) / 2 - DateTime.UnixEpoch).TotalMilliseconds; }
            }
            if (!double.IsNaN(offset)) return (offset, best, "persistent shell EPOCHREALTIME");
        }
        catch { }
        return ClockOffset(serial);
    }
}

/// A long-lived `adb -s serial shell` fed through stdin; Exec() runs one command and returns its last output line
/// (each command is followed by a unique sentinel echo).
public sealed class PersistentShell : IDisposable
{
    private readonly Process _p;
    private int _seq;

    public PersistentShell(Adb adb, string serial)
    {
        var psi = new ProcessStartInfo(adb.Path) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (var a in new[] { "-s", serial, "shell" }) psi.ArgumentList.Add(a);
        _p = Process.Start(psi)!;
        _p.StandardInput.AutoFlush = true;
        _p.StandardInput.NewLine = "\n";
        _ = _p.StandardError.ReadToEndAsync();
    }

    public string Exec(string cmd, int timeoutMs = 10000)
    {
        var tag = $"__pb{++_seq}__";
        _p.StandardInput.WriteLine($"{cmd}; echo {tag}");
        string last = "";
        var deadline = Environment.TickCount64 + timeoutMs;
        while (Environment.TickCount64 < deadline)
        {
            var read = _p.StandardOutput.ReadLineAsync();
            if (!read.Wait((int)Math.Max(1, deadline - Environment.TickCount64))) break;
            var line = read.Result;
            if (line == null) throw new IOException("adb shell exited");
            line = line.TrimEnd('\r');
            if (line == tag) return last;
            last = line;
        }
        throw new TimeoutException($"adb shell: no reply to '{cmd}'");
    }

    public void Dispose()
    {
        try { _p.StandardInput.WriteLine("exit"); if (!_p.WaitForExit(1500)) _p.Kill(); } catch { }
        _p.Dispose();
    }
}
