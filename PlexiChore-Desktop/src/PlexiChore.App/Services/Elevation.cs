using System.ComponentModel;
using System.Diagnostics;

namespace PlexiChore.App.Services;

public static class Elevation
{
    /// Runs a process elevated via UAC ("runas"). Returns exit code, or throws OperationCanceledException if the
    /// user declined the UAC prompt.
    public static async Task<int> RunElevatedAsync(string fileName, string arguments, TimeSpan timeout,
        CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo(fileName, arguments)
        {
            UseShellExecute = true,
            Verb = "runas",
            WindowStyle = ProcessWindowStyle.Hidden,
            CreateNoWindow = true,
        };
        Process? p;
        try
        {
            p = Process.Start(psi);
        }
        catch (Win32Exception ex) when (ex.NativeErrorCode == 1223) // ERROR_CANCELLED
        {
            throw new OperationCanceledException("Administrator permission was declined.");
        }
        if (p == null) throw new InvalidOperationException($"Could not start {fileName}.");
        using (p)
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(timeout);
            try { await p.WaitForExitAsync(cts.Token); }
            catch (OperationCanceledException) { throw new TimeoutException($"{Path.GetFileName(fileName)} did not finish within {timeout.TotalSeconds:0} s."); }
            return p.ExitCode;
        }
    }

    /// Runs an elevated PowerShell script file with arguments.
    public static Task<int> RunElevatedPowerShellAsync(string scriptPath, string args, TimeSpan timeout,
        CancellationToken ct = default) =>
        RunElevatedAsync("powershell.exe",
            $"-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"{scriptPath}\" {args}",
            timeout, ct);
}
