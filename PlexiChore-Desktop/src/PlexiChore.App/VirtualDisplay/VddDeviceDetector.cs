using System.Management;

namespace PlexiChore.App.VirtualDisplay;

/// NeedsRepair: the adapter is running but its virtual monitor did not arrive (e.g. IddCxMonitorArrival failed because
/// the settings had too many modes, or monitors/count = 0). Fixed by Repair (compact settings + elevated restart).
public enum VddState { Unknown, NotInstalled, Ready, Disabled, Error, NeedsRepair }

public sealed record VddDeviceStatus(VddState State, string? InstanceId, string? Name, int ConfigManagerErrorCode, string? Detail,
    bool MonitorPresent = false)
{
    public static readonly VddDeviceStatus NotInstalled = new(VddState.NotInstalled, null, null, 0, null);

    public const string NoMonitorDetail = "Virtual monitor didn't start — click Repair (admin).";

    /// Combines the PnP device state with whether its virtual monitor exists (unit-tested).
    public VddDeviceStatus WithMonitor(bool monitorPresent) =>
        State == VddState.Ready && !monitorPresent
            ? this with { State = VddState.NeedsRepair, MonitorPresent = false, Detail = NoMonitorDetail }
            : this with { MonitorPresent = monitorPresent };
}

/// Detects the root-enumerated Virtual Display Driver device (hardware id Root\MttVDD) via WMI.
public static class VddDeviceDetector
{
    public const string HardwareId = @"Root\MttVDD";
    public const string DisplayClassGuid = "4d36e968-e325-11ce-bfc1-08002be10318";

    public static VddDeviceStatus Detect()
    {
        using var searcher = new ManagementObjectSearcher(
            @"SELECT DeviceID, Name, Status, ConfigManagerErrorCode, HardwareID FROM Win32_PnPEntity WHERE DeviceID LIKE 'ROOT\\%'");
        foreach (ManagementObject mo in searcher.Get())
        {
            using (mo)
            {
                var ids = mo["HardwareID"] as string[] ?? Array.Empty<string>();
                if (!ids.Any(i => string.Equals(i, HardwareId, StringComparison.OrdinalIgnoreCase))) continue;
                var code = mo["ConfigManagerErrorCode"] is uint c ? (int)c : 0;
                var state = code switch
                {
                    0 => VddState.Ready,
                    22 => VddState.Disabled,
                    _ => VddState.Error,
                };
                return new VddDeviceStatus(state, mo["DeviceID"] as string, mo["Name"] as string, code, Describe(code));
            }
        }
        return VddDeviceStatus.NotInstalled;
    }

    public static Task<VddDeviceStatus> DetectAsync() => Task.Run(Detect);

    public static string? Describe(int cmErrorCode) => cmErrorCode switch
    {
        0 => null,
        1 => "Device is not configured correctly (code 1).",
        10 => "Device cannot start (code 10). Try Repair.",
        22 => "Device is disabled in Device Manager (code 22).",
        28 => "Driver is not installed for the device (code 28). Try Repair.",
        31 => "Windows cannot load the driver (code 31). Try Repair.",
        43 => "Windows stopped the device because it reported problems (code 43). Try Repair, then reboot.",
        52 => "Windows cannot verify the driver signature (code 52).",
        _ => $"Device problem code {cmErrorCode}.",
    };
}
