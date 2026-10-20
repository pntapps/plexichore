using System.Text.RegularExpressions;

namespace PlexiChore.App.Services.Adb;

public sealed record AdbDevice(
    string Serial,
    string State,                       // device | unauthorized | offline | recovery | sideload | bootloader | authorizing | no permissions
    IReadOnlyDictionary<string, string> Props)
{
    public string? Model => Props.TryGetValue("model", out var m) ? m.Replace('_', ' ') : null;
    public string? Product => Props.TryGetValue("product", out var p) ? p : null;
    public bool IsReady => State == "device";
    public bool IsUnauthorized => State is "unauthorized" or "authorizing";

    /// Wireless debugging (adb pair/connect or mDNS tls-connect) vs a physical cable.
    public bool IsWireless =>
        Serial.Contains("._adb-tls-connect.", StringComparison.OrdinalIgnoreCase) ||
        Serial.Contains("._adb._tcp", StringComparison.OrdinalIgnoreCase) ||
        AdbParser.HostPortSerial().IsMatch(Serial);

    public string DisplayName => Model ?? Product ?? Serial;

    /// Hardware serial of the tablet behind this transport: the serial itself for a cable, the one embedded in an
    /// mDNS wireless-debugging serial ("adb-&lt;serial&gt;-&lt;id&gt;._adb-tls-connect._tcp"); null when unknown (ip:port).
    public string? PhysicalSerial
    {
        get
        {
            if (!IsWireless) return Serial;
            var m = AdbParser.MdnsSerial().Match(Serial);
            return m.Success ? m.Groups[1].Value : null;
        }
    }
}

public static partial class AdbParser
{
    [GeneratedRegex(@"^[\w\.\-\[\]:]+:\d{2,5}$")]
    internal static partial Regex HostPortSerial();

    [GeneratedRegex(@"^adb-(.+)-[^-.]+\._adb", RegexOptions.IgnoreCase)]
    internal static partial Regex MdnsSerial();

    /// Parses `adb devices -l` output.
    public static List<AdbDevice> ParseDevices(string output)
    {
        var list = new List<AdbDevice>();
        foreach (var raw in output.Split('\n'))
        {
            var line = raw.Trim();
            if (line.Length == 0 || line.StartsWith("List of devices", StringComparison.OrdinalIgnoreCase) ||
                line.StartsWith('*') || line.StartsWith("adb ", StringComparison.OrdinalIgnoreCase))
                continue;
            var tokens = line.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries);
            if (tokens.Length < 2) continue;
            var serial = tokens[0];
            int i = 1;
            string state;
            if (tokens[1] == "no" && tokens.Length > 2 && tokens[2].StartsWith("permissions"))
            {
                state = "no permissions";
                i = 3;
                // skip "(...)" explanation
                while (i < tokens.Length && !tokens[i].Contains(':')) i++;
            }
            else
            {
                state = tokens[1];
                i = 2;
            }
            var props = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (; i < tokens.Length; i++)
            {
                var t = tokens[i];
                var c = t.IndexOf(':');
                if (c > 0) props[t[..c]] = t[(c + 1)..];
            }
            list.Add(new AdbDevice(serial, state, props));
        }
        return list;
    }

    /// Which device-side adb transport serves the PlexiChore reverse in `adb reverse --list` output:
    /// "usb-cable" (UsbFfs), "usb-wireless-adb" (host-N = wireless debugging / adb over TCP), null when not listed.
    public static string? ReverseLink(string output, int port)
    {
        var needle = $"tcp:{port} tcp:{port}";
        foreach (var raw in output.Split('\n'))
        {
            var l = raw.Trim();
            if (!l.EndsWith(needle, StringComparison.OrdinalIgnoreCase)) continue;
            var owner = l.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries)[0];
            if (owner.StartsWith("Usb", StringComparison.OrdinalIgnoreCase)) return "usb-cable";
            if (owner.StartsWith("host", StringComparison.OrdinalIgnoreCase)) return "usb-wireless-adb";
            return null;
        }
        return null;
    }
    /// True if `adb reverse --list` output contains the PlexiChore mapping.
    public static bool HasReverse(string output, int port)
    {
        var needle = $"tcp:{port} tcp:{port}";
        return output.Split('\n').Any(l => l.Trim().EndsWith(needle, StringComparison.OrdinalIgnoreCase));
    }
}
