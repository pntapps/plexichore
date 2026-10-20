using CommunityToolkit.Mvvm.ComponentModel;
using PlexiChore.Engine;

namespace PlexiChore.App.ViewModels;

public sealed partial class SessionViewModel : ObservableObject
{
    public SessionViewModel(SessionInfo info)
    {
        Info = info;
        ConnectedAt = DateTime.Now;
    }

    public SessionInfo Info { get; private set; }
    public Guid SessionId => Info.SessionId;
    public DateTime ConnectedAt { get; }

    public string DeviceName => string.IsNullOrWhiteSpace(Info.DeviceName) ? "Tablet" : Info.DeviceName;
    public string Model => string.IsNullOrWhiteSpace(Info.Model) ? "Android tablet" : Info.Model;
    public string TransportText => Info.IsUsb ? "USB" : "Wi‑Fi";
    public string TransportIcon => Info.IsUsb ? "PlugConnected24" : "Wifi124";
    public bool IsExtend => string.Equals(Info.Mode, "extend", StringComparison.OrdinalIgnoreCase);
    public bool IsPrimaryDisplay => string.Equals(Info.Mode, "primary", StringComparison.OrdinalIgnoreCase);
    public string ModeText => IsPrimaryDisplay ? "Primary display" : IsExtend ? "Extended display" : "Mirrored";
    public string Resolution => $"{Info.Width} × {Info.Height}";
    public string CodecText => Info.Codec.ToUpperInvariant();
    public string TargetFps => $"{Info.Fps}";
    /// "Scale 200% (auto)" — Windows display scale of the virtual monitor; empty when not applicable (mirror).
    public string ScaleText => FormatScale(Info.ScalePercent, Info.ScaleAuto);
    internal static string FormatScale(int percent, bool auto) =>
        percent <= 0 ? "" : auto ? $"Scale {percent}% (auto)" : $"Scale {percent}%";

    [ObservableProperty] private string _fpsText = "—";
    [ObservableProperty] private string _bitrateText = "—";
    [ObservableProperty] private string _rttText = "—";
    [ObservableProperty] private string _encodeText = "—";
    [ObservableProperty] private string _durationText = "just now";

    public void Update(SessionInfo info)
    {
        Info = info;
        OnPropertyChanged(string.Empty);
    }

    public void Apply(SessionStats s)
    {
        FpsText = $"{s.CaptureFps:0}";
        BitrateText = s.BitrateKbps >= 1000 ? $"{s.BitrateKbps / 1000.0:0.0} Mbps" : $"{s.BitrateKbps} kbps";
        RttText = s.RttMs > 0 ? $"{s.RttMs:0} ms" : "—";
        EncodeText = $"{s.EncodeMs:0.0} ms";
        Tick();
    }

    public void Tick()
    {
        var d = DateTime.Now - ConnectedAt;
        DurationText = d.TotalMinutes < 1 ? "just now" : d.TotalHours < 1 ? $"{(int)d.TotalMinutes} min" : $"{(int)d.TotalHours} h {d.Minutes} min";
    }
}
