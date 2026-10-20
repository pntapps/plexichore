using System.IO.Compression;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using PlexiChore.App.Services;

namespace PlexiChore.App.VirtualDisplay;

/// Downloads and (un)installs the signed Virtual Display Driver (https://github.com/VirtualDrivers/Virtual-Display-Driver,
/// MIT) the same way the project's own "silent-install.ps1" does: trust the SignPath publisher certificate from the
/// catalog, then `nefconw install MttVDD.inf Root\MttVDD` (creates the root device node + installs the driver).
/// Everything is downloaded unelevated; only the generated PowerShell script runs elevated (one UAC prompt).
public sealed class VddInstaller(ILogger<VddInstaller> log)
{
    public const string ReleasesApi = "https://api.github.com/repos/VirtualDrivers/Virtual-Display-Driver/releases/latest";
    // Pinned fallbacks (latest stable at time of writing: 25.7.23). The "x86" asset name is historical — its INF
    // targets NTamd64 and is the asset the project's own silent installer uses for x64.
    public const string FallbackDriverUrl = "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23/VirtualDisplayDriver-x86.Driver.Only.zip";
    public const string FallbackDriverUrlArm64 = "https://github.com/VirtualDrivers/Virtual-Display-Driver/releases/download/25.7.23/VirtualDisplayDriver-ARM64.Driver.Only.zip";
    public const string NefconUrl = "https://github.com/nefarius/nefcon/releases/download/v1.14.0/nefcon_v1.14.0.zip";

    public sealed record ReleaseAsset(string Tag, string Name, string Url);

    /// Picks the driver-only asset for this CPU from a GitHub release JSON document (unit-tested).
    public static ReleaseAsset? PickAsset(string releaseJson, Architecture arch)
    {
        using var doc = JsonDocument.Parse(releaseJson);
        var tag = doc.RootElement.TryGetProperty("tag_name", out var t) ? t.GetString() ?? "" : "";
        if (!doc.RootElement.TryGetProperty("assets", out var assets)) return null;
        var list = assets.EnumerateArray()
            .Select(a => (Name: a.GetProperty("name").GetString() ?? "", Url: a.GetProperty("browser_download_url").GetString() ?? ""))
            .Where(a => a.Name.EndsWith(".zip", StringComparison.OrdinalIgnoreCase) &&
                        a.Name.Contains("VirtualDisplayDriver", StringComparison.OrdinalIgnoreCase))
            .ToList();
        bool Has(string n, string s) => n.Contains(s, StringComparison.OrdinalIgnoreCase);
        (string Name, string Url) pick;
        if (arch == Architecture.Arm64)
            pick = list.FirstOrDefault(a => Has(a.Name, "ARM64"));
        else
            pick = list.FirstOrDefault(a => Has(a.Name, "x64"))
                   is { Name.Length: > 0 } x64 ? x64
                   : list.FirstOrDefault(a => Has(a.Name, "x86") || (!Has(a.Name, "ARM64")));
        return string.IsNullOrEmpty(pick.Url) ? null : new ReleaseAsset(tag, pick.Name, pick.Url);
    }

    private static HttpClient NewHttp()
    {
        var http = new HttpClient { Timeout = TimeSpan.FromMinutes(5) };
        http.DefaultRequestHeaders.UserAgent.ParseAdd("PlexiChore-Desktop/1.0");
        return http;
    }

