using System.Diagnostics;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Text;

namespace PlexiBench;

/// PC-side, read-only checks: LAN IP, PlexiChore process / listener, Windows Firewall rules (never modified).
public static class HostChecks
{
    public const int Port = 47800;

    public static List<(string Iface, IPAddress Ip, bool HasGateway)> LanIPv4() =>
        NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .SelectMany(n =>
            {
                var p = n.GetIPProperties();
                bool gw = p.GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
                return p.UnicastAddresses.Where(u => u.Address.AddressFamily == AddressFamily.InterNetwork && !IPAddress.IsLoopback(u.Address)
                                                     && !u.Address.ToString().StartsWith("169.254."))
                    .Select(u => (n.Name, u.Address, gw));
            }).OrderByDescending(x => x.gw).ToList();

    public static string? PickLanIp(string? preferred)
    {
        var all = LanIPv4();
        if (preferred != null && all.Any(a => a.Ip.ToString() == preferred)) return preferred;
        return all.FirstOrDefault().Ip?.ToString();
    }

    public static bool PortListening(int port = Port) =>
        IPGlobalProperties.GetIPGlobalProperties().GetActiveTcpListeners().Any(e => e.Port == port);

    public static (int Pid, string? Path, DateTime? Started)? PlexiChoreApp()
    {
        foreach (var p in Process.GetProcessesByName("PlexiChore"))
        {
            try { return (p.Id, p.MainModule?.FileName, p.StartTime); } catch { return (p.Id, null, null); }
        }
        return null;
    }

    public static string? EngineHostRunning() => Process.GetProcessesByName("EngineHost").Select(p => $"EngineHost pid {p.Id}").FirstOrDefault();

    public static string NetworkCategory()
    {
        var r = RunCapture("powershell.exe", "-NoProfile -NonInteractive -Command \"(Get-NetConnectionProfile | ForEach-Object { $_.InterfaceAlias + '=' + $_.NetworkCategory }) -join ';'\"", 20000);
        return r.Trim();
    }

    public sealed record FwRule(string Name, string Direction, string Action, string Protocol, string Profiles, string Program, string LocalPort, bool Enabled);

    /// Parses `netsh advfirewall firewall show rule name=all dir=in verbose` (works without admin, unlike Get-NetFirewall*Filter).
    public static List<FwRule> InboundRules()
    {
        var text = RunCapture("netsh.exe", "advfirewall firewall show rule name=all dir=in verbose", 90000);
        return ParseNetsh(text);
    }

    public static List<FwRule> ParseNetsh(string text)
    {
        var rules = new List<FwRule>();
        Dictionary<string, string>? cur = null;
        void Flush()
        {
            if (cur == null || !cur.ContainsKey("Rule Name")) return;
            string G(string k) => cur.TryGetValue(k, out var v) ? v : "";
            rules.Add(new FwRule(G("Rule Name"), G("Direction"), G("Action"), G("Protocol"), G("Profiles"), G("Program"), G("LocalPort"), G("Enabled") == "Yes"));
        }
        foreach (var raw in text.Split('\n'))
        {
            var line = raw.TrimEnd('\r');
            int c = line.IndexOf(':');
            if (line.StartsWith("Rule Name:")) { Flush(); cur = new(); }
            if (cur == null || c <= 0 || line.StartsWith("---")) continue;
            var key = line[..c].Trim();
            if (key.Length > 0 && !cur.ContainsKey(key)) cur[key] = line[(c + 1)..].Trim();
        }
        Flush();
        return rules;
    }

    /// Verdict for inbound TCP 47800 to `exePath` on the given profile ("Private"/"Public"/"Domain").
    public static string FirewallVerdict(List<FwRule> rules, string? exePath, string profile)
    {
        bool ProgMatch(FwRule r) => exePath != null && r.Program.Length > 0 && r.Program != "Any"
            && string.Equals(Path.GetFullPath(r.Program), Path.GetFullPath(exePath), StringComparison.OrdinalIgnoreCase);
        bool PortExplicit(FwRule r) => r.LocalPort.Split(',').Select(p => p.Trim()).Contains(Port.ToString());
        bool Applies(FwRule r) => r.Enabled && (r.Protocol is "TCP" or "Any")
            && (r.Profiles.Contains(profile, StringComparison.OrdinalIgnoreCase) || r.Profiles.Contains("Any"))
            && (r.LocalPort is "Any" or "" || PortExplicit(r))
            // targets us: our exe, or a program-agnostic rule for port 47800 (rules without a Program line are
            // package-scoped UWP rules and never apply to a desktop exe)
            && (ProgMatch(r) || (r.Program == "Any" && PortExplicit(r)));
        var applicable = rules.Where(Applies).ToList();
        var block = applicable.Where(r => r.Action == "Block").ToList();
        var allow = applicable.Where(r => r.Action == "Allow").ToList();
        if (block.Count > 0) return $"BLOCKED by: {string.Join(", ", block.Select(b => b.Name))}";
        if (allow.Count > 0) return $"allowed ({profile}) by: {string.Join(", ", allow.Select(a => a.Name).Distinct())}";
        return $"NO allow rule for {exePath ?? "PlexiChore.exe"} on {profile} profile (default inbound = block): wifi-direct will likely fail";
    }

    public static string RunCapture(string exe, string args, int timeoutMs)
    {
        var psi = new ProcessStartInfo(exe, args) { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true, StandardOutputEncoding = Encoding.UTF8 };
        using var p = Process.Start(psi)!;
        var o = p.StandardOutput.ReadToEndAsync();
        _ = p.StandardError.ReadToEndAsync();
        if (!p.WaitForExit(timeoutMs)) { try { p.Kill(); } catch { } }
        o.Wait(2000);
        return o.IsCompletedSuccessfully ? o.Result : "";
    }
}
