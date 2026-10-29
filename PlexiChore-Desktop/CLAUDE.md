# CLAUDE.md — PlexiChore Desktop (Windows host)

Read `../CLAUDE.md` and `../PROTOCOL.md` first. Human docs: `README.md`, `driver/README.md`.

## Build / test / run
- .NET 10 SDK, Windows 10 1809+ (tested 19045). No Visual Studio needed.
- `dotnet build PlexiChore.slnx -m:1` · `dotnet test PlexiChore.slnx` (111 tests at last count).
- If the running app locks DLLs in `bin\`, build elsewhere: `dotnet build PlexiChore.slnx --artifacts-path <scratch>`.
- Publish: `powershell -File publish.ps1` → `dist\PlexiChore.exe` (self-contained single file, uncompressed + ReadyToRun, ~229 MB; first start after publish self-extracts and can take ~30 s). Kill the old exe first (`taskkill /F /IM PlexiChore.exe` — a graceful close only hides it to the tray).
- Logs: `%LOCALAPPDATA%\PlexiChore\logs\plexichore-YYYYMMDD.log`. Settings: `%APPDATA%\PlexiChore\settings.json` (HostId, trusted devices). Primary-mode crash-restore record: `%APPDATA%\PlexiChore\primary-restore.json`. Native crashes never reach our log: check Event Viewer (Application, IDs 1000/1026); on the dev PC WER LocalDumps writes full dumps to `%LOCALAPPDATA%\PlexiChore\CrashDumps` (HKLM `...\Windows Error Reporting\LocalDumps\PlexiChore.exe`, 3 kept).
- Debug-only demo UI: env `PLEXICHORE_DEMO_UI=1`.

## Projects
- `src/PlexiChore.Engine` — streaming core. `PlexiServer.cs` (TCP/UDP, sessions, pairing), `Protocol/`, `Streaming/` (`Session.cs` + `Session.Scale.cs`, `SessionSender.cs` backpressure, `StreamPipeline.cs` capture→cursor→scale/NV12→encode with adaptive seamless downscale and steady-cadence fallback, `VirtualDisplayLeases.cs` ref-counted attach with grace period, `Warmup.cs`), `Capture/` (DXGI Desktop Duplication, `DevicePool.cs` pooled D3D11 device, `GpuCursor.cs`/`CursorOverlay.cs` DDA pointer compositing), `Encoding/MfH264Encoder.cs` (Media Foundation HW MFT async D3D11, SW fallback), `MjpegEncoder.cs`, `Input/InputInjector.cs` (synthetic pointer touch/pen, SendInput mouse), `Discovery/`, `DisplayScale.cs`, `Diagnostics/EncoderProbe.cs`.
- `src/PlexiChore.App` — WPF tray app (WPF-UI 4, H.NotifyIcon). `Services/` (ServerHost, Adb/AdbManager — applies `adb reverse` preferring the USB transport, Firewall, Startup, SingleInstance, Settings, FileLogger), `VirtualDisplay/` (`VirtualDisplayDriverProvider.cs` implements `IVirtualDisplayProvider` incl. primary + DPI scale, `VddInstaller.cs` elevated install/repair/uninstall script, `VddSettingsFile.cs` capped preset modes, `VddPipeClient.cs` PING/GETSETTINGS only, `DisplayNative.cs` interop, `PrimaryDisplayRestore.cs`), `ViewModels/`, `Views/` (MainWindow, PairingWindow, Pages: Home, Display, USB, Settings, About), `Themes/PlexiTheme.xaml`. `app.manifest` must stay PerMonitorV2 DPI aware (input mapping depends on it).
- `tests/PlexiChore.App.Tests` — xunit.
- `tools/EngineHost` (standalone server: `--port --discovery-port --approve --sw --verbose --encbench`), `tools/EngineTestClient` (fake tablet, validates H.264/JPEG), `tools/FakeHost` (fake host for Android testing), `tools/Bench` (smoothness benchmark: `bench.ps1 -Preflight | -Scenario usb-mirror,usb-extend,wifi-direct-extend,usb-primary,... | -All [-Seconds 15]`; results in `tools/Bench/results/results.md`). Set `PLEXI_USB_SERIAL` (cable serial from `adb devices`) and `PLEXI_WIRELESS_SERIAL` (the `adb-<serial>-xxxx._adb-tls-connect._tcp` entry) before running.
- Diagnostic env vars (off by default): `PLEXI_LATLOG`, `PLEXI_GPUTIME`, `PLEXI_CPU_CURSOR`, `PLEXI_MAXW`, `PLEXI_FORCE_STEADY`, `PLEXI_ENC`.
- `installer/PlexiChore.iss` — Inno Setup script (not compiled yet). `driver/README.md` — VDD integration and findings.

## Virtual Display Driver (Extend/Primary) — must-know
- Signed open-source MttVDD (github.com/VirtualDrivers/Virtual-Display-Driver, 25.7.23), installed by the app (download + one UAC). Settings file `C:\VirtualDisplayDriver\vdd_settings.xml` (path from `HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver\VDDPATH`).
- Pipe `\\.\pipe\MTTVirtualDisplayPipe`: only PING/GETSETTINGS; post the read before writing. `RELOAD_DRIVER` & friends crash the driver host.
- Mode list: 19 presets (16 landscape + 3 portrait) @60 Hz, hard caps 24 resolutions / 48 generated modes; too many modes → `IddCxMonitorArrival` fails 0xC00000BB (no monitor). Mode changes require *Repair* (elevated `pnputil /restart-device`).
- Monitor stays connected; sessions attach/detach it via ChangeDisplaySettingsEx/SetDisplayConfig (no admin). Its GDI name changes after driver restarts (`\\.\DISPLAY7` → `8` → `9`) — always look it up.
- DPI scale via undocumented DisplayConfig{Get,Set}DeviceInfo types -3/-4, only while attached.

## Status / next
Working and benchmarked (see `../ROADMAP.md`). Next: installer compile + code signing, CI, rotation re-attach skip, Wi-Fi pacing re-bench, keyboard forwarding.
