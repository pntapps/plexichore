using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using Microsoft.Extensions.Logging;

namespace PlexiChore.App.Services.Adb;

public enum AdbStatus { Searching, NotFound, Downloading, Running, Error }

/// Finds adb, polls `adb devices -l` every 2 s and keeps `adb reverse tcp:47800 tcp:47800` applied on every
/// authorized device so the tablet can reach the host over USB (or wireless debugging) at 127.0.0.1:47800.
/// Never kills or restarts the user's adb server.
public sealed class AdbManager : IAsyncDisposable
{
    public const string PlatformToolsUrl = "https://dl.google.com/android/repository/platform-tools-latest-windows.zip";
    public const int Port = 47800;

    private readonly ILogger<AdbManager> _log;
    private readonly Func<string?> _overridePath;
    private readonly System.Collections.Concurrent.ConcurrentDictionary<string, DateTime> _reversedAt = new();
    private CancellationTokenSource? _cts;
    private Task? _loop;
    private bool _serverStarted;

    public AdbManager(ILogger<AdbManager> log, Func<string?> overridePath)
    {
        _log = log;
        _overridePath = overridePath;
    }

    public string? AdbPath { get; private set; }
    public string? AdbVersion { get; private set; }
    public AdbStatus Status { get; private set; } = AdbStatus.Searching;
    public string? LastError { get; private set; }
    public IReadOnlyList<AdbDevice> Devices { get; private set; } = Array.Empty<AdbDevice>();
    public IReadOnlySet<string> ReversedSerials => _reversedAt.Keys.ToHashSet();
    public bool AutoReverse { get; set; } = true;

    /// Raised (on a thread-pool thread) whenever status or the device list changes.
    public event EventHandler? Changed;

