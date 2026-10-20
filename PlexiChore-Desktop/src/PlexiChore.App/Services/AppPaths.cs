namespace PlexiChore.App.Services;

/// Well-known locations. Roaming settings, local (machine-specific) logs and downloaded tools.
public static class AppPaths
{
    public const string AppName = "PlexiChore";

    public static string RoamingDir { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), AppName);

    public static string LocalDir { get; } =
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), AppName);

    public static string SettingsFile => Path.Combine(RoamingDir, "settings.json");
    public static string LogsDir => Path.Combine(LocalDir, "logs");
    public static string PlatformToolsDir => Path.Combine(LocalDir, "platform-tools");
    public static string VddWorkDir => Path.Combine(LocalDir, "vdd");

    public static string ExecutablePath =>
        Environment.ProcessPath ?? Path.Combine(AppContext.BaseDirectory, "PlexiChore.exe");
}
