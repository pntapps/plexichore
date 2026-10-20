# Extended display driver

PlexiChore's **Extend** mode needs Windows to believe a second monitor is plugged in, so the tablet can show
desktop space that is not on your main screen. On Windows 10/11 that requires an **Indirect Display Driver
(IddCx)**. PlexiChore does not ship its own driver. It uses the signed, open-source
**[Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)** (VDD) by VirtualDrivers
(MikeTheTech, Bud and contributors), MIT licence.

## Why not a custom driver?

| | Custom PlexiChore IddCx driver | Signed VDD (what we use) |
|---|---|---|
| Build toolchain | Visual Studio + Windows Driver Kit (WDK), C++ | none: we download the published release |
| Signing | An EV code-signing certificate **plus** Microsoft attestation signing through the Partner Center hardware dashboard. Without it, Windows 10/11 x64 refuses to load the driver unless test-signing mode is on (`bcdedit /set testsigning on`, which shows a watermark and weakens security) | Already signed by the project (SignPath Foundation code signing, catalog `mttvdd.cat`) |
| Maintenance | We would own the IddCx swap-chain, EDID, mode-list and HDR code, and Windows-update regressions | Maintained upstream; we pin a known release and can upgrade |
| Features we need | Same as VDD | Configurable monitor count, custom resolutions and refresh rates (`vdd_settings.xml`), control pipe, HDR, cursor |

A custom driver only becomes worth it if PlexiChore later needs things VDD can't do, such as zero-copy frame
hand-off from the driver to the encoder. Today the Engine captures the virtual monitor like any other output
(DXGI Desktop Duplication on the GDI name we return), so a generic virtual monitor is enough.

## How PlexiChore installs it

Everything below happens only after you click **Install driver** on the *Extended display* page. You get one
UAC prompt.

