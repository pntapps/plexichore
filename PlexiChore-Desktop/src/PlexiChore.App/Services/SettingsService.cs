using System.Text.Json;
using System.Text.Json.Serialization;

namespace PlexiChore.App.Services;

public sealed class TrustedDevice
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public DateTime AddedUtc { get; set; } = DateTime.UtcNow;
    [JsonIgnore] public string AddedText => $"Trusted since {AddedUtc.ToLocalTime():d MMM yyyy}";
    [JsonIgnore] public string ShortId => Id.Length > 8 ? Id[..8] : Id;
}

public sealed class AppSettings
{
    public string HostId { get; set; } = "";
    public bool StartWithWindows { get; set; } = true;
    public bool RequireApprovalForWifi { get; set; } = true;
    public bool PreferHardwareEncoder { get; set; } = true;
    public bool ServerPaused { get; set; }
    public bool ShowConnectNotifications { get; set; } = true;
    public bool AutoAdbReverse { get; set; } = true;
    /// Optional user override for adb.exe.
    public string? AdbPath { get; set; }
    public List<TrustedDevice> TrustedDevices { get; set; } = new();
    public bool FirstRunCompleted { get; set; }
}

/// Loads / saves %APPDATA%\PlexiChore\settings.json atomically. HostId is generated once and never changes.
public sealed class SettingsService
{
    private static readonly JsonSerializerOptions JsonOpts = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    private readonly string _path;
    private readonly object _gate = new();

    public SettingsService(string? path = null)
    {
        _path = path ?? AppPaths.SettingsFile;
        Current = Load();
    }

    public AppSettings Current { get; private set; }

    public event EventHandler? Changed;

    private AppSettings Load()
    {
        AppSettings s;
        try
        {
            s = File.Exists(_path)
                ? JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(_path), JsonOpts) ?? new AppSettings()
                : new AppSettings();
        }
        catch
        {
            // Corrupt file: keep a backup and start fresh rather than crash at login.
            try { File.Copy(_path, _path + ".bak", overwrite: true); } catch { }
            s = new AppSettings();
        }

        var dirty = false;
        if (!Guid.TryParse(s.HostId, out _))
        {
            s.HostId = Guid.NewGuid().ToString();
            dirty = true;
        }
        s.TrustedDevices ??= new();
        if (dirty || !File.Exists(_path)) SaveCore(s);
        return s;
    }

    public void Save()
    {
        SaveCore(Current);
        Changed?.Invoke(this, EventArgs.Empty);
    }

    public void Update(Action<AppSettings> mutate)
    {
        lock (_gate) mutate(Current);
        Save();
    }

    private void SaveCore(AppSettings s)
    {
        lock (_gate)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(s, JsonOpts));
            File.Move(tmp, _path, overwrite: true);
        }
    }

    public bool IsTrusted(string deviceId) =>
        Current.TrustedDevices.Any(d => string.Equals(d.Id, deviceId, StringComparison.OrdinalIgnoreCase));

    public void AddTrusted(string deviceId, string name)
    {
        Update(s =>
        {
            s.TrustedDevices.RemoveAll(d => string.Equals(d.Id, deviceId, StringComparison.OrdinalIgnoreCase));
            s.TrustedDevices.Add(new TrustedDevice { Id = deviceId, Name = name, AddedUtc = DateTime.UtcNow });
        });
    }

    public void RemoveTrusted(string deviceId) =>
        Update(s => s.TrustedDevices.RemoveAll(d => string.Equals(d.Id, deviceId, StringComparison.OrdinalIgnoreCase)));
}
