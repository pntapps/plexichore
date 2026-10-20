# PlexiChore

Turn any Android tablet into a portable monitor for a Windows PC or a Mac — as a **second (extended) display**, as the computer's **primary display**, or as a **mirror** of an existing screen. Touch and S-Pen input are sent back to the computer.

```
┌──────────────┐   H.264 video (TCP 47800)   ┌──────────────┐
│  Windows/Mac │ ──────────────────────────▶ │   Android    │
│  host app    │ ◀────────────────────────── │   tablet app │
└──────────────┘   touch / pen / settings    └──────────────┘
     USB cable (adb reverse or USB tethering) · Wi-Fi (UDP 47801 discovery)
```

## Repository layout

| Folder | What | Status |
|---|---|---|
| [`PlexiChore/`](PlexiChore) | Android tablet app (Kotlin, Jetpack Compose, Material 3) | ✅ Working, tested on Galaxy Tab S8 |
| [`PlexiChore-Desktop/`](PlexiChore-Desktop) | Windows host: .NET 10 WPF tray app + streaming engine + tools | ✅ Working, tested on Windows 10 19045 |
| [`PlexiChore-Mac/`](PlexiChore-Mac) | macOS host: Swift / SwiftUI menu-bar app | ⚠️ Written, **never compiled** |
| [`PROTOCOL.md`](PROTOCOL.md) | Wire protocol shared by all three — the contract | Authoritative |
| [`ROADMAP.md`](ROADMAP.md) | What is left, known limits, cleanup | Start here for next work |
| [`CLAUDE.md`](CLAUDE.md) | Guide for Claude Code sessions continuing this project | |

## Features (Windows host + Android tablet)

- **Three modes:** Extend (virtual second monitor), Primary (tablet becomes the Windows main display; original layout restored on disconnect, crash-safe), Mirror (any existing monitor).
- **Portrait:** rotating the tablet switches the virtual monitor to a portrait mode (1600×2560 etc.).
- **Auto scaling:** the tablet's virtual monitor gets a Windows DPI scale matching the tablet's density (200 % on a Tab S8); adjustable on the tablet (Display size).
- **Low latency:** hardware H.264 (NVENC/QuickSync/AMF via Media Foundation, software and MJPEG fallbacks), Qualcomm/Exynos/MediaTek low-latency decoders, vsync-aligned frame pacing, sub-second connect.
- **Transports:** USB cable (adb reverse, auto-applied by the desktop app; USB tethering supported), Wi-Fi with automatic discovery and 4-digit pairing, manual IP.
- **Input:** multi-touch, S-Pen (pressure/tilt/hover/barrel/eraser), touch-as-mouse mode, scroll.
- **Compatibility:** Android 8–17, phones to 14.6" tablets, foldables, DeX, Fire OS (no Google services), decoder capability negotiation with fallback chain.

Measured on Galaxy Tab S8 + GeForce GT 710 over USB: ~60 fps desktop/cursor motion in all modes, 51–55 fps full-screen video in extend (GPU-limited), ~3 ms RTT, 0.4–1 s tap-to-picture.

## Quick start

### Windows host
Requirements: Windows 10 1809+ (tested 19045), .NET 10 SDK to build.
```powershell
cd PlexiChore-Desktop
dotnet build PlexiChore.slnx -m:1
dotnet test  PlexiChore.slnx
powershell -File publish.ps1          # → dist\PlexiChore.exe (self-contained, single file)
```
Run `dist\PlexiChore.exe` (lives in the tray). For **Extend/Primary** click *Extended display → Install* once (installs the signed open-source [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver), one UAC prompt). See [`PlexiChore-Desktop/README.md`](PlexiChore-Desktop/README.md) and [`PlexiChore-Desktop/driver/README.md`](PlexiChore-Desktop/driver/README.md).

### Android app
Requirements: Android Studio / JDK 17+ (Android Studio's JBR works), Android SDK 37.
```bash
cd PlexiChore
./gradlew assembleDebug
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

### Mac host (untested)
```bash
cd PlexiChore-Mac
swift build            # or open Package.swift in Xcode
./scripts/build-app.sh # assembles + signs build/PlexiChore.app
```
See [`PlexiChore-Mac/README.md`](PlexiChore-Mac/README.md).

## Using it

1. Start PlexiChore Desktop on the PC (enable *Start with Windows* in its Settings if you like).
2. **USB:** enable *USB debugging* on the tablet, plug in, accept the prompt. **Wi-Fi:** same network; approve the 4-digit code on the PC the first time.
3. Open PlexiChore on the tablet, pick **Extend / Primary / Mirror**, tap **Connect**.
4. While streaming: swipe down from the top edge or 3-finger tap for controls (disconnect, display size, touch mode, stats).

## Known limits
See [`ROADMAP.md`](ROADMAP.md#known-limits). Highlights: full-screen video is GPU-limited on weak GPUs; the Mac host has never been compiled; the virtual display driver needs a short (≤ ~48) mode list.

## License / third party
Virtual Display Driver (MIT) and nefcon (BSD-3) are downloaded at install time, not bundled — see `PlexiChore-Desktop/driver/README.md`. Fonts: Inter and Space Grotesk (SIL OFL).