    // ---------- discovery ----------
    public static IEnumerable<string> CandidatePaths(string? overridePath)
    {
        if (!string.IsNullOrWhiteSpace(overridePath)) yield return overridePath!;
        yield return Path.Combine(AppContext.BaseDirectory, "platform-tools", "adb.exe"); // bundled next to exe
        yield return Path.Combine(AppPaths.PlatformToolsDir, "adb.exe");                    // downloaded by us
        foreach (var env in new[] { "ANDROID_HOME", "ANDROID_SDK_ROOT" })
        {
            var v = Environment.GetEnvironmentVariable(env);
            if (!string.IsNullOrEmpty(v)) yield return Path.Combine(v, "platform-tools", "adb.exe");
        }
        var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        yield return Path.Combine(local, "Android", "Sdk", "platform-tools", "adb.exe");
        var pf86 = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86);
        var pf = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        yield return Path.Combine(pf86, "Android", "android-sdk", "platform-tools", "adb.exe");
        yield return Path.Combine(pf, "Android", "android-sdk", "platform-tools", "adb.exe");
        foreach (var dir in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator))
        {
            if (string.IsNullOrWhiteSpace(dir)) continue;
            string p;
            try { p = Path.Combine(dir.Trim().Trim('"'), "adb.exe"); } catch { continue; }
            yield return p;
        }
    }

    public static string? Locate(string? overridePath) => CandidatePaths(overridePath).FirstOrDefault(File.Exists);

    // ---------- lifecycle ----------
    public void Start()
    {
        if (_loop != null) return;
        _cts = new CancellationTokenSource();
        _loop = Task.Run(() => LoopAsync(_cts.Token));
    }

    public void Rescan()
    {
        AdbPath = null;
        _serverStarted = false;
        SetStatus(AdbStatus.Searching);
    }

    private async Task LoopAsync(CancellationToken ct)
    {
        var verifyEvery = TimeSpan.FromSeconds(15);
        while (!ct.IsCancellationRequested)
        {
            try
            {
                if (Status == AdbStatus.Downloading) { await Task.Delay(1000, ct); continue; }
                if (AdbPath == null || !File.Exists(AdbPath))
                {
                    AdbPath = Locate(_overridePath());
                    _serverStarted = false;
                    if (AdbPath == null)
                    {
                        Devices = Array.Empty<AdbDevice>();
                        SetStatus(AdbStatus.NotFound);
                        await Task.Delay(5000, ct);
                        continue;
                    }
                    _log.LogInformation("Using adb at {Path}", AdbPath);
                    var ver = await RunAsync("version", TimeSpan.FromSeconds(10), ct);
                    AdbVersion = ver.Output.Split('\n').FirstOrDefault()?.Trim();
                }

                if (!_serverStarted)
                {
                    // start-server is a no-op if the user's server is already running. Run without redirection:
                    // a freshly forked adb daemon can inherit redirected pipes and block ReadToEnd forever.
                    await StartServerAsync(ct);
                    _serverStarted = true;
                }

                var r = await RunAsync("devices -l", TimeSpan.FromSeconds(10), ct);
                if (r.ExitCode != 0)
                {
                    LastError = r.Error.Trim().Length > 0 ? r.Error.Trim() : $"adb devices exited with {r.ExitCode}";
                    SetStatus(AdbStatus.Error);
                    _serverStarted = false;
                    await Task.Delay(3000, ct);
                    continue;
                }
                var devices = AdbParser.ParseDevices(r.Output);
                var changed = !devices.SequenceEqual(Devices, DeviceComparer.Instance);

                // forget reversals for devices that went away / changed state
                foreach (var gone in _reversedAt.Keys.Where(s => !devices.Any(d => d.Serial == s && d.IsReady)).ToList())
                    _reversedAt.TryRemove(gone, out _);

                // adbd keeps ONE reverse listener per device port, served by whichever transport applied it last.
                // When the same tablet is on a cable and on wireless debugging, only the cable gets it (lower latency,
                // far more bandwidth). Never "remove" on the wireless twin (that deletes the shared listener); it is
                // re-applied there automatically once the cable goes away.
                var cabled = devices.Where(d => d.IsReady && !d.IsWireless).Select(d => d.Serial).ToHashSet(StringComparer.OrdinalIgnoreCase);
                bool HasCableTwin(AdbDevice d) => d.IsWireless && d.PhysicalSerial != null && cabled.Contains(d.PhysicalSerial);
                foreach (var d in devices.Where(HasCableTwin)) _reversedAt.TryRemove(d.Serial, out _);
                // A cable that just appeared must take the listener over even though the wireless twin set it before.
                foreach (var d in devices.Where(d => d.IsReady && !d.IsWireless && !Devices.Any(o => o.Serial == d.Serial && o.IsReady)))
                    _reversedAt.TryRemove(d.Serial, out _);

                if (AutoReverse)
                {
                    // wireless first, cables last: if a wireless twin could not be matched, the cable still wins
                    foreach (var d in devices.Where(d => d.IsReady && !HasCableTwin(d)).OrderBy(d => d.IsWireless ? 0 : 1))
                    {
                        if (_reversedAt.TryGetValue(d.Serial, out var at))
                        {
                            if (DateTime.UtcNow - at < verifyEvery) continue;
                            // periodic verification: another tool may have restarted the adb server (rules lost)
                            var list = await RunAsync($"-s {Quote(d.Serial)} reverse --list", TimeSpan.FromSeconds(8), ct);
                            if (list.ExitCode == 0 && AdbParser.HasReverse(list.Output, Port))
                            {
                                _reversedAt[d.Serial] = DateTime.UtcNow;
                                continue;
                            }
                        }
                        if (await ApplyReverseAsync(d.Serial, ct)) changed = true;
                    }
                }

                Devices = devices;
                LastError = null;
                if (Status != AdbStatus.Running || changed) SetStatus(AdbStatus.Running);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { break; }
            catch (Exception ex)
            {
                _log.LogWarning(ex, "adb poll failed");
                LastError = ex.Message;
                SetStatus(AdbStatus.Error);
            }
            try { await Task.Delay(2000, ct); } catch (OperationCanceledException) { break; }
        }
    }

    private async Task<bool> ApplyReverseAsync(string serial, CancellationToken ct)
    {
        var r = await RunAsync($"-s {Quote(serial)} reverse tcp:{Port} tcp:{Port}", TimeSpan.FromSeconds(10), ct);
        if (r.ExitCode == 0)
        {
            _reversedAt[serial] = DateTime.UtcNow;
            _log.LogInformation("adb reverse tcp:{Port} applied on {Serial}", Port, serial);
            return true;
        }
        _log.LogWarning("adb reverse failed on {Serial}: {Err}", serial, (r.Error + r.Output).Trim());
        return false;
    }

    /// For a tablet connected through 127.0.0.1 (adb reverse): is the reverse served over the cable or over wireless
    /// debugging? Asks the device which transport owns the tcp:47800 listener. `model` is the tablet's HELLO model
    /// ("SM-X700"; adb lists "SM_X700"). Null when unknown (no matching device, adb busy).
    public async Task<string?> ResolveLoopbackLinkAsync(string? model, CancellationToken ct)
    {
        static string Norm(string? s) => (s ?? "").Replace('_', ' ').Replace('-', ' ').Trim().ToUpperInvariant();
        var ready = Devices.Where(d => d.IsReady).ToList();
        var mine = ready.Where(d => Norm(d.Model) == Norm(model)).ToList();
        if (mine.Count == 0 && ready.Count == 1) mine = ready;
        foreach (var d in mine.OrderBy(d => d.IsWireless ? 1 : 0))
        {
            var r = await RunAsync($"-s {Quote(d.Serial)} reverse --list", TimeSpan.FromSeconds(3), ct);
            if (r.ExitCode != 0) continue;
            var link = AdbParser.ReverseLink(r.Output, Port);
            if (link != null) return link;
        }
        return null;
    }
    /// Forces reverse to be re-applied on all devices at the next poll.
    public void ReapplyAll() => _reversedAt.Clear();

    private async Task StartServerAsync(CancellationToken ct)
    {
        var psi = new ProcessStartInfo(AdbPath!, "start-server")
        {
            UseShellExecute = false, CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        using var p = Process.Start(psi)!;
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(TimeSpan.FromSeconds(20));
        try { await p.WaitForExitAsync(cts.Token); }
        catch (OperationCanceledException) when (!ct.IsCancellationRequested) { _log.LogWarning("adb start-server timed out"); }
    }

    public readonly record struct RunResult(int ExitCode, string Output, string Error);

    public async Task<RunResult> RunAsync(string args, TimeSpan timeout, CancellationToken ct = default)
    {
        if (AdbPath == null) return new RunResult(-1, "", "adb not found");
        var psi = new ProcessStartInfo(AdbPath, args)
        {
            UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8, StandardErrorEncoding = Encoding.UTF8,
        };
        using var p = new Process { StartInfo = psi };
        p.Start();
        var outTask = p.StandardOutput.ReadToEndAsync();
        var errTask = p.StandardError.ReadToEndAsync();
        using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        cts.CancelAfter(timeout);
        try
        {
            await p.WaitForExitAsync(cts.Token);
        }
        catch (OperationCanceledException)
        {
            try { p.Kill(); } catch { }   // kills only this adb client invocation, never the server
            if (ct.IsCancellationRequested) throw;
            return new RunResult(-2, "", $"adb {args} timed out");
        }
        var done = Task.WhenAll(outTask, errTask);
        await Task.WhenAny(done, Task.Delay(2000, CancellationToken.None));
        return new RunResult(p.ExitCode,
            outTask.IsCompletedSuccessfully ? outTask.Result : "",
            errTask.IsCompletedSuccessfully ? errTask.Result : "");
    }

    private static string Quote(string s) => s.Contains(' ') ? $"\"{s}\"" : s;

    private void SetStatus(AdbStatus s)
    {
        Status = s;
        Changed?.Invoke(this, EventArgs.Empty);
    }

    // ---------- one-click platform-tools download ----------
    public async Task DownloadPlatformToolsAsync(IProgress<double>? progress, CancellationToken ct = default)
    {
        var prev = Status;
        SetStatus(AdbStatus.Downloading);
        var tmpZip = Path.Combine(Path.GetTempPath(), $"plexichore-platform-tools-{Guid.NewGuid():N}.zip");
        var staging = Path.Combine(AppPaths.LocalDir, "platform-tools.staging");
        try
        {
            using (var http = new HttpClient { Timeout = TimeSpan.FromMinutes(10) })
            {
                http.DefaultRequestHeaders.UserAgent.ParseAdd("PlexiChore-Desktop/1.0");
                using var resp = await http.GetAsync(PlatformToolsUrl, HttpCompletionOption.ResponseHeadersRead, ct);
                resp.EnsureSuccessStatusCode();
                var total = resp.Content.Headers.ContentLength ?? 0;
                await using var src = await resp.Content.ReadAsStreamAsync(ct);
                await using var dst = File.Create(tmpZip);
                var buf = new byte[81920];
                long read = 0;
                int n;
                while ((n = await src.ReadAsync(buf, ct)) > 0)
                {
                    await dst.WriteAsync(buf.AsMemory(0, n), ct);
                    read += n;
                    if (total > 0) progress?.Report(read * 0.9 / total);
                }
            }
            if (Directory.Exists(staging)) Directory.Delete(staging, true);
            ZipFile.ExtractToDirectory(tmpZip, staging);
            var extracted = Path.Combine(staging, "platform-tools");
            if (!File.Exists(Path.Combine(extracted, "adb.exe")))
                throw new InvalidDataException("Downloaded archive did not contain platform-tools\\adb.exe.");
            var target = AppPaths.PlatformToolsDir;
            if (Directory.Exists(target))
            {
                try { Directory.Delete(target, true); }
                catch (IOException) { throw new IOException("An adb from a previous download is still running. Close it and retry."); }
            }
            Directory.Move(extracted, target);
            progress?.Report(1.0);
            _log.LogInformation("platform-tools installed to {Dir}", target);
            AdbPath = null; // re-locate on next poll, will prefer ours if no SDK... (Locate order)
            _serverStarted = false;
            SetStatus(AdbStatus.Searching);
        }
        catch (Exception ex)
        {
            _log.LogError(ex, "platform-tools download failed");
            LastError = ex.Message;
            SetStatus(prev == AdbStatus.Downloading ? AdbStatus.NotFound : prev);
            throw;
        }
        finally
        {
            try { File.Delete(tmpZip); } catch { }
            try { if (Directory.Exists(staging)) Directory.Delete(staging, true); } catch { }
        }
    }

    public async ValueTask DisposeAsync()
    {
        _cts?.Cancel();
        if (_loop != null) { try { await _loop.WaitAsync(TimeSpan.FromSeconds(3)); } catch { } }
        _cts?.Dispose();
    }

    private sealed class DeviceComparer : IEqualityComparer<AdbDevice>
    {
        public static readonly DeviceComparer Instance = new();
        public bool Equals(AdbDevice? a, AdbDevice? b) => a?.Serial == b?.Serial && a?.State == b?.State && a?.Model == b?.Model;
        public int GetHashCode(AdbDevice d) => HashCode.Combine(d.Serial, d.State);
    }
}