1. **Download (unelevated)** into `%LOCALAPPDATA%\PlexiChore\vdd\<tag>\`:
   * The driver-only asset of the latest release, found through
     `https://api.github.com/repos/VirtualDrivers/Virtual-Display-Driver/releases/latest`.
     For release `25.7.23` this is `VirtualDisplayDriver-x86.Driver.Only.zip`. Despite the name, its INF targets
     `NTamd64`, and it is the asset the project's own `Community Scripts/silent-install.ps1` uses on x64.
     ARM64 uses `VirtualDisplayDriver-ARM64.Driver.Only.zip`. If GitHub is unreachable, the 25.7.23 URLs are
     used as a fallback.
   * [nefcon](https://github.com/nefarius/nefcon) `v1.14.0` (BSD-3-Clause), the same version the VDD script pins.
2. **Elevated PowerShell** (generated from `VddInstaller.Script`):
   * checks that `mttvdd.cat` is signed, then imports its publisher (end-entity) certificate into
     `LocalMachine\TrustedPublisher`, as `silent-install.ps1` does, so Windows doesn't show a second
     "install this device software?" prompt.
   * writes `C:\VirtualDisplayDriver\vdd_settings.xml` **before the device starts** (the driver reads it only at
     device start): **1 monitor**, the compact tablet mode list below, logging off, plus the `<cursor>` and
     `<colour>` blocks. It grants *Users* modify rights on that folder and sets
     `HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver\VDDPATH`.
   * runs `nefconw install MttVDD.inf Root\MttVDD`. This creates the root-enumerated device node and installs
     the driver, the same command the upstream script uses. If the device already exists, it runs
     `pnputil /add-driver MttVDD.inf /install` and then restarts the device.
3. Windows extends the desktop onto the new monitor straight away. PlexiChore then **detaches it** until a tablet
   asks for Extend mode.

**Uninstall** runs `nefconw --remove-device-node --hardware-id Root\MttVDD --class-guid {4d36e968-e325-11ce-bfc1-08002be10318}`.
It then deletes any remaining `mttvdd.inf` package from the driver store (`pnputil /delete-driver … /uninstall /force`).

**Restart** runs `pnputil /restart-device "<instance id>"` elevated. The instance id (for example `ROOT\DISPLAY\0000`)
is looked up by hardware id `Root\MttVDD`. If pnputil fails, it falls back to `Disable-/Enable-PnpDevice`.

**Repair** rewrites the compact `vdd_settings.xml` and restarts the device, with one UAC prompt. It keeps the monitor
count (minimum 1), the GPU choice, unknown elements and any resolutions you added. If the driver files themselves
are missing or broken (problem codes 28, 31, 52 and similar), it reinstalls instead.

## Findings (verified on Windows 10 19045, IddCx 0x1501, VDD 25.7.23)

1. **Never send reload commands over the pipe.** `RELOAD_DRIVER` crashes the driver host (WUDFHost access
   violation): `ReloadDriver` passes the pipe HANDLE to `WdfObjectGet_IndirectDeviceContextWrapper`. Every command
   that ends in `ReloadDriver` crashes it the same way: `SETDISPLAYCOUNT`, `SETGPU`, `HDRPLUS`, `SDR10`,
   `CUSTOMEDID`, `PREVENTSPOOF`, `CEAOVERRIDE` and `HARDWARECURSOR`. `VddPipeClient` only allows `PING` and
   `GETSETTINGS`, and refuses everything else before it connects. The settings (count, resolutions, refresh rates)
   are read only at device start, so changing them needs an elevated device restart.
2. **Too many modes break monitor creation.** Each `<g_refresh_rate>` is multiplied across *all* unique
   resolutions, and each `<resolution>` adds its own mode. With 28 resolutions × 5 global rates (about 140+
   modes), `IddCxMonitorArrival` fails with `0xC00000BB` (`STATUS_NOT_SUPPORTED`, upstream issue #254). The
   adapter starts but **no monitor** appears. 16 resolutions at 60 Hz (32 generated modes) works. PlexiChore
   therefore writes exactly this list, each at `<refresh_rate>60</refresh_rate>`, with a single
   `<g_refresh_rate>60</g_refresh_rate>`:

   `2560x1600 1920x1200 1280x800 2880x1800 2000x1200 2400x1600 3000x2000 2732x2048 2048x1536 1600x1000 2560x1440
   1920x1080 1366x768 2800x1752 2960x1848 1440x900` plus three portrait modes for tablets held upright:
   `1600x2560 1200x1920 1752x2800` (19 resolutions, 38 generated modes). Without a portrait mode a portrait tablet
   gets the landscape desktop and a "rotate" hint (`DisplayLayout.OrientForModes`). Existing installs pick up the
   portrait presets after **Repair** (one UAC prompt).

   `VddSettingsFile` enforces a hard cap: at most **24** `<resolution>` entries, **2** global rates, and **48**
   generated modes (entries + unique resolutions × global rates).
3. **Write every setting the driver reads.** Missing integer values are read as -1. PlexiChore writes:
   ```xml
   <options> CustomEdid/PreventSpoof/EdidCeaOverride=false, HardwareCursor=true, SendLogsThroughPipe=false,
             SDR10bit=false, HDRPlus=false, logging=false, debuglogging=false </options>
   <cursor><HardwareCursor>true</HardwareCursor><CursorMaxX>128</CursorMaxX><CursorMaxY>128</CursorMaxY>
           <AlphaCursorSupport>true</AlphaCursorSupport><XorCursorSupportLevel>2</XorCursorSupportLevel></cursor>
   <colour><SDR10bit>false</SDR10bit><HDRPlus>false</HDRPlus><ColourFormat>RGB</ColourFormat></colour>
   ```
4. **Pipe protocol** (`\.\pipe\MTTVirtualDisplayPipe`, ACL *Everyone*): one command per connection, UTF-16LE,
   message mode, no terminator. The driver writes its reply and immediately calls `DisconnectNamedPipe` without
   flushing, which discards any unread reply. The client must therefore **post an overlapped read before writing
   the command**. `PING` returns `PONG` as 4 ANSI bytes. `GETSETTINGS` returns UTF-16 `SETTINGS DEBUG=.. LOG=..`.
   The pipe is used only for health checks.
5. **The monitor stays connected permanently.** A session attaches the monitor to the desktop or detaches it with
   `ChangeDisplaySettingsEx`/`SetDisplayConfig`, which needs no admin. Windows auto-extends onto the monitor
   whenever it arrives (install, device restart, reboot), so PlexiChore detaches it when no tablet is using it:
   after install, Repair and Restart, at app start, and whenever the status poll sees the monitor (re)appear.
6. **Changing the resolution list or the monitor count needs an elevated device restart**
   (`pnputil /restart-device`).

## How Extend mode drives it at runtime (no admin)

`VirtualDisplayDriverProvider.AttachAsync(width, height, hz, position[, makePrimary])`:

1. Finds the VDD source among the GDI displays (`EnumDisplayDevices`, plus the `QueryDisplayConfig` adapter or
   monitor path). It **does not** edit `vdd_settings.xml` or ask the driver to reload.
2. Chooses the best available mode: exact size (closest refresh rate), then the same aspect ratio with the
   largest area that does not exceed the request, then any mode that fits (largest), and otherwise the closest
   area (same aspect preferred). The Engine scales the stream. The fallback is logged and shown on the
   *Extended display* page. There, **Add this tablet's exact resolution** adds the mode (within the cap, stored in
   `%LOCALAPPDATA%\PlexiChore\vdd-extra-modes.json` so Repair keeps it) and restarts the device, with one UAC prompt.
3. Places the monitor next to the primary display on the requested side (`right|left|top|bottom`, centred on the
   shared edge, pushed outward past any other monitor). It applies this with
   `ChangeDisplaySettingsEx(CDS_UPDATEREGISTRY|CDS_NORESET)` followed by a global apply. If that fails, it retries
   once after `SetDisplayConfig(SDC_TOPOLOGY_EXTEND)`.
4. In *Primary* mode, it saves the original layout (`%APPDATA%\PlexiChore\primary-restore.json`) and shifts all
   monitors so the virtual one becomes primary at (0,0). The layout is restored on detach, or at the next start
   after a crash.
5. Returns `VirtualMonitor(\.\DISPLAYn, bounds)` in physical virtual-desktop pixels (the app is
   per-monitor-DPI-aware v2).

`DetachAsync` removes the monitor from the desktop (0×0 mode), so Windows moves windows back to the main screen.
Monitors the app attached are recorded in `%LOCALAPPDATA%\PlexiChore\vdd-state.json` and detached again at the
next start if the app crashed.

## Health status

The status poll (every 15 s) checks two things: the PnP device (`Root\MttVDD`, problem code), and whether the
adapter has a monitor. The monitor counts as present if a GDI child monitor exists under a VDD source, or if
`QueryDisplayConfig(QDC_ALL_PATHS)` reports an available target on the VDD adapter. If the adapter runs but has no
monitor, the status is **Needs repair**: *"Virtual monitor didn't start — click Repair (admin)"*.

## Testing the install manually

To test on a machine you control:

1. Run PlexiChore, open **Extended display**, click **Install driver**, and approve UAC.
   Expected: the status changes to *Virtual display ready*, Device Manager shows *Display adapters → Virtual
   Display Driver*, and Settings → Display briefly shows a second screen and then reverts (detached).
2. Check from PowerShell:
   ```powershell
   Get-PnpDevice | ? { $_.HardwareID -contains 'Root\MttVDD' }     # Status OK
   Get-Content C:\VirtualDisplayDriver\vdd_settings.xml              # count=1, 19 resolutions @60 Hz (16 landscape + 3 portrait), one g_refresh_rate
   ```
3. Connect a tablet in Extend mode. A new display appears to the right of the primary one at the tablet's
   resolution, or at the closest preset. Disconnect it and the display goes away.
   If the page says **Needs repair**, click **Repair** and approve UAC.
4. **Uninstall** removes the device (`Get-PnpDevice` returns nothing).
   Logs: `%LOCALAPPDATA%\PlexiChore\logs\plexichore-yyyyMMdd.log`.

## License attribution

Virtual Display Driver, Copyright (c) VirtualDrivers / MikeTheTech and contributors, is distributed under the
MIT License: <https://github.com/VirtualDrivers/Virtual-Display-Driver/blob/master/LICENSE>.
nefcon, Copyright (c) Benjamin Höglinger-Stelzer, is distributed under the BSD-3-Clause License:
<https://github.com/nefarius/nefcon/blob/master/LICENSE>.
PlexiChore downloads both from their official GitHub releases at install time and does not redistribute modified
copies.