    /// Downloads driver + nefcon into %LOCALAPPDATA%\PlexiChore\vdd and returns (driverDir, nefconExe).
    public async Task<(string DriverDir, string NefconExe, string Version)> PrepareAsync(IProgress<string>? progress, CancellationToken ct)
    {
        var arch = RuntimeInformation.OSArchitecture;
        using var http = NewHttp();
        ReleaseAsset? asset = null;
        try
        {
            progress?.Report("Checking latest Virtual Display Driver release…");
            var json = await http.GetStringAsync(ReleasesApi, ct);
            asset = PickAsset(json, arch);
        }
        catch (Exception ex) { log.LogWarning(ex, "GitHub API unavailable, using pinned VDD release"); }
        asset ??= new ReleaseAsset("25.7.23", "pinned", arch == Architecture.Arm64 ? FallbackDriverUrlArm64 : FallbackDriverUrl);

        var root = Path.Combine(AppPaths.VddWorkDir, asset.Tag.Length > 0 ? asset.Tag : "latest");
        if (Directory.Exists(root)) Directory.Delete(root, true);
        Directory.CreateDirectory(root);

        progress?.Report($"Downloading Virtual Display Driver {asset.Tag}…");
        var drvZip = Path.Combine(root, "driver.zip");
        await DownloadAsync(http, asset.Url, drvZip, ct);
        var drvOut = Path.Combine(root, "driver");
        ZipFile.ExtractToDirectory(drvZip, drvOut);
        var inf = Directory.GetFiles(drvOut, "MttVDD.inf", SearchOption.AllDirectories).FirstOrDefault()
                  ?? throw new InvalidDataException("Driver archive does not contain MttVDD.inf.");

        progress?.Report("Downloading device installer (nefcon)…");
        var nefZip = Path.Combine(root, "nefcon.zip");
        await DownloadAsync(http, NefconUrl, nefZip, ct);
        var nefOut = Path.Combine(root, "nefcon");
        ZipFile.ExtractToDirectory(nefZip, nefOut);
        var archDir = arch switch { Architecture.Arm64 => "ARM64", Architecture.X86 => "x86", _ => "x64" };
        var nefcon = Path.Combine(nefOut, archDir, "nefconw.exe");
        if (!File.Exists(nefcon)) throw new InvalidDataException("nefcon archive does not contain nefconw.exe.");
        return (Path.GetDirectoryName(inf)!, nefcon, asset.Tag);
    }

