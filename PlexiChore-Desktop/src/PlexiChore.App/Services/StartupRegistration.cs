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
