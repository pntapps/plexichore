# PlexiChore — status, what's left, known limits

Last updated: 2026-10-21 (end of the first build session on the Windows dev PC).

## Done and verified on real hardware
(Galaxy Tab S8 SM-X700 / Android 16, Windows 10 Pro 19045, NVIDIA GeForce GT 710, 8 GB RAM)

- Mirror, Extend, Primary modes end-to-end over USB (adb reverse), wireless adb and direct Wi-Fi.
- Portrait rotation → real 1600×2560 portrait virtual monitor (~0.3 s switch).
- Auto per-monitor DPI scale (200 % on Tab S8) + Display size setting, applied live.
- Primary mode restores the original Windows primary/layout on disconnect (also after a crash, via `%APPDATA%\PlexiChore\primary-restore.json`).
- Touch → cursor mapping exact (letterbox-aware), touch-as-mouse mode.
- Cursor composited from DDA pointer shape, DPI-correct size.
- Seamless adaptive encode downscale (2560×1600 → 1920×1200 under sustained full motion, back when calm).
- Connect: ~0.4–1 s tap-to-picture; 8–10 s virtual-display grace period for instant reconnect.
- Virtual Display Driver install/repair/uninstall from the app; health status "Needs repair".
- Android UI: onboarding, Home (merged host cards, mode-aware hero animation), Settings, Help, pairing/connecting overlays, light/dark, adaptive layouts; screenshot-test matrix (Roborazzi, 14 device configs).
- Compatibility work: Android 17 `ACCESS_LOCAL_NETWORK`, taskbar insets, decoder capability negotiation + fallback chain, portrait/viewport, VPN/LAN binding, subnet discovery sweep (details: `PlexiChore/COMPATIBILITY.md`).

Benchmarks: `PlexiChore-Desktop/tools/Bench/results/results.md` (raw per-run folders are not committed — they contain desktop screenshots).

## What's left (prioritized)

### P0 — next steps
1. **macOS host: first compile + test on a MacBook.** `PlexiChore-Mac` was written on Windows and never built. Expect small compile errors. Most likely spots (per its author): `@MainActor` AppDelegate `init()` override, `CFArray as NSArray?` cast in `H264Encoder.isKeyframe`, `Text.tracking` on macOS 13, `-fobjc-arc` unsafe flag for the ObjC target. Then verify: CGVirtualDisplay (private API) appears/positions/disappears, HiDPI mode, ScreenCaptureKit permission flow, VideoToolbox output decodes on the tablet (the Mac sends SPS/PPS as a separate VIDEO packet with flags=0x02 — Android handles this), CGEvent input/scroll direction, `adb reverse` with Homebrew adb, SMAppService login item. **Bring the Mac host up to parity with newer protocol fields** (see "Protocol fields the Mac host doesn't implement yet" in `PlexiChore-Mac/CLAUDE.md`).
2. **Release readiness**
   - Android release build: signing config + keystore (keep secrets out of git), R8 rules check (`app/src/main/keepRules/rules.keep`), `versionCode`/`versionName`, Play Store listing assets, privacy policy (local network + no data collection).
   - Replace placeholder download link `pntapps.com/plexichore` in `PlexiChore/app/src/main/res/values/strings.xml`.
   - Windows installer: compile `PlexiChore-Desktop/installer/PlexiChore.iss` with Inno Setup 6; consider code-signing the exe (SmartScreen).
   - CI (GitHub Actions): Android assemble + unit tests; `dotnet build/test` on windows-latest; `swift build` on macos-latest.
3. **Hands-on tests nobody could automate:** S-Pen pressure/tilt/barrel/eraser in a drawing app; 3-finger tap to show controls; USB tethering path (`link: usb-tether`); a second, cheaper Android tablet (MediaTek/Unisoc) for decoder fallback; Android 17 emulator for the local-network permission flow.

### P1
4. Keyboard / touchpad / mouse forwarding from the tablet (protocol has `KEY` 0x05, tablet never sends it yet; no host-side physical-mouse forwarding).
5. Rotation: skip detach/re-attach when the resolved mode is unchanged (~0.4 s blank today); thin black border in portrait (display inset handling in `display/StreamLayout.kt`).
6. Direct Wi-Fi pacing: last bench showed slightly more stutter than an earlier run (noise vs regression unresolved) — re-bench on a quieter machine with `tools/Bench/bench.ps1 -Scenario wifi-direct-mirror,wifi-direct-extend`.
7. Encoder latency spikes 70–170 ms seen occasionally (not root-caused).
8. Gesture-nav back edge while streaming; batched/historical pen samples dropped; launching DisplayActivity from background (Android 10+ BAL restrictions).
9. Localization: most UI strings are hard-coded English in Compose — move to `strings.xml`.

### P2
10. Windows vs macOS laptop glyphs look alike in host cards; Wi-Fi chip contrast; RTL mixed-direction text.
11. Low-RAM buffer pooling on Android; MJPEG path is CPU heavy.
12. Desktop: settings changes (trusted device removal, encoder switch) apply after server restart, which waits for no active session; tray uses classic balloons, not toasts.
13. Multiple tablets at once (each needs its own virtual monitor; one session per monitor is a DDA limit).

## Known limits
- **Weak GPUs** (e.g. GT 710): full-screen motion in extend/primary is ~51–55 fps because Windows' compositor itself can't produce 60 fps on the virtual display while NVENC encodes; the engine downscales to 1920×1200 during sustained motion and has a steady-40 fps fallback. Desktop/cursor work is ~60 fps.
- **adb reverse** (USB debugging / wireless debugging) bunches frames; the tablet's adaptive frame pacer smooths it at the cost of up to ~1–2 frames. Direct Wi-Fi on a good network or USB tethering avoid adb.
- **Virtual Display Driver (MttVDD 25.7.23)**: never send `RELOAD_DRIVER`/`SETDISPLAYCOUNT`/option toggles over its pipe (crashes WUDFHost); more than ~100 generated modes makes monitor arrival fail (0xC00000BB); mode-list changes need an elevated device restart (*Repair*). Details: `PlexiChore-Desktop/driver/README.md`.
- UAC / lock screen (secure desktop) can't be captured without SYSTEM rights; the last frame is shown meanwhile.
- Rotated (portrait) *physical* monitors and HDR desktops aren't handled in mirror mode.
- macOS host uses the private `CGVirtualDisplay` API → not App Store eligible.

## Cleanup items on the original dev machine / test tablet
- Tablet screen-off timeout was set to 30 min by a test agent (original value unknown) — reset in Settings → Display.
- The test tablet was added to the PC app's trusted devices by automation during testing (remove under Settings → Trusted devices if unwanted).
- Virtual Display Driver is installed on the dev PC (Uninstall from *Extended display* page if desired).