    private static async Task DownloadAsync(HttpClient http, string url, string file, CancellationToken ct)
    {
        using var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, ct);
        resp.EnsureSuccessStatusCode();
        await using var f = File.Create(file);
        await resp.Content.CopyToAsync(f, ct);
    }

    public async Task InstallAsync(IProgress<string>? progress, CancellationToken ct = default)
    {
        var (driverDir, nefcon, ver) = await PrepareAsync(progress, ct);
        // Compact settings with 1 monitor, written BEFORE the device starts (the driver reads them only at start).
        var settingsTmp = WriteCompactSettings();
        progress?.Report("Installing driver (approve the Windows prompt)…");
        await RunScriptAsync("install", $"-DriverDir \"{driverDir}\" -Nefcon \"{nefcon}\" -SettingsXml \"{settingsTmp}\" -SettingsDir \"{VddSettingsFile.DefaultDir}\"", ct);
        log.LogInformation("VDD {Ver} installed", ver);
    }

    public async Task UninstallAsync(IProgress<string>? progress, CancellationToken ct = default)
    {
        string nefcon;
        var cached = Directory.Exists(AppPaths.VddWorkDir)
            ? Directory.GetFiles(AppPaths.VddWorkDir, "nefconw.exe", SearchOption.AllDirectories)
                .FirstOrDefault(p => p.Contains(RuntimeInformation.OSArchitecture == Architecture.Arm64 ? "ARM64" : "x64"))
            : null;
        if (cached != null) nefcon = cached;
        else nefcon = (await PrepareAsync(progress, ct)).NefconExe;
        progress?.Report("Removing driver (approve the Windows prompt)…");
        await RunScriptAsync("uninstall", $"-Nefcon \"{nefcon}\"", ct);
        log.LogInformation("VDD uninstalled");
    }

    /// Builds the compact settings document (presets + user-added tablet modes, existing monitor count/GPU kept,
    /// logging off) from the current file and saves it to the work dir. Returns the temp path.
    internal static string WriteCompactSettings(IEnumerable<(int W, int H)>? extraModes = null)
    {
        Directory.CreateDirectory(AppPaths.VddWorkDir);
        var settingsTmp = Path.Combine(AppPaths.VddWorkDir, "vdd_settings.xml");
        var s = VddSettingsFile.Load(VddSettingsFile.ResolvePath());
        s.Normalize(extraModes ?? VddExtraModes.Load());
        s.Save(settingsTmp);
        return settingsTmp;
    }

    /// `pnputil /restart-device` so the driver re-reads vdd_settings.xml. Elevated. The instance id (e.g.
    /// ROOT\DISPLAY\0000) is looked up by hardware id if not given. NEVER use the pipe's RELOAD_DRIVER instead.
    public async Task RestartDeviceAsync(string? instanceId, CancellationToken ct = default)
    {
        await RunScriptAsync("restart", InstanceArg(instanceId), ct);
    }

    /// Repair: rewrite the compact vdd_settings.xml (fixes "adapter but no monitor" caused by too many modes or
    /// count = 0, resets folder ACL + VDDPATH) and restart the device — one UAC prompt.
    public async Task RepairAsync(string? instanceId, IProgress<string>? progress = null, IEnumerable<(int W, int H)>? extraModes = null,
        CancellationToken ct = default)
    {
        var settingsTmp = WriteCompactSettings(extraModes);
        progress?.Report("Rewriting driver settings and restarting the virtual display (approve the Windows prompt)…");
        await RunScriptAsync("repair", $"{InstanceArg(instanceId)} -SettingsXml \"{settingsTmp}\" -SettingsDir \"{VddSettingsFile.ResolveDirectory()}\"", ct);
        log.LogInformation("VDD repaired (compact settings + device restart)");
    }

    private static string InstanceArg(string? instanceId) =>
        string.IsNullOrWhiteSpace(instanceId) ? "" : $"-InstanceId \"{instanceId}\"";

    private async Task RunScriptAsync(string action, string args, CancellationToken ct)
    {
        Directory.CreateDirectory(AppPaths.VddWorkDir);
        var script = Path.Combine(AppPaths.VddWorkDir, "plexichore-vdd.ps1");
        var result = Path.Combine(AppPaths.VddWorkDir, $"result-{Guid.NewGuid():N}.txt");
        await File.WriteAllTextAsync(script, Script, ct);
        int code;
        try
        {
            code = await Elevation.RunElevatedPowerShellAsync(script, $"-Action {action} {args} -ResultFile \"{result}\"",
                TimeSpan.FromMinutes(3), ct);
        }
        finally { try { File.Delete(script); } catch { } }
        var text = File.Exists(result) ? (await File.ReadAllTextAsync(result, ct)).Trim() : "";
        try { File.Delete(result); } catch { }
        log.LogInformation("VDD script {Action} exit {Code}: {Text}", action, code, text);
        if (code != 0 || !text.StartsWith("OK", StringComparison.Ordinal))
            throw new InvalidOperationException(text.Length > 0 ? text.Replace("ERROR:", "").Trim() : $"Driver {action} failed (exit code {code}).");
    }

    /// Elevated helper. Kept in-process as a string so it always matches this app version.
    internal const string Script = """
param(
  [Parameter(Mandatory=$true)][ValidateSet('install','uninstall','restart','repair')][string]$Action,
  [string]$DriverDir, [string]$Nefcon, [string]$SettingsXml, [string]$SettingsDir = 'C:\VirtualDisplayDriver',
  [string]$InstanceId, [Parameter(Mandatory=$true)][string]$ResultFile
)
$ErrorActionPreference = 'Stop'
$ClassGuid = '{4d36e968-e325-11ce-bfc1-08002be10318}'
function Done($msg, $code) { Set-Content -Path $ResultFile -Value $msg -Encoding UTF8; exit $code }
# Settings folder the driver reads (C:\VirtualDisplayDriver), writable by Users. Written BEFORE the device (re)starts:
# the driver only reads vdd_settings.xml at device start.
function Write-Settings {
  New-Item -ItemType Directory -Force -Path $SettingsDir | Out-Null
  if ($SettingsXml -and (Test-Path $SettingsXml)) { Copy-Item -Force $SettingsXml (Join-Path $SettingsDir 'vdd_settings.xml') }
  & icacls.exe $SettingsDir /grant '*S-1-5-32-545:(OI)(CI)M' /T /C /Q | Out-Null
  New-Item -Path 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver' -Force | Out-Null
  Set-ItemProperty -Path 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver' -Name 'VDDPATH' -Value $SettingsDir
}
function Find-Instance {
  if ($InstanceId) { return $InstanceId }
  $d = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' } | Select-Object -First 1
  if (-not $d) { throw 'The Virtual Display Driver device was not found. Install the driver first.' }
  return $d.InstanceId
}
# Restart the device so the driver re-reads its settings. (Never the pipe's RELOAD_DRIVER: it crashes WUDFHost.)
function Restart-Vdd($id) {
  $p = Start-Process -FilePath 'pnputil.exe' -ArgumentList @('/restart-device', "`"$id`"") -Wait -PassThru -WindowStyle Hidden
  if ($p.ExitCode -ne 0) {
    Disable-PnpDevice -InstanceId $id -Confirm:$false
    Start-Sleep -Milliseconds 800
    Enable-PnpDevice -InstanceId $id -Confirm:$false
  }
  $dev = Get-PnpDevice -InstanceId $id -ErrorAction SilentlyContinue
  if ($dev -and $dev.Problem -eq 'CM_PROB_DISABLED') { Enable-PnpDevice -InstanceId $id -Confirm:$false }
}
try {
  switch ($Action) {
    'install' {
      $cat = Get-ChildItem -Path $DriverDir -Filter '*.cat' | Select-Object -First 1
      if (-not $cat) { throw "Driver catalog (.cat) not found in $DriverDir" }
      $sig = Get-AuthenticodeSignature -FilePath $cat.FullName
      if ($sig.Status -in @('NotSigned','HashMismatch','Incompatible')) { throw "Driver catalog signature check failed ($($sig.Status))." }
      # Trust the publisher (end-entity) certificates embedded in the catalog, as the project's silent-install.ps1
      # does, so Windows does not show an extra "install this device software?" prompt.
      $certs = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2Collection
      $certs.Import([System.IO.File]::ReadAllBytes($cat.FullName))
      $store = New-Object System.Security.Cryptography.X509Certificates.X509Store('TrustedPublisher','LocalMachine')
      $store.Open('ReadWrite')
      foreach ($c in $certs) {
        $bc = $c.Extensions | Where-Object { $_.Oid.Value -eq '2.5.29.19' }
        if (-not $bc -or -not $bc.CertificateAuthority) { $store.Add($c) }
      }
      $store.Close()

      Write-Settings

      $existing = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
      $inf = Join-Path $DriverDir 'MttVDD.inf'
      if ($existing) {
        $p = Start-Process -FilePath 'pnputil.exe' -ArgumentList @('/add-driver', "`"$inf`"", '/install') -Wait -PassThru -WindowStyle Hidden
        if ($p.ExitCode -eq 0 -or $p.ExitCode -eq 3010) { Restart-Vdd ($existing | Select-Object -First 1).InstanceId }
      } else {
        $p = Start-Process -FilePath $Nefcon -ArgumentList @('install', "`"$inf`"", 'Root\MttVDD') -WorkingDirectory $DriverDir -Wait -PassThru -WindowStyle Hidden
      }
      if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "Driver installation failed (exit code $($p.ExitCode))." }
      Start-Sleep -Seconds 3
      $dev = Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' }
      if (-not $dev) { throw 'Driver installed but the virtual display device was not created.' }
      Done "OK installed $($dev.InstanceId)" 0
    }
    'uninstall' {
      $p = Start-Process -FilePath $Nefcon -ArgumentList @('--remove-device-node', '--hardware-id', 'Root\MttVDD', '--class-guid', $ClassGuid) -Wait -PassThru -WindowStyle Hidden
      Get-PnpDevice -ErrorAction SilentlyContinue | Where-Object { $_.HardwareID -contains 'Root\MttVDD' } | ForEach-Object {
        & pnputil.exe /remove-device $_.InstanceId | Out-Null
      }
      Get-WindowsDriver -Online -ErrorAction SilentlyContinue | Where-Object { $_.OriginalFileName -like '*mttvdd.inf' } | ForEach-Object {
        & pnputil.exe /delete-driver $_.Driver /uninstall /force | Out-Null
      }
      Done "OK uninstalled (nefcon exit $($p.ExitCode))" 0
    }
    'restart' {
      $id = Find-Instance
      Restart-Vdd $id
      Done "OK restarted $id" 0
    }
    'repair' {
      $id = Find-Instance
      Write-Settings
      Restart-Vdd $id
      Done "OK repaired $id" 0
    }
  }
} catch {
  Done ("ERROR: " + $_.Exception.Message) 1
}
""";
}
