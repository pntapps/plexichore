# CLAUDE.md — PlexiChore Android app

Read `../CLAUDE.md` and `../PROTOCOL.md` first.

## Build / test / run
- JDK 17+ (Android Studio's bundled JBR is fine: on Windows `JAVA_HOME="C:\Program Files\Android\Android Studio\jbr"`; on macOS `/Applications/Android Studio.app/Contents/jbr/Contents/Home`). Create `local.properties` with `sdk.dir=...` (not committed).
- AGP 9.4.1, Gradle 9.6, Kotlin 2.2.10, compileSdk/targetSdk 37, minSdk 26.
- `./gradlew assembleDebug` · `./gradlew testDebugUnitTest` · `./gradlew lintDebug`
- Screenshot matrix (Robolectric + Roborazzi, no emulator): `./gradlew :app:testDebugUnitTest --tests "*DeviceMatrixScreenshotTest*" [-Pplexi.shots=phone_port,tab7_land]` → `app/build/outputs/roborazzi/<config>/<scene>.png`. Infinite animations are disabled in tests; the first frame must be meaningful.
- Install: `adb -s <serial> install -r app/build/outputs/apk/debug/app-debug.apk`.
- Debug-only connect without UI (from `app/src/debug/AndroidManifest.xml` alias):
  `adb -s <serial> shell am start -n com.pntapps.plexichore/.display.DebugDisplay --es host 127.0.0.1 --es codec h264|mjpeg --es mode extend|primary|mirror --ez stats true [--ei scale 200] [--ef resScale 0.75] [--ez discover true]`
  (Git Bash on Windows: set `MSYS_NO_PATHCONV=1`.) For USB first: `adb -s <serial> reverse tcp:47800 tcp:47800` (the Windows app does this automatically).
- Debug UI extras on MainActivity: `--ez demo true|false` (fake hosts), `--ez resetOnboarding true`.
- Logcat tags: `PlexiH264` (decoder), `PlexiProfile` (device caps), `PlexiStats` (1/s fps, RTT, gaps, late frames), `PlexiDiscovery`.
- Frame pacer off switch: `adb shell setprop debug.plexichore.nopacing 1`.

## Code map (`app/src/main/java/com/pntapps/plexichore/`)
- `core/` — networking + media. `PlexiCore.kt` (singleton `PlexiConnection`, reconnect, transport preference incl. USB-tether/Wi-Fi), `StreamSession.kt` (one TCP session, HELLO/CONFIG/PING/PAIRING/SETTINGS), `Protocol.kt`, `HostDiscovery.kt` (UDP beacons, `PLEXI?` probes, loopback USB probe, subnet sweep fallback), `LanNetwork.kt` (bind to Wi-Fi/Ethernet when VPN active), `DeviceProfile.kt` (display metrics, decoder caps → HELLO), `VideoDecoders.kt` (MediaCodec chain: HW low-latency → HW → c2.android.avc → MJPEG), `VideoPipeline.kt`, `FramePacer.kt` (adaptive vsync pacing for bursty adb), `InputEncoder.kt`, `StreamService.kt` (foreground service, connectedDevice).
- `display/` — `DisplayActivity` (immersive stream screen), `StreamLayout.kt` (aspect-fit, insets, gestures: 3-finger tap / top-edge swipe), `DisplayOverlay.kt` (control pill, stats, Size button).
- `ui/` — Compose app: `theme/`, `components/` (glass cards, segmented control, `Illustrations.kt` mode-aware hero animation, `DisplayScaleUi.kt`, `DisplayModeUi.kt`, PositionPicker), `screens/` (Onboarding, Home, Settings, Help, ConnectionOverlay, ConnectByIpDialog), `data/SettingsRepository.kt` (DataStore), `MainViewModel.kt`, `HostGroup.kt` (merges USB + Wi-Fi entries of the same host), `preview/FakePlexiConnection.kt`.
- `core/Contracts.kt` is the core↔UI contract — additive changes only.

## Status
Working and verified on Galaxy Tab S8 (Android 16). Compatibility audit + fixes: `COMPATIBILITY.md` (status table at top; remaining P2 items listed there). Open items: `../ROADMAP.md`.

## Gotchas
- targetSdk 37: orientation locks are ignored on ≥600dp — layouts and the stream must handle any orientation; the tablet reports orientation/viewport to the host.
- `ACCESS_LOCAL_NETWORK` (API 37) must be granted for Wi-Fi; USB via adb reverse doesn't need it.
- Samsung taskbar is reported as navigationBars + tappableElement — pad with `safeDrawing ∪ tappableElement`.
- Rendering with timestamps can drop a 120 Hz panel to 60 Hz — `FramePacer`/`DisplayActivity` vote 120 Hz explicitly.
- Release builds: `ConnectionProvider` calls `PlexiCore.get` directly (no reflection); check R8 keep rules before shipping.
