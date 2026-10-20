using PlexiChore.App.Services.Adb;

namespace PlexiChore.App.ViewModels;

public sealed class AdbDeviceViewModel
{
    public AdbDeviceViewModel(AdbDevice d, bool reversed)
    {
        Device = d;
        Reversed = reversed;
    }

    public AdbDevice Device { get; }
    public bool Reversed { get; }
    public string Name => Device.DisplayName;
    public string Serial => Device.Serial;
    public string Connection => Device.IsWireless ? "Wireless debugging" : "USB cable";
    public string ConnectionIcon => Device.IsWireless ? "Wifi124" : "PlugConnected24";

    public string StateText => Device.State switch
    {
        "device" => Reversed ? "Ready · port 47800 forwarded" : "Connected · forwarding…",
        "unauthorized" => "Waiting for authorization",
        "authorizing" => "Authorizing…",
        "offline" => "Offline",
        "no permissions" => "No permission",
        "recovery" or "sideload" or "bootloader" => $"In {Device.State} mode",
        _ => Device.State,
    };

    public string Tone => Device.State switch
    {
        "device" => Reversed ? "good" : "info",
        "unauthorized" or "authorizing" => "warn",
        _ => "bad",
    };

    public string? Hint => Device.State switch
    {
        "unauthorized" => "Unlock the tablet and tap “Allow” on the “Allow USB debugging?” prompt. Tick “Always allow from this computer” so it is remembered.",
        "authorizing" => "Keep the tablet unlocked while it authorizes this PC.",
        "offline" => "Unplug and replug the cable, or toggle USB debugging off and on in Developer options.",
        "no permissions" => "Reconnect the tablet and accept the debugging prompt.",
        _ => null,
    };
}
