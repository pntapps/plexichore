# CLAUDE.md — PlexiChore for Mac (macOS host)

Read `../CLAUDE.md` and `../PROTOCOL.md` first. Human docs: `README.md`.

## ⚠️ Status: written on Windows, NEVER compiled or run
Everything here was authored without a Mac. Your first job on a MacBook:
1. `swift build` (Swift 5.9 tools, Swift 5 language mode, macOS 13+) — fix compile errors. Likely spots: `@MainActor` AppDelegate overriding `init()`; `CFArray as NSArray?` cast in `Encode/H264Encoder.swift` (`isKeyframe`); `Text.tracking` availability on macOS 13; ARC for the ObjC target `CVirtualDisplay` (`-fobjc-arc` unsafe flag in Package.swift); Swift concurrency isolation warnings (classes marked `@unchecked Sendable`).
2. `./scripts/build-app.sh` → `build/PlexiChore.app` (ad-hoc signed; set a stable signing identity so TCC permissions persist across rebuilds). Grant Screen Recording + Accessibility (+ Local Network on macOS 15).
3. End-to-end with an Android tablet: build/install the Android app (`../PlexiChore/CLAUDE.md`), USB via `adb reverse tcp:47800 tcp:47800` (the app's ADBManager does it; Homebrew adb at /opt/homebrew/bin), or Wi-Fi (UDP beacon). Verify in order: mirror → extend (CGVirtualDisplay) → input (click, drag, scroll direction, pen pressure) → reconnect.
4. Check the private API: virtual display appears with correct size, HiDPI mode (points = pixels/2), placed beside the main display, disappears on release (kept 6 s for quick reconnect).

## Code map (`Sources/PlexiChore/`)
`App/` (PlexiChoreApp MenuBarExtra, HostController @MainActor hub, WindowManager) · `Protocol/Protocol.swift` (framing, JSON models, 24-byte INPUT pointers) · `Network/` (HostServer NWListener :47800, ClientSession, DiscoveryBeacon BSD-socket UDP broadcast :47801) · `Display/` (VirtualDisplayManager via `CVirtualDisplay` ObjC wrapper `PXVirtualDisplay`, DisplayCatalog) · `Capture/ScreenCapturer.swift` (ScreenCaptureKit, 420v) · `Encode/` (VideoToolbox H.264 low-latency, AVCC→Annex-B, SPS/PPS sent as separate VIDEO packet flags=0x02; MJPEG) · `Stream/` (pipeline, keep-alive frames, STATS) · `Input/` (CGEvent mouse/scroll/keys) · `USB/ADBManager.swift` · `System/` (permissions, SMAppService login item, prefs/trusted devices) · `UI/`.
`Sources/CVirtualDisplay/` — private `CGVirtualDisplay*` declarations + `PXVirtualDisplay` wrapper (classes looked up via `NSClassFromString`, so missing API ⇒ mirror fallback).

## Protocol fields the Mac host doesn't implement yet (Windows does)
Bring to parity after it compiles (see `../PROTOCOL.md`):
- `requested.mode == "primary"` (make the virtual display the main display: `CGConfigureDisplayOrigin` to (0,0) for it / set as main via display config; restore on detach).
- `requested.scalePercent` / CONFIG `scalePercent` (choose HiDPI vs 1× mode for the virtual display based on tablet `densityDpi`).
- `requested.orientation` + SETTINGS `{"orientation":"portrait"}` (recreate the virtual display in portrait size), `viewportWidthPx/HeightPx`.
- Decoder caps in HELLO: `decodeModes`, `h264Profiles`, `h264MaxLevel` — clamp size/fps/profile to them (Windows: `ClampToDecoder`, `H264ProfileForTablet` in Engine `Session.cs`).
- CONFIG `link` (`usb-cable` | `usb-wireless-adb` | `usb-tether` | `wifi`) and `encoder` (informational).
- Seamless resize: tablet accepts a mid-stream CONFIG with a new size followed by codec-config + IDR.
Then update this list and `../ROADMAP.md`.

## Notes
- Not sandboxed (private API + CGEvent) → not App Store eligible; distribute notarized outside the store.
- Pairing: loopback (USB) and trusted device IDs skip PAIRING; others get a 4-digit code (auto-reject after 2 min).
