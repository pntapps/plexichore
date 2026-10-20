namespace PlexiChore.App.Services;

/// Ultra-early startup trace (before logging is configured). Enabled with PLEXICHORE_BOOTTRACE=1.
internal static class BootTrace
{
    private static readonly bool Enabled = Environment.GetEnvironmentVariable("PLEXICHORE_BOOTTRACE") == "1";
    private static readonly string File = Path.Combine(Path.GetTempPath(), "plexichore-boot.txt");

    public static void Mark(string what)
    {
        if (!Enabled) return;
        try { System.IO.File.AppendAllText(File, $"{DateTime.Now:HH:mm:ss.fff} [{Environment.ProcessId}] {what}{Environment.NewLine}"); } catch { }
    }
}
