<#
.SYNOPSIS
  Builds a self-contained, single-file win-x64 PlexiChore Desktop into .\dist\ (and optionally the Inno Setup installer).
.EXAMPLE
  .\publish.ps1                 # dist\PlexiChore.exe
  .\publish.ps1 -Installer      # also runs ISCC (Inno Setup 6) if installed -> dist\PlexiChoreSetup-<ver>.exe
  .\publish.ps1 -Runtime win-arm64
#>
param(
    [string]$Runtime = 'win-x64',
    [string]$Configuration = 'Release',
    [switch]$Installer
)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$proj = Join-Path $root 'src\PlexiChore.App\PlexiChore.App.csproj'
$dist = Join-Path $root 'dist'
$stage = Join-Path $root "artifacts\publish\$Runtime"

if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
New-Item -ItemType Directory -Force -Path $dist | Out-Null

Write-Host "Publishing $proj ($Runtime, $Configuration)..." -ForegroundColor Cyan
# No compression: the runtime then maps the bundled assemblies straight from the exe (file-backed pages Windows can
# drop and re-read) instead of inflating ~150 MB into private memory that must go to the pagefile on a busy 8 GB PC.
# ReadyToRun: precompiled code, so the first tablet connection does not JIT under memory pressure.
& dotnet publish $proj -c $Configuration -r $Runtime --self-contained true `
    -p:PublishSingleFile=true `
    -p:IncludeNativeLibrariesForSelfExtract=true `
    -p:EnableCompressionInSingleFile=false `
    -p:DebugType=embedded `
    -p:PublishReadyToRun=true `
    -o $stage
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed ($LASTEXITCODE)" }

Copy-Item (Join-Path $stage 'PlexiChore.exe') (Join-Path $dist 'PlexiChore.exe') -Force
# Any non-embeddable native files (normally none) are copied alongside.
Get-ChildItem $stage -File | Where-Object { $_.Name -ne 'PlexiChore.exe' -and $_.Extension -in '.dll', '.json' } |
    ForEach-Object { Copy-Item $_.FullName $dist -Force }

$exe = Get-Item (Join-Path $dist 'PlexiChore.exe')
Write-Host ("Built {0} ({1:N1} MB)" -f $exe.FullName, ($exe.Length / 1MB)) -ForegroundColor Green

if ($Installer) {
    $iscc = @(
        "${env:ProgramFiles(x86)}\Inno Setup 6\ISCC.exe",
        "$env:ProgramFiles\Inno Setup 6\ISCC.exe",
        "$env:LOCALAPPDATA\Programs\Inno Setup 6\ISCC.exe"
    ) | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $iscc) { throw 'Inno Setup 6 (ISCC.exe) not found. Install it from https://jrsoftware.org/isdl.php' }
    # ProductVersion carries the commit ("1.1.0+<sha>"); the installer name/version uses the plain version
$ver = ((Get-Item (Join-Path $dist 'PlexiChore.exe')).VersionInfo.ProductVersion -split '\+')[0]
    & $iscc "/DAppVersion=$ver" "/DDistDir=$dist" (Join-Path $root 'installer\PlexiChore.iss')
    if ($LASTEXITCODE -ne 0) { throw "ISCC failed ($LASTEXITCODE)" }
}
