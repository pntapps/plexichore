using System.Diagnostics;
using Microsoft.Extensions.Logging;

namespace PlexiChore.App.Services;

/// Inbound Windows Firewall rules for TCP 47800 (stream) and UDP 47801 (discovery).
/// Querying is unelevated; adding/removing runs netsh elevated, only when the user clicks.
public sealed class FirewallService(ILogger<FirewallService> log)
{
    public const string TcpRuleName = "PlexiChore Stream (TCP 47800)";
    public const string UdpRuleName = "PlexiChore Discovery (UDP 47801)";

    public async Task<bool> AreRulesPresentAsync()
    {
        return await RuleExistsAsync(TcpRuleName) && await RuleExistsAsync(UdpRuleName);
    }

    private static async Task<bool> RuleExistsAsync(string name)
    {
        try
        {
            var psi = new ProcessStartInfo("netsh", $"advfirewall firewall show rule name=\"{name}\"")
            {
                UseShellExecute = false, CreateNoWindow = true,
                RedirectStandardOutput = true, RedirectStandardError = true,
            };
            using var p = Process.Start(psi)!;
            _ = await p.StandardOutput.ReadToEndAsync();
            await p.WaitForExitAsync();
            return p.ExitCode == 0;
        }
        catch { return false; }
    }

    internal static string BuildScript(string exePath, bool add)
    {
        var lines = new List<string>
        {
            "@echo off",
            $"netsh advfirewall firewall delete rule name=\"{TcpRuleName}\" >nul 2>&1",
            $"netsh advfirewall firewall delete rule name=\"{UdpRuleName}\" >nul 2>&1",
        };
        if (add)
        {
            lines.Add($"netsh advfirewall firewall add rule name=\"{TcpRuleName}\" dir=in action=allow protocol=TCP localport=47800 profile=private,domain,public description=\"PlexiChore tablet display stream\" || exit /b 1");
            lines.Add($"netsh advfirewall firewall add rule name=\"{UdpRuleName}\" dir=in action=allow protocol=UDP localport=47801 profile=private,domain,public description=\"PlexiChore tablet discovery\" || exit /b 1");
        }
        lines.Add("exit /b 0");
        return string.Join("\r\n", lines) + "\r\n";
    }

    public Task AddRulesAsync() => RunAsync(add: true);
    public Task RemoveRulesAsync() => RunAsync(add: false);

    private async Task RunAsync(bool add)
    {
        var dir = Path.Combine(Path.GetTempPath(), "PlexiChore");
        Directory.CreateDirectory(dir);
        var script = Path.Combine(dir, add ? "fw-add.cmd" : "fw-remove.cmd");
        await File.WriteAllTextAsync(script, BuildScript(AppPaths.ExecutablePath, add));
        log.LogInformation("Running elevated firewall script ({Action})", add ? "add" : "remove");
        var code = await Elevation.RunElevatedAsync("cmd.exe", $"/c \"\"{script}\"\"", TimeSpan.FromSeconds(60));
        try { File.Delete(script); } catch { }
        if (code != 0) throw new InvalidOperationException($"netsh failed (exit code {code}).");
    }
}
