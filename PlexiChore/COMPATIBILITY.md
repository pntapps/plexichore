# PlexiChore Android: compatibility audit (Phase 1) and fixes (Phase 2a/2b)

## Status, 2026-10-20

Phase 2a (UI) and 2b (core/display plus the Windows engine) are implemented and verified off-device:
- `assembleDebug`, `lintDebug` (no NewApi/InlinedApi errors) and all Android unit tests pass, including 472 screenshots (26 configs × 18 scenes, plus 4 on the API 37 sandbox).
- The Desktop solution builds and all 110 App tests pass (`--artifacts-path` scratch build; `dist\` untouched).
- **On-device (Galaxy Tab S8, Android 16 / API 36, 1600x2560 @ 340 dpi), 23:10–23:14:**
  - **Taskbar:** One UI reports the taskbar as `navigationBars` + `tappableElement` + `mandatorySystemGestures` (102 px = 48dp). Home now clears it.
  - **Host merge:** USB and Wi-Fi entries show as one card.
  - **Decoder:** ranked `c2.qti.avc.decoder.low_latency` > `c2.qti.avc.decoder` > `c2.android.avc.decoder`. Low latency is on, with 32 vendor keys declared. Decode modes go up to 3840x2160@120 and 3840x2400@30.
  - **Portrait with the live landscape-only driver:** SETTINGS `orientation=portrait` → provider falls back to landscape → engine streams 2560x1600 as is → tablet shows the "rotate to landscape" hint. Rotating back sends `landscape`. The portrait presets apply after Repair.
  - **wm emulation** (all reset afterwards): sw600 (426 dpi), 4:3 1536x2048@320, phone sw411 (623 dpi, hero art hidden), large (240 dpi) all render correctly.
  - **Bench smoke over USB** (cursor, 6 s): mirror 60.7 fps, extend 60.3 fps, primary 61.1 fps, 5–10 stutters each. No regression.
  - **Known minor issue:** a rotation re-attaches the virtual monitor even when the fallback ends up with the same landscape mode (about 0.4 s blank). It could be skipped.

| Item | Status | Where |
|---|---|---|
| P0-1 ACCESS_LOCAL_NETWORK (API 37) | Fixed. Declared, requested at runtime (Onboarding last page + Home card, "Open settings" after a permanent deny, re-checked on resume). Core waits for it before LAN UDP and maps the denial to a clear message. The constant was verified in the android-37 jar. | `ui/components/LocalNetworkPermission.kt`, `HomeScreen`, `OnboardingScreen`, `HostDiscovery.hasLocalNetworkAccess`, manifest |
| P0-2 orientation on ≥600dp | Fixed (additive protocol). HELLO/SETTINGS carry `orientation` + viewport, and the tablet re-sends after 0.7 s of stable rotation. The host builds a portrait virtual monitor when the VDD has a portrait mode; otherwise it streams landscape and the tablet shows a "rotate" hint. VDD presets now include 1600x2560, 1200x1920 and 1752x2800 (19 resolutions, 38 modes, within the 24/48 caps); existing installs need Repair. | `PlexiCore.onViewportChanged`, `Session.TabletBox/ReconfigureAsync`, `DisplayLayout.OrientForModes` (+ test), `DisplayOverlay` hint |
| P0-3 decode caps | Fixed. Native size probed first, plus a ladder, `areSizeAndRateSupported` and PerformancePoints (API 29+), and a joint fallback. HELLO adds `decodeModes`, `h264Profiles` and `h264MaxLevel`. The host clamps size/fps (`ClampToDecoder`) and encodes Main/Baseline when High is missing. | `DeviceProfile`, `Session.ClampToDecoder/H264ProfileForTablet`, `MfH264Encoder` |
| P0-4 decoder chain | Fixed. Ranked candidates (no secure/alias entries); per codec it tries low-latency, then no vendor keys/operating rate, then basic. The next candidate is used on create failure *and* after repeated runtime failures; MJPEG only when all have failed. | `VideoDecoders.kt`, `VideoPipeline.resetIfCurrent` |
| P0-5 taskbar insets | Fixed: `safeDrawing ∪ tappableElement` everywhere. The screenshots now model the One UI taskbar as tappableElement-only. | `ui/components/Insets.kt` |
| S-1/S-2/S-4, S-5..S-11 | Fixed (scrollable overlay card, width-fitted digits, stacked session card, adaptive host card, ellipsized segments, FlowRow chips, scrolling onboarding, no duplicate host name, height-aware two-pane, fitting left pane). Duplicate USB + Wi-Fi entries are merged into one card. | ui/** |
| S-3 pill | Fixed. Icon-only buttons below 560dp or above 1.3× font, host name ellipsized and shrinks first, Disconnect always visible, safe-area padding. | `DisplayOverlay.kt` |
| P1-1/P1-2 display insets / cutout | Fixed. The video fits inside cutout + visible bars/caption/taskbar (full-bleed in true immersive), and the overlay pads with the same insets. | `StreamLayout.applyFit` |
| P1-3 profile cache | Fixed. Rebuilt on every connect; refresh matched by aspect ratio. | `PlexiCore.profile` |
| P1-4 KEY_LOW_LATENCY / vendor keys | Fixed. Only when FEATURE_LowLatency is supported; vendor keys checked against `supportedVendorParameters` (API 31+). | `VideoDecoders.kt` |
| P1-5 MJPEG resolution | Fixed. The fallback asks for ≤ ~1920 px on the long edge and ≤ 30 fps. | `PlexiCore.onCodecUnavailable` |
| P1-6 discovery / VPN | Fixed. Unicast /24 sweep when broadcasts find nothing, direct probe of the last LAN host, cellular/tunnel interfaces skipped, sockets bound to Wi-Fi/Ethernet while a VPN is active. | `HostDiscovery`, `LanNetwork.kt` |
| P1-8 uses-feature | Fixed: wifi, touchscreen and multitouch set to required=false. | manifest |
| P1-9 AndroidX | Upgraded: activity 1.13.0, core-ktx 1.19.1, lifecycle 2.11.0, Compose BOM 2026.09.00. Kotlin is unchanged at 2.2.10. | `libs.versions.toml` |
| P2-5 StreamLayout density | Fixed (read live). | |
| P2-11 RTL icons | Fixed (AutoMirrored). | |
| Still open | P2-1 gesture exclusion, P2-2 historical pen samples, P2-3 touchpad/keyboard, P2-8 background display launch, P2-10 low-RAM buffer pooling, S-12 bidi isolates, S-13 chip contrast, and an emulator smoke test on API 37. | |

Scope: API 26–37, every tablet class (7" 600dp up to 14.6" Ultra), foldables, phones (graceful),
DeX/multi-window, all vendor video decoders, network quirks. Phase 1 = audit only; no product source
was changed. The test-only additions are listed at the end.

Priority key:
- **P0** = broken or blocked on some devices, or a store/policy blocker.
- **P1** = visibly wrong or degraded on a common device class.
- **P2** = polish, or a niche device class.

Line numbers refer to the sources as of 2026-10-20. Other agents are editing core/ and display/,
so re-locate by symbol name.

---

## P0

### P0-1 Local Network Protection: `ACCESS_LOCAL_NETWORK` is missing (targetSdk 37)
- **Where:** `AndroidManifest.xml`, `core/HostDiscovery.kt` (UDP 47801 broadcast/probe), `core/StreamSession.kt:138` (TCP to a LAN IP).
- **Problem:** the API 37 SDK ships `android.permission.ACCESS_LOCAL_NETWORK` (I checked the android-37 `android.jar`; it sits in the NEARBY_DEVICES group). Under Android's Local Network Protection, an app targeting 37 needs this runtime permission before it can send or receive LAN unicast, broadcast or multicast. Without it, Wi-Fi discovery shows nothing and Wi-Fi/manual-IP connects fail with EPERM/ENETUNREACH. USB via `adb reverse` (127.0.0.1) still works, because loopback is exempt.
- **Affected:** every device running Android 17 (API 37). Older releases are not affected.
- **Fix:**
  - Declare `<uses-permission android:name="android.permission.ACCESS_LOCAL_NETWORK"/>`.
  - On API ≥ 37, request it at runtime: add an onboarding page and a Home "Allow Wi-Fi discovery" card, the same way POST_NOTIFICATIONS is handled.
  - Gate `HostDiscovery.udpLoop` on it, and map EPERM to a clear "Allow nearby devices / local network" message in `PlexiCore.describe()`.
- **Verify:** on the API 37 emulator image (the only system image installed) once RAM allows. The Tab S8 runs an older Android, so it cannot reproduce this.

### P0-2 Wrong orientation and resolution on ≥600dp: `screenOrientation="sensorLandscape"` is ignored
- **Where:** `AndroidManifest.xml:46` (lint `DiscouragedApi`), `core/DeviceProfile.kt:50-51` (always reports landscape `max × min`), `display/StreamLayout.kt:applyFit`.
- **Problem:** from Android 16, with targetSdk ≥ 36 and sw ≥ 600dp, orientation and resizability locks are ignored. targetSdk 37 has no opt-out property.
  - A tablet held in portrait, or one in split screen, gets a landscape 2560×1600 stream letterboxed into a narrow band. That is about 39% of the screen on a 16:10 tablet in portrait.
  - Touch mapping is still correct (contentRect).
- **Affected:** every tablet on Android 16+ in portrait, split-screen or freeform. Phones (<600dp) still honour the lock.
- **Fix:**
  - Treat orientation as runtime state. Send an additive `SETTINGS {orientation, viewportWidthPx, viewportHeightPx}`, or a re-HELLO, when the DisplayActivity window size changes. The host then rebuilds the virtual display in portrait (Windows IDD and macOS CGVirtualDisplay both support it).
  - Until the host supports that, show a "Rotate to landscape" hint in portrait instead of a thin band.
  - Drop `screenOrientation` or keep it only as a hint. Do not rely on it.

### P0-3 HELLO `maxDecodeWidth/Height` is not trustworthy, and no profile, level or fps limit is reported
- **Where:** `core/DeviceProfile.kt:maxDecodeSize` (≈ lines 81-88 of the file).
- **Problems:**
  1. The candidate list (3840×2160, 2960×1848, 2560×1600 …) leaves out the device's **native** size, for example 2800×1752 (Tab S8+/S9+), 2880×1800 (Xiaomi Pad 6), 2000×1200 (Lenovo P11), 2408×1720 (Galaxy Tab S9 FE) and 1920×1200. If 3840×2160 fails because it is unsupported, a native 2800×1752 that would decode can fall through to 2560×1600.
  2. It uses `isSizeSupported` and ignores frame rate. A level 5.1 decoder handles 2560×1600 @ 60 but not @ 120 on many MediaTek and Unisoc chips, so the host is never told.
  3. The fallback `supportedWidths.upper to supportedHeights.upper` pairs the maximum of each axis independently. Example: 4096×4096 on a decoder whose real limit is 4096×2304. The result is a size the decoder **cannot** handle.
  4. No profile or level is reported. Low-end Allwinner, Rockchip RK3326 and Unisoc T310 parts, plus the `c2.android.avc` software fallback, may top out at Main or level 4.1 (1920×1080 @ 30). PROTOCOL.md says the host may send High.
- **Affected:** budget tablets (Fire HD 8/10, Lenovo M-series, Teclast, Blackview, Doogee, Alldocube), Android Go devices and Rockchip boards. Also anything at 120 Hz.
- **Fix:**
  - Probe the native `w × h` first (and `h × w`), then the 16:10 and 16:9 ladders.
  - Use `areSizeAndRateSupported(w, h, fps)` for fps ∈ {120, 90, 60, 30}. On API 29+ also use `getSupportedPerformancePoints()` when it is non-null.
  - Compute the joint fallback from `getSupportedHeightsFor(w)`.
  - Report additive HELLO fields:
    - `h264Profiles: ["high","main","baseline"]` from `CodecCapabilities.profileLevels`;
    - `h264MaxLevel`;
    - `decodeModes: [{w,h,maxFps}]`.
  - The host must clamp to these (Windows engine side).

### P0-4 Only one decoder is ever tried; a failure goes straight to MJPEG
- **Where:** `core/VideoDecoders.kt:findDecoder` (≈190-210), `create` (≈216-242), `VideoPipeline.buildLocked`.
- **Problem:** `findDecoder()` caches a single `MediaCodecInfo`. If that codec throws in `createByCodecName`, `configure` or `start`, `onCodecUnavailable` asks the host for MJPEG at once. Typical triggers:
  - Exynos `c2.exynos.h264.decoder` rejecting a size that is not a multiple of 16, such as 1752 or 1848;
  - a Rockchip OMX decoder out of instances while a YouTube PiP is running;
  - an MTK decoder rejecting `KEY_OPERATING_RATE = 32767` on API 26-28.

  MJPEG at 2560×1600 decodes in software at roughly 15-25 fps on mid-range SoCs, so the session becomes laggy instead of just using the next codec.
- **Fix:**
  - Rank all non-secure AVC decoders and drop aliases (API 29+ `isAlias`).
  - Try each in order. Within one codec, use a progressive format fallback:
    1. full low-latency;
    2. no vendor keys, no `KEY_OPERATING_RATE`;
    3. basic.
  - End with `c2.android.avc` / `OMX.google.h264.decoder` before MJPEG.
  - Remember the codec that worked (SharedPreferences, keyed by build fingerprint).

### P0-5 Samsung (and other) taskbar overlaps the bottom of Home, Settings and Help
- **Where:** `ui/screens/HomeScreen.kt:150,158,167`, `SettingsScreen.kt:105`, `HelpScreen.kt:89`. Each uses `WindowInsets.navigationBars...bottom` alone.
- **Problem:** on One UI 5/6 with the pinned taskbar, and on Android 12L-14 large-screen taskbars, the taskbar height comes in through `tappableElement` (and `systemGestures`). `navigationBars` can be only the small gesture handle, or 0 when the taskbar is "transient". The red bands in the screenshots show where the overlap lands. Fixed bottom content, such as the Onboarding "Next" row, is safe because it uses `safeDrawing` in full.
- **Fix:**
  - Use `WindowInsets.safeDrawing.union(WindowInsets.tappableElement)`, bottom side, as the bottom content padding everywhere. Put it in one helper, e.g. `Modifier.plexiBottomInsets()` / `bottomContentPadding()`.
  - In Phase 2, confirm on the Tab S8 with `adb shell dumpsys window | grep -iA3 "InsetsSource.*navigationBars\|tappable"`.

---

## P1

### P1-1 DisplayActivity does not inset the video or overlay in multi-window, freeform or DeX
- **Where:** `display/DisplayActivity.kt:76-77`, `display/DisplayOverlay.kt:71,80,97`.
- **Problem:** with `setDecorFitsSystemWindows(false)` everything draws under the bars. System bars cannot be hidden in split-screen, freeform, DeX or desktop windowing (Android 15/16 desktop mode). As a result:
  - the video (and desktop content) sits under the status bar, the caption bar and the taskbar;
  - the control pill (top 14dp), the stats card (16dp) and the hint (bottom 32dp) end up under the caption bar or taskbar, where they cannot be tapped.
- **Fix:**
  - Fit `contentRect` inside `systemBars ∪ displayCutout ∪ captionBar` whenever those insets are *visible* (`WindowInsetsCompat.isVisible`).
  - Pad the overlay with `WindowInsets.safeDrawing` / `safeContent`.
  - Keep the full-bleed path for real immersive fullscreen.

### P1-2 Display cutout: the video is drawn under the notch
- **Where:** `DisplayActivity.kt:70-74` (`LAYOUT_IN_DISPLAY_CUTOUT_MODE_ALWAYS`).
- **Problem:** the Tab S8 Ultra and S9 Ultra have a notch in the top bezel, and many phones and Fire OS devices have punch holes. Desktop pixels under the cutout (the top-centre of the Windows desktop or the macOS menu bar) are hidden, and taps there cannot land.
- **Fix:** add a user setting, "Use area around camera cutout", default off. When off, fit `contentRect` to `displayCutout.safeInsets`. Ideally also tell the host the safe area so it can size the virtual display exactly.

### P1-3 The decode profile is cached once per process (foldables, DeX, resolution changes)
- **Where:** `core/PlexiCore.kt:76` (`profile by lazy`).
- **Problem:** `widthPx/heightPx/densityDpi/refreshHz` are captured the first time. Cases that go stale:
  - unfolding a Fold or Pixel Fold (outer 2316×904 → inner 2176×1812);
  - connecting to DeX;
  - changing One UI's "Screen resolution" (FHD+/WQXGA);
  - a `wm size` override.

  In each case HELLO carries the old screen. The refresh lookup also does an exact `physicalWidth == w` match, which fails under a `wm size` override and silently falls back to `display.refreshRate`.
- **Fix:** rebuild the profile on every `connect()`. On `DisplayManager.DisplayListener.onDisplayChanged`, send SETTINGS or reconnect. Pick refresh using the aspect ratio, not an exact width.

### P1-4 `KEY_LOW_LATENCY` is set without checking the feature; the retry drops every hint
- **Where:** `VideoDecoders.kt:249-266`.
- **Problem:** on API 30+ `KEY_LOW_LATENCY=1` is set even when `FEATURE_LowLatency` is unsupported. Most codecs ignore it, but some older c2 HALs (Unisoc, early MTK c2) fail `configure`. The catch then retries with `basicFormat`, which loses `KEY_FRAME_RATE`, `KEY_PRIORITY`, `KEY_OPERATING_RATE` *and* the vendor keys, so the device ends up with the worst latency.
- **Fix:**
  - Set `KEY_LOW_LATENCY` only when `isFeatureSupported(FEATURE_LowLatency)`.
  - Make the fallback stepwise, as in P0-4.
  - Check vendor keys first: on API 31+ use `codec.supportedVendorParameters` and `setParameters()` after `start()` instead of guessing in the format. Qualcomm `vendor.qti-ext-dec-low-latency.enable`, Exynos `vendor.rtc-ext-dec-low-latency.enable` and MTK `vendor.mtk.vdec.lowlatency.mode` can be discovered that way.
  - The OMX-era `vdec-lowlatency` key only works on OMX.MTK (API ≤ 30).

### P1-5 MJPEG fallback runs at full resolution
- **Where:** `PlexiCore.onCodecUnavailable` (≈140).
- **Problem:** the fallback SETTINGS keeps `resolutionScale` and `fps`. Software JPEG decode of 2560×1600 every frame on Fire HD or Helio G80-class devices gives about 15 fps, plus 16 MB ARGB churn per frame.
- **Fix:** with MJPEG, request at most about 1920×1200 @ 30 (resolutionScale 0.6-0.75). Optionally decode to RGB_565 when the `ActivityManager.isLowRamDevice` / `memoryClass` flags indicate a low-RAM device.

### P1-6 Wi-Fi discovery has no unicast fallback, and VPN or secondary interfaces break routing
- **Where:** `core/HostDiscovery.kt:279-298`, `StreamSession.kt:138`.
- **Problems:**
  - Many mesh, enterprise and hotel APs ("AP isolation", "multicast/broadcast filtering", Ubiquiti/Eero "multicast enhancement"), and some Android hotspots, drop 255.255.255.255 and subnet broadcasts. The host is then never found.
  - With an active VPN (always-on VPN, Samsung Secure Wi-Fi, NordVPN …), sockets follow the VPN default route. Broadcasts go to `tun0` and the LAN TCP connect is tunnelled away, unless the VPN allows LAN bypass.
  - `ia.broadcast` also includes `rmnet`, `p2p0` and `ap0` interfaces.
- **Fixes:**
  1. Use `ConnectivityManager.registerNetworkCallback(TRANSPORT_WIFI | TRANSPORT_ETHERNET)` to find the LAN `Network`, then `network.bindSocket(datagramSocket)` and `network.bindSocket(socket)` before the TCP connect. Fall back to the default network.
  2. If nothing is found after about 4 s, send a unicast `PLEXI?` sweep to every host of the Wi-Fi interface's /24 on :47801. That is 254 small datagrams, rate-limited, repeated every 10 s.
  3. Skip interfaces whose names start with `rmnet`, `ccmni`, `tun`, `ppp` or `dummy`.
  4. Remember the last successful host IP and probe it by unicast first.
  5. Optional: mDNS/NSD (`_plexichore._tcp`) via `NsdManager`. It works through many broadcast filters, and the Windows host can register it.

### P1-7 Material3 overlay and status card: fixed widths overflow on phones; text clips at large font
- See the screenshot findings (section S) for details.

### P1-8 `uses-feature` declarations are missing (store filtering)
- **Where:** `AndroidManifest.xml`.
- **Problem:** `ACCESS_WIFI_STATE` and `CHANGE_WIFI_MULTICAST_STATE` imply `android.hardware.wifi` required=true. Ethernet-only devices (Android boxes, some kiosk tablets, ChromeOS with Ethernet) are then filtered out on Play even though USB works.
- **Fix:** add the following, and handle "no Wi-Fi" gracefully:
  - `<uses-feature android:name="android.hardware.wifi" android:required="false"/>`
  - `android.hardware.touchscreen` required=false, so ChromeOS and mouse-only devices are allowed. Touch forwarding simply is not used there.

### P1-9 Old AndroidX versions (edge-to-edge, insets, predictive back fixes)
- **Where:** `gradle/libs.versions.toml`. `activity-compose 1.8.0`, `core-ktx 1.10.1`, `lifecycle-runtime-ktx 2.6.1` (lint `GradleDependency`).
- **Problem:**
  - `enableEdgeToEdge` in 1.8.0 predates the Android 15 nav-bar contrast and scrim fixes and the 3-button nav transparency fix.
  - core 1.10 predates the `WindowInsetsCompat` fixes for `tappableElement` and captionBar on 12L+.

  Gradle conflict resolution may already pull newer versions through the Compose BOM, but the declared floor is old.
- **Fix:**
  - activity 1.13.0
  - core-ktx 1.19.x
  - lifecycle 2.11.0
  - Compose BOM 2026.09.00
  - Ask the lead before bumping; it affects every agent.

---

## P2

- **P2-1 Gesture-nav edge back while streaming.** `StreamLayout` sets no gesture exclusion. In immersive mode, a back swipe from the left or right edge can still steal drags meant for the host, such as Windows scrollbars at the right edge or window resizing. Fix: `setSystemGestureExclusionRects` (API 29+, ≤ 200dp per edge) over the vertical middle of each edge while `forwardInput`. Also give users a "lock edges" option.
- **P2-2 Historical (batched) MotionEvent samples are dropped.** `InputEncoder.encode` only reads the current sample. S Pen at 240 Hz and Lenovo/Xiaomi pens deliver several samples per event, so strokes look polygonal. Encode `getHistorical*` for pen moves.
- **P2-3 Touchpads (keyboard covers, DeX).** Android 13+ touchpads report `TOOL_TYPE_FINGER` + `SOURCE_MOUSE` with `CLASSIFICATION_TWO_FINGER_SWIPE`. Map them to mouse and scroll, not touch. Hardware keyboard keys are not forwarded (protocol KEY 0x05 exists). Esc and Ctrl+key would be expected on DeX and Book Cover keyboards.
- **P2-4 3-finger gestures** collide with OEM 3-finger screenshot (Xiaomi, OnePlus, Oppo, Realme, Vivo) and 3-finger "split screen" (MIUI). Taps still work. Document it, and offer a 2-finger long-press alternative.
- **P2-5 StreamLayout density** is captured in the constructor (`StreamLayout.kt:density`). DisplayActivity handles `density` config changes itself, so after a DeX or Display-size change the edge and swipe thresholds are stale. Read the density lazily.
- **P2-6 Frame pacing on 90/120 Hz panels.** `preferHighestRefreshRate` forces the panel to the maximum (battery cost). Prefer `Surface.setFrameRate(streamFps, FRAME_RATE_COMPATIBILITY_FIXED_SOURCE)` (API 30+), which lets 60 fps content run at 60 or 120 Hz cleanly. This is the performance agent's area.
- **P2-7 Notifications denied (API 33+).** The FGS still runs, but the "Disconnect" action is hidden. Make the in-app disconnect reachable and show a hint on Home. Already fine for API < 33.
- **P2-8 Background activity start.** `PlexiCore.launchDisplay` starts `DisplayActivity` from the application context after an async CONFIG. If the user leaves the app while "Connecting…", Android 10+ blocks it silently (a FGS does not grant BAL). Fix: if the app is not foreground, post a full-screen-intent / heads-up "Tap to open display" notification, or open the display on the next resume.
- **P2-9 Fire OS / no GMS.** OK: no Play Services dependency, and DataStore, coroutines and Compose are all fine. Notes:
  - Fire OS 7 = API 28 and Fire OS 8 = API 30, both MediaTek (`OMX.MTK.VIDEO.DECODER.AVC` / `c2.mtk.avc.decoder`). Covered by P0-3 and P1-4.
  - Amazon Appstore needs no change.
  - `Settings.Global "device_name"` may be null; the fallback is OK.
- **P2-10 Android Go / low-RAM.** `MAX_PAYLOAD` 16 MB, a 2 MB socket receive buffer, a new `ByteArray` per video frame, the infinite Aurora/Radar animations, and `KEY_MAX_INPUT_SIZE = w*h`. On `isLowRamDevice`:
  - pool frame buffers;
  - cap input size at about w*h/2;
  - stop decorative infinite animations (also when "Remove animations" is enabled: `Settings.Global.ANIMATOR_DURATION_SCALE == 0`);
  - limit to 1080p.
- **P2-11 RTL icons.** `Icons.Rounded.HelpOutline`, `OpenInNew`, `ViewQuilt` and `ScreenShare` are deprecated in favour of `Icons.AutoMirrored.*` (compiler warnings in `HomeScreen.kt:203,367,402,432`, `SettingsScreen.kt:221,404`, `OnboardingScreen.kt:103`, `DisplayModeUi.kt:11,13`).
- **P2-12 Lint.**
  - `mipmap-anydpi-v26` should be `mipmap-anydpi` (ObsoleteSdkInt).
  - `StaticFieldLeak` in `PlexiCore` is a false positive (application context).
  - `StreamLayout` `performClick` is missing (accessibility).
  - `PlexiApp.kt:48` uses `Configuration.screenWidthDp` instead of `LocalWindowInfo.containerSize`. In multi-window that is the window, which is what we want, but read it from WindowSizeClass for consistency.
  - Lint found no NewApi, InlinedApi or WrongConstant issues: all API-guarded calls are correctly guarded.
- **P2-13 Predictive back (targetSdk 36+ default on).** It works: DisplayActivity uses `OnBackPressedDispatcher` and Compose `BackHandler`. DisplayActivity's always-enabled callback suppresses the back-to-home animation, which is intended.
- **P2-14 Foreground service type.** OK. `connectedDevice` plus `FOREGROUND_SERVICE_CONNECTED_DEVICE`, and the API 34 prerequisite is met by `CHANGE_WIFI_MULTICAST_STATE`. The Play Console FGS declaration must explain "USB/Wi-Fi external display session".

---

## S. Screenshot findings (Robolectric + Roborazzi matrix)

The matrix produced 416 PNGs: 26 configs × 16 scenes, under `app/build/outputs/roborazzi/<config>/`. Insets are simulated as status 24dp plus `navigationBars` 24/48/56dp (red bands). Each finding below lists where it is visible and which device classes it affects.

### UI P0
- **S-1 The connection overlay card cannot scroll; its action buttons are clipped off-screen.**
  - **Where:** `ui/screens/ConnectionOverlay.kt` (≈105-125, the `GlassCard` in a centred `Box`, with no `verticalScroll` and no insets).
  - **Visible in:** `phone_land/07,08,09`, `tab7_land_fs200/07,08,09`, `phone_port_fs200/08,09`, `tabS8_land_fs200/09`.
  - **Effect:** the "Cancel", "Back" and "Try again" buttons are not visible, so the user is stuck on the pairing or failed screen (only system back helps).
  - **Affected:** any window shorter than about 640dp: 7-8" tablets in landscape at font ≥1.3, all phones in landscape, split-screen, and foldable cover screens.
  - **Fix:**
    - Wrap the card content in `verticalScroll`, add `safeDrawing` padding, and use `heightIn(max = maxHeight)`.
    - Shrink the illustration when height < 600dp (`LinkIllustration` at `fillMaxWidth(0.85f)` is about 200dp tall).
    - Pin the action row outside the scroll.
- **S-2 The pairing code overflows horizontally on narrow windows.**
  - **Where:** `ConnectionOverlay.kt:CodeDigit`. Each digit is a fixed 86×108dp, plus 14dp gaps, plus 36dp×2 card padding plus 24dp×2, which needs about 506dp.
  - **Visible in:** `phone_port/08` and `phone_port_fs200/08`, where only "4 8 2" is shown and the 4th digit is cut.
  - **Affected:** phones, foldable cover screens, and split-screen halves of 7-8" tablets.
  - **Fix:** size digits from the available width (`BoxWithConstraints`: digit = min(86dp, (maxWidth − 3·gap)/4), height = 1.25·digit, and scale the font the same way).
- **S-3 The DisplayOverlay control pill overflows, so Disconnect becomes unreachable.**
  - **Where:** `display/DisplayOverlay.kt:ControlPill` (a `Row` with no width constraint, host name `widthIn(max=220dp)`, plus the new "Auto" button).
  - **Visible in:** `phone_port/14`. The "Auto" label wraps one letter per line, and "Stats" and the ✕ Disconnect button are pushed off-screen. `tabS8_land_fs200/14` is also clipped.
  - **Fix:**
    - Set `Modifier.widthIn(max = maxWidth - 32dp)`.
    - Give the host name `weight(1f, fill=false)` with `overflow = Ellipsis`. It currently clips mid-word without an ellipsis even on the Tab S8.
    - Collapse button labels to icons below about 480dp, or at font scale > 1.3.
    - Keep Disconnect as the last item and never let it shrink.
  - **Owner:** the scaling agent, who owns DisplayOverlay.kt.
- **S-4 SessionCard squeezes its text column to about one character wide.**
  - **Where:** `HomeScreen.kt:SessionCard` (≈378-405). The text `Column(weight 1f)` sits next to two fixed buttons, "Disconnect" and "Open display".
  - **Visible in:** `tab7_land_fs200/04`, where "2560×1600 · 60 fps…" renders one character per line down the card and the buttons go off the right edge. Also `phone_port*/04` and `tabS8_land_fs200/04`.
  - **Fix:** use a `FlowRow`, or put the buttons below the text when width < about 560dp or fontScale > 1.3. Add `maxLines`/ellipsis on the spec line.

### UI P1
- **S-5 HostCard on narrow widths or at large font.**
  - **Visible in:** `phone_port_fs200/05`. The name and OS line wrap to 3-4 characters per line ("Wind / ows / 192.1 / 68.1…"), because a 58dp badge and a 48dp "Connect" button take the row.
  - **Fix:** when width < 480dp or fontScale ≥ 1.5, drop the badge to 40dp and show the Connect button below or as an icon. Give the address line `maxLines = 1` with an ellipsis.
- **S-6 SegmentedControl labels clip without an ellipsis.**
  - **Where:** `Components.kt:SegmentedControl` (`maxLines = 1`, no `overflow`).
  - **Visible in:** `phone_port_fs200/02`: "Exten · Prima · Mirro", "Spee · Balan · Qualit".
  - **Fix:** use `TextOverflow.Ellipsis`; hide the icons when the segment width is < about 110dp. Also let the height grow with font scale: `heightIn(min = 48.dp)` instead of a fixed `height`. The same fixed-`height` pattern is in GradientButton and GhostButton.
- **S-7 Onboarding text pane does not scroll; the feature row overflows.**
  - **Where:** `OnboardingScreen.kt:OnboardPage`. The text column has no `verticalScroll`, and the features use a `Row` instead of a `FlowRow`.
  - **Visible in:**
    - `tab7_land/01`: the third chip "Up to 120 fps" is squeezed into 3 lines;
    - `tabS8_land_fs200/01` and `phone_land/01`: the body text is cut and the chips are missing;
    - `phone_port_fs200/01`: the body is cut behind the Next row.
  - **Fix:** use `FlowRow` for the features, `verticalScroll` on the page, and an art size capped by height.
- **S-8 The Failed message repeats the host name.** For example: "Studio's … Floor 3): Studio's … Floor 3) refused the connection". `FailedContent` prefixes `host.name`, and `PlexiCore.describe()` already includes it. Drop one of the two.
- **S-9 Two-pane breakpoint ignores height and aspect ratio.**
  - **Where:** `PlexiApp.kt:46-49`.
  - **Problem:**
    - `phone_land` (914×411dp) gets two-pane but is too short, which is the root cause of S-1 and S-7 on phones.
    - `fold_inner` (829×690dp, Medium width) gets the single-column phone layout. The hero card fills the whole first screen and the host list sits below the fold, wasting about 60% of the width.
  - **Fix:** `twoPane = width ≥ 720dp && height ≥ 480dp` (or WindowSizeClass Medium+ with landscape/near-square), with a compact-height variant (heightSizeClass Compact → smaller hero, scrollable panes).
- **S-10 DisplayOverlay ignores insets.**
  - **Visible in:** `*/14`. The pill (top 14dp) and stats card (16dp) render under the status-bar band, and the hint (bottom 32dp) sits on the taskbar band (`*/16`).
  - **Impact:** fine in true immersive mode, wrong in multi-window, DeX and freeform (see P1-1).
  - **Fix:** `windowInsetsPadding(WindowInsets.safeDrawing)` on the overlay `Box`.
- **S-11 The left pane of two-pane Home overflows by a few dp at rest.**
  - **Visible in:** `tabS8_land/04,05` and `r43_land`. The QuickControls card bottom sits under the taskbar band until the user scrolls the left pane. Users rarely scroll that pane, so it reads as overlap.
  - **Fix:** shrink the hero by available height, or make the whole screen one scroll.

### UI P2
- **S-12 RTL.** `tabS8_land_rtl` mirrors correctly. Bidi issues where numbers and Latin text are concatenated:
  - "1600×2560" is shown reversed;
  - "found · still scanning 5".
  - Wrap technical strings with `⁦…⁩` (LTR isolate) or `BidiFormatter`. The non-AutoMirrored icons are listed in P2-11.
- **S-13 Contrast.** The violet "Wi-Fi" StatusChip (accentStart at 14% alpha bg, violet text) on the dark glass card is about 3:1, below WCAG AA for 12sp text. The tertiary text (`textTertiary`, e.g. "Don't see your computer?…") is also around 3:1 in dark mode. The light theme is fine.
- **S-14 Touch targets.**
  - `GlassIconButton` is 46dp, just below the 48dp minimum.
  - The "Open setup guide" text link in FailedContent is 8dp padding plus text, about 34dp.
  - ChoiceChips (fps, display size) at phone width are about 40dp.
  - Fix: use 48dp minimum interactive size (`minimumInteractiveComponentSize()`).
- **S-15 Font scale.** 1.3 is acceptable on all tablets. At 2.0, besides S-1 to S-7, the Settings "Display size" chips ("Auto 150% 175%…") wrap or clip on phones and 7" portrait (`phone_port_fs200/10`), and the "Replay intro" button in About clips to "R" (`phone_port_fs200/11`). Use FlowRow and wrapping buttons.
- **No issues found on:** `tab10_port`, `tabS8_port`, `tab12_land`, `ultra_land`, `r43_*` and `r32_land` at font 1.0, and in light mode. Layouts scale cleanly and there is no wasted space beyond S-11.
- **Note on P0-5.** With the inset reported as `navigationBars`, every list clears the taskbar band correctly (`tabS8_land/05,11,13`). So the Tab S8 overlap must come from One UI reporting the taskbar under a different inset type (tappableElement or systemGestures), or from it being transient. That supports the `safeDrawing ∪ tappableElement` fix. Confirm with `dumpsys window` in Phase 2.

---

## Test-only additions (Phase 1)
- `gradle/libs.versions.toml`: `robolectric 4.17`, `roborazzi 1.76.0` (+ `roborazzi-compose`).
- `app/build.gradle.kts`:
  - `testOptions.unitTests` (includeAndroidResources, Roborazzi record, `-Pplexi.shots=` filter);
  - test deps: compose ui-test-junit4, robolectric, roborazzi.
- `app/src/test/java/com/pntapps/plexichore/screenshots/DeviceMatrixScreenshotTest.kt`:
  - renders the real Onboarding, Home (0/1/many/long hosts, streaming), Connecting/Pairing/Failed overlays, Settings (top and bottom), Help (top and bottom) and the DisplayOverlay (pill+stats, pairing card, hint);
  - covers 26 configurations: 14 devices, font scale 1.3/2.0, light and RTL;
  - simulates status-bar and taskbar insets, drawn as red bands.
  - Run: `./gradlew :app:testDebugUnitTest --tests "*DeviceMatrixScreenshotTest*" [-Pplexi.shots=tab7_land,phone_port]`
  - Output: `app/build/outputs/roborazzi/<config>/<scene>.png`

Emulator smoke test skipped: only an API 37 image is installed (`system-images/android-37.0/google_apis_playstore`), and about 1.2-1.4 GB of the 8 GB RAM was free while other agents were building. Run it in Phase 2 to verify P0-1 (it needs about 2 GB free).
