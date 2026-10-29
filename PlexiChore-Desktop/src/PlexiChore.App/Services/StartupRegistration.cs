using Microsoft.Win32;

namespace PlexiChore.App.Services;

/// HKCU\Software\Microsoft\Windows\CurrentVersion\Run\PlexiChore = "<exe>" --minimized
public static class StartupRegistration
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string ValueName = "PlexiChore";

    public static string Command => $"\"{AppPaths.ExecutablePath}\" --minimized";

    public static bool IsEnabled()
    {
        using var k = Registry.CurrentUser.OpenSubKey(RunKey, false);
        return k?.GetValue(ValueName) is string s && s.Length > 0;
    }

    public static void Set(bool enabled)
    {
        using var k = Registry.CurrentUser.CreateSubKey(RunKey, true);
        if (enabled) k.SetValue(ValueName, Command, RegistryValueKind.String);
        else if (k.GetValue(ValueName) != null) k.DeleteValue(ValueName, false);
    }

    private const int RESTART_NO_PATCH = 4, RESTART_NO_REBOOT = 8;

    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private static extern int RegisterApplicationRestart(string? commandLine, int flags);

    /// Asks Windows Error Reporting to relaunch the app (minimized to the tray) if it crashes or hangs, so tablets can
    /// keep connecting. Windows only does this for processes that ran at least 60 s; not after updates or reboots
    /// (the Run entry covers those).
    public static void RegisterCrashRestart()
    {
        try { RegisterApplicationRestart("--minimized", RESTART_NO_PATCH | RESTART_NO_REBOOT); } catch { }
    }

    /// Keeps the Run entry pointing at the current exe (e.g. after the app was moved/updated).
    public static void Sync(bool enabled)
    {
        try
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey, false);
            var cur = k?.GetValue(ValueName) as string;
            if (enabled && !string.Equals(cur, Command, StringComparison.OrdinalIgnoreCase)) Set(true);
            else if (!enabled && cur != null) Set(false);
        }
        catch { }
    }
}
