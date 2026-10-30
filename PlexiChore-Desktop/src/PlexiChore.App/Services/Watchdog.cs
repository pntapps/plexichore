using System.Diagnostics;

namespace PlexiChore.App.Services;

/// Relaunches PlexiChore (minimized) when it dies from a crash, so tablets can reconnect without anyone restarting the
/// app. Runs as a second, window-less copy of the exe: "PlexiChore.exe --watchdog <pid>". Quitting, End task and
/// taskkill exit with 0 / 1 and are left alone; at most MaxRestarts relaunches per RestartWindow (no crash loop).
/// Replaces RegisterApplicationRestart, which Windows skipped when WER wrote a crash dump.
public static class Watchdog
{
    public const string Arg = "--watchdog";
    private const int MaxRestarts = 3;
    private static readonly TimeSpan RestartWindow = TimeSpan.FromMinutes(10);
    private static string HistoryFile => Path.Combine(AppPaths.LocalDir, "crash-restarts.txt");

    /// Called by the app once it owns the single-instance mutex.
    public static void Start()
    {
        try
        {
            Process.Start(new ProcessStartInfo(AppPaths.ExecutablePath, $"{Arg} {Environment.ProcessId}")
            {
                UseShellExecute = false,
                CreateNoWindow = true,
            })?.Dispose();
        }
        catch { }
    }

    public static int Run(int pid)
    {
        int code;
        try
        {
            using var p = Process.GetProcessById(pid);
            _ = p.Handle; // open it now so the exit code stays readable
            p.WaitForExit();
            code = p.ExitCode;
        }
        catch { return 0; }
        if (!IsCrash(code)) return 0;

        if (!RecordRestart())
        {
            Log($"PlexiChore exited with 0x{code:X8}; not restarting ({MaxRestarts} restarts within {RestartWindow.TotalMinutes:0} min)");
            return 0;
        }
        Log($"PlexiChore (pid {pid}) exited with 0x{code:X8}; restarting it");
        Thread.Sleep(1500);
        try { Process.Start(new ProcessStartInfo(AppPaths.ExecutablePath, "--minimized") { UseShellExecute = false })?.Dispose(); }
        catch (Exception ex) { Log("Restart failed: " + ex.Message); }
        return 0;
    }

    /// NTSTATUS errors (access violation 0xC0000005, fail-fast 0xC0000409, ...) and unhandled .NET exceptions
    /// (0xE0434352). 0xC000013A is the logoff / Ctrl+C termination, not a crash.
    public static bool IsCrash(int exitCode)
    {
        uint u = unchecked((uint)exitCode);
        return (u >= 0xC0000000 && u != 0xC000013A) || u == 0xE0434352;
    }

    /// Appends now to the restart history; false when the limit is reached.
    private static bool RecordRestart()
    {
        try
        {
            var now = DateTime.UtcNow;
            var recent = File.Exists(HistoryFile)
                ? File.ReadAllLines(HistoryFile)
                    .Select(l => long.TryParse(l, out var t) ? new DateTime(t, DateTimeKind.Utc) : DateTime.MinValue)
                    .Where(t => now - t < RestartWindow).ToList()
                : new List<DateTime>();
            if (recent.Count >= MaxRestarts) return false;
            recent.Add(now);
            Directory.CreateDirectory(AppPaths.LocalDir);
            File.WriteAllLines(HistoryFile, recent.Select(t => t.Ticks.ToString()));
            return true;
        }
        catch { return true; }
    }

    private static void Log(string msg)
    {
        try
        {
            Directory.CreateDirectory(AppPaths.LogsDir);
            File.AppendAllText(Path.Combine(AppPaths.LogsDir, $"plexichore-{DateTime.Now:yyyyMMdd}.log"),
                $"{DateTime.Now:HH:mm:ss.fff} [WRN] Watchdog: {msg}{Environment.NewLine}");
        }
        catch { }
    }
}
