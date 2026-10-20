<#
.SYNOPSIS
  PlexiChore smoothness benchmark: {usb, wireless-adb, wifi-direct} x {mirror, extend}.

.DESCRIPTION
  Wrapper around tools\Bench (Bench.exe). For each scenario it
    1. pins the transport (adb reverse tcp:47800 owned by the cable or by wireless debugging; wifi-direct dials the
       PC LAN IP) and checks Windows Firewall read-only,
    2. force-stops the tablet app and starts DebugDisplay via `am start`, timing am start -> HELLO -> CONFIG (engine
       log) -> first decoded frame (tablet logcat, clock-synced over a persistent adb shell),
    3. drives motion on the captured monitor (125 Hz SetCursorPos circles, then a 60 fps full-screen animation),
    4. polls `dumpsys SurfaceFlinger --latency <PlexiChore SurfaceView>` to get real presentation times on the tablet
       -> fps, frame-interval p50/p95/p99/max, stutters (>2x 16.7 ms), janks (>1.5x),
       plus engine `perf:` lines, "Encoder busy" drops, gfxinfo and a screencap of the stats overlay,
    5. appends a markdown row per (scenario, motion) to tools\Bench\results\results.md (+ result.json, raw dumps).

  Needs PlexiChore Desktop running (extend needs it for the virtual display). Wi-Fi sessions need approval in the
  desktop app unless the tablet is trusted; the harness beeps and waits up to 90 s.

.EXAMPLE
  .\bench.ps1 -SelfTest
  .\bench.ps1 -Preflight
  .\bench.ps1 -Scenario usb-mirror -Seconds 15
  .\bench.ps1 -All -Taps 10
#>
[CmdletBinding()]
param(
    [ValidateSet('usb-mirror', 'usb-extend', 'wireless-adb-mirror', 'wireless-adb-extend', 'wifi-direct-mirror', 'wifi-direct-extend', 'usb-primary')]
    [string[]]$Scenario,
    [switch]$All,
    [double]$Seconds = 15,
    [string]$Motions = 'cursor,anim',
    [int]$Taps = 0,
    [string]$HostIp = '192.168.0.132',
    [switch]$Preflight,
    [switch]$SelfTest,
    [switch]$Rebuild
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$exe = Join-Path $here 'bin\Release\net10.0-windows\Bench.exe'

if ($Rebuild -or -not (Test-Path $exe) -or
    (Get-ChildItem $here -Filter *.cs | Where-Object { $_.LastWriteTime -gt (Get-Item $exe).LastWriteTime })) {
    Write-Host 'building Bench (Release)...'
    & dotnet build (Join-Path $here 'Bench.csproj') -c Release --disable-build-servers -nologo -v q
    if ($LASTEXITCODE -ne 0) { throw 'build failed' }
}

if ($SelfTest) { & $exe selftest; exit $LASTEXITCODE }
if ($Preflight) { & $exe preflight; exit $LASTEXITCODE }

$order = 'usb-mirror', 'usb-extend', 'wireless-adb-mirror', 'wireless-adb-extend', 'wifi-direct-mirror', 'wifi-direct-extend', 'usb-primary'
$list = if ($All) { $order } elseif ($Scenario) { $Scenario } else { throw 'pass -Scenario <name>, -All, -Preflight or -SelfTest' }

$failed = @()
foreach ($s in $list) {
    $mode = ($s -split '-')[-1]
    $transport = $s.Substring(0, $s.Length - $mode.Length - 1)
    Write-Host "`n================ $transport / $mode ================" -ForegroundColor Cyan
    $a = @('run', '--transport', $transport, '--mode', $mode, '--seconds', "$Seconds", '--motions', $Motions, '--host-ip', $HostIp)
    if ($Taps -gt 0) { $a += @('--taps', "$Taps") }
    & $exe @a
    if ($LASTEXITCODE -ne 0) { $failed += $s }
    # extend/primary keep the virtual display attached for a ~10 s grace period: wait it out so the next run is a cold attach
    if ($mode -ne "mirror") { Start-Sleep -Seconds 14 } else { Start-Sleep -Seconds 3 }
}

Write-Host "`n================ summary ================" -ForegroundColor Cyan
& $exe table (Join-Path $here 'results')
if ($failed.Count) { Write-Warning "scenarios with errors: $($failed -join ', ')"; exit 1 }
