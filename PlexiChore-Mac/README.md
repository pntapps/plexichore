# PlexiChore for Mac

The macOS host for **PlexiChore**. It turns an Android tablet into a portable monitor, either as an
**extended** secondary display (a virtual monitor) or as a **mirror** of an existing display.
It speaks PlexiChore protocol v1 (`../PROTOCOL.md`), the same protocol as the Windows host, so one Android
client works with both.

It runs as a menu-bar app (SwiftUI `MenuBarExtra`) with a dark settings and status window that uses
the violet-to-cyan brand gradient.

---

## Requirements

- macOS 13 Ventura or later. Apple silicon and Intel are both supported.
- Xcode 15 or later (Swift 5.9 toolchain), or the matching Command Line Tools.
- To use USB, you need Android `adb`. The app finds it in Homebrew, the Android Studio SDK, or `PATH`,
  and can also download Google's `platform-tools` for you.

## Build

### Command line

```bash
cd PlexiChore-Mac
swift build -c release            # compile only
./scripts/build-app.sh            # compile and assemble build/PlexiChore.app (ad-hoc signed)
open build/PlexiChore.app
```

Options for `scripts/build-app.sh`:

| Variable | Meaning |
|---|---|
| `SIGN_IDENTITY="Apple Development: … (TEAMID)"` | Sign with a real identity. Recommended, see below. |
| `UNIVERSAL=1` | Build a universal arm64 + x86_64 binary. Needs full Xcode. |
| `CONFIG=debug` | Debug build. |

### Xcode

Open `Package.swift` in Xcode (File > Open…, or `xed .`), pick the **PlexiChore** scheme and press Run.
This is fine for development. Keep two limits in mind:

- A target built by SwiftPM in Xcode is a bare executable, not a `.app`. It has no Info.plist and
  no `LSUIElement`. The app compensates at runtime with `setActivationPolicy(.accessory)`. However,
  **Open at login** and user notifications need the bundle.
- macOS privacy permissions (TCC) granted to that executable are tracked separately from
  the bundled app.

For day-to-day use, run `./scripts/build-app.sh` and launch `build/PlexiChore.app`, preferably after
copying it to `/Applications`.

### Signing notes

- **There is no App Sandbox** (`Resources/PlexiChore.entitlements`). The private `CGVirtualDisplay`
  API, `CGEvent` injection and launching `adb` all need that. As a result **PlexiChore cannot be
  distributed through the Mac App Store.** You can distribute it directly with a Developer ID and
  notarization. The hardened runtime is already enabled by the build script.
- macOS ties Screen Recording and Accessibility permissions to the app's **code signature**. An
  ad-hoc signature (`-`) changes on every build, so macOS may ask for the permissions again after
  each rebuild. If that happens, remove the old PlexiChore entry in System Settings and add it again.
  Signing with a stable identity (`SIGN_IDENTITY=…`) avoids the problem.
- For notarized distribution, use
  `SIGN_IDENTITY="Developer ID Application: …"`, then
  `xcrun notarytool submit … --wait` and `xcrun stapler staple build/PlexiChore.app`.

## Permissions

| Permission | Why | Where |
|---|---|---|
| **Screen Recording** | Capture the extended or mirrored display (ScreenCaptureKit) | System Settings > Privacy & Security > Screen Recording |
| **Accessibility** | Turn tablet touches and pen input into mouse and keyboard events (`CGEvent`) | System Settings > Privacy & Security > Accessibility |
| **Local Network** (macOS 15+) | UDP discovery beacon and accepting Wi-Fi tablets | Prompted automatically |
| Incoming connections (firewall) | TCP 47800 / UDP 47801 | Prompted by the macOS firewall if it is on |

The status window shows each permission with **Allow** and **Open Settings** buttons. After you
enable Screen Recording, macOS may require you to quit and relaunch PlexiChore.

## Using it

1. Launch PlexiChore. An icon appears in the menu bar.
2. **USB:** enable *USB debugging* on the tablet, plug it in and accept the RSA prompt. PlexiChore
   runs `adb reverse tcp:47800 tcp:47800`, and the tablet lists the Mac as "USB".
3. **Wi-Fi:** put both devices on the same network. The Mac broadcasts a beacon every second, so it
   shows up on the tablet automatically. The first time a tablet connects over Wi-Fi, a
   **4-digit code** appears on both screens. Approve it on the Mac and the tablet is remembered.
   You can manage remembered tablets under *Trusted tablets*.
4. Choose **Extend** or **Mirror** on the tablet, along with resolution, position (left, right,
   top or bottom), fps and bitrate.

## Architecture

```
Sources/
├── CVirtualDisplay/                 ObjC shim (C-family SwiftPM target)
│   ├── CGVirtualDisplayPrivate.h    @interface decls of the PRIVATE CoreGraphics classes
│   ├── PXVirtualDisplay.m           runtime lookup (NSClassFromString) + safe wrapper
│   └── include/CVirtualDisplay.h    public header: PXVirtualDisplay (the only thing Swift sees)
└── PlexiChore/
    ├── App/          PlexiChoreApp (MenuBarExtra + AppDelegate), HostController (brain), WindowManager
    ├── Protocol/     message types, BE framing, JSON models, INPUT parser
    ├── Network/      HostServer (NWListener :47800, TCP_NODELAY), ClientSession (framing,
    │                 PING/PONG, 5 s timeout, BYE, backpressure), DiscoveryBeacon (BSD UDP :47801)
    ├── Display/      VirtualDisplayManager (create/position virtual display), DisplayCatalog
    ├── Capture/      ScreenCapturer (SCStream, 420v, showsCursor, minimumFrameInterval)
    ├── Encode/       H264Encoder (VideoToolbox, low-latency RC, AVCC→Annex-B), MJPEGEncoder (CIContext)
    ├── Stream/       StreamPipeline (capture→encode→send, keep-alive frames, stats), SessionContext
    ├── Input/        InputInjector (touch/pen/mouse/scroll → CGEvent), KeyInjector (soft keyboard)
    ├── USB/          ADBManager (locate/download adb, poll devices, adb reverse)
    ├── System/       Permissions, LaunchAtLogin (SMAppService), HostPreferences/Trusted devices
    └── UI/           Theme (glass + gradient), MainWindowView, MenuBarView
Resources/            Info.plist, PlexiChore.entitlements (used by scripts/build-app.sh)
```

### Session flow (host side)

1. `HostServer` accepts a TCP connection and creates a `ClientSession`. The session reads the
   `u8 type | u32 BE length | payload` frames, answers PING with PONG, sends its own PING every
   second, and drops the connection after 5 s without any traffic.
2. **HELLO**: loopback connections (USB through `adb reverse`) and trusted device IDs are accepted
   immediately. Unknown Wi-Fi tablets get `PAIRING {waiting, code}` and must be approved in the UI.
   The host then sends `PAIRING {approved}`, or `{rejected}` followed by BYE.
3. `HostController.configure` picks the codec, fps, bitrate and frame size.
   - **Extend:** a `CGVirtualDisplay` is created at the tablet's resolution × `resolutionScale`
     (HiDPI optional, ppi taken from `densityDpi`). It is placed next to the main display using
     `CGBeginDisplayConfiguration` and `CGConfigureDisplayOrigin` (`.forSession`). If creation
     fails, the host falls back to mirror and reports `"mode":"mirror"` in CONFIG.
   - **Mirror:** the display at `monitorIndex` is captured, scaled to fit the tablet.
4. The host sends CONFIG, then `StreamPipeline` starts. The `SCStream` delivers NV12 frames to
   `VTCompressionSession` (real time, no reordering, average bitrate plus a 1.5× hard cap, low-latency
   rate control). Every IDR is preceded by a separate VIDEO packet with `flags=0x02` that contains the
   SPS and PPS in Annex-B form, and the IDR itself goes out with `flags=0x01`.
   - An IDR is sent on REQUEST_KEYFRAME, after any dropped frame, and every 5 s.
   - If the screen is static, the last frame is re-encoded at least every 450 ms.
   - Delta frames are dropped when more than 3 MB is queued on the socket. Frames are also skipped
     before encoding when the backlog exceeds 1.5 MB.
5. SETTINGS is merged into the requested settings. A change to bitrate alone is applied live; any
   other change rebuilds the pipeline (and the display if needed), and CONFIG is sent again.
6. INPUT is handled directly on the session queue for the lowest latency. Normalized coordinates
   are mapped to `CGDisplayBounds(target)` and posted as `CGEvent`s at `.cghidEventTap`:
   - one finger → left button with drag and double-click detection;
   - two fingers → pixel scroll, and a quick two-finger tap → right click;
   - pen → left button with pressure, barrel button → right button;
   - mouse → left and right buttons;
   - kind 3 → line scroll.
7. STATS (`captureFps`, `encodeMs`, `bitrateKbps`) is sent about once per second.

### Discovery

A BSD UDP socket (`SO_BROADCAST`, bound to `*:47801`) sends the beacon
`{"svc":"plexichore","v":1,"id":…,"name":…,"os":"macos","port":47800,"virtualDisplay":…}` once per second. It goes to
`255.255.255.255` and to every interface's directed broadcast address, and the host replies unicast
to `PLEXI?`. Network.framework cannot set `SO_BROADCAST`, which is why this part uses BSD sockets.

## About the private `CGVirtualDisplay` API

Extended-display mode relies on the **undocumented** CoreGraphics classes
`CGVirtualDisplayDescriptor`, `CGVirtualDisplaySettings`, `CGVirtualDisplayMode` and `CGVirtualDisplay`.
They have existed since macOS 11 and are the same API that DeskPad, BetterDisplay-style tools and
Chromium's test utilities use.

- **It is not App Store compatible**, and Apple may change or remove it in any macOS release.
- The shim never references the class symbols at link time. Everything goes through
  `NSClassFromString`, so on a macOS release without the API the app still launches,
  `PXVirtualDisplay.isSupported()` returns `NO`, and PlexiChore offers mirror mode only
  (`"virtualDisplay": false` in the beacon).
- The display exists only while the `PXVirtualDisplay` object is retained. PlexiChore keeps it for
  6 s after a tablet disconnects, so that a quick reconnect does not rearrange your windows.
- macOS 14 and later require a non-zero vendor ID and a unique serial number. Both are set.

## Troubleshooting

- **Black screen on the tablet:** check Screen Recording permission, then relaunch PlexiChore.
- **Touches do nothing:** grant Accessibility. If PlexiChore is already listed, remove it and add it
  again after a rebuild with a new signature.
- **Tablet not found over Wi-Fi:** make sure both devices are on the same subnet and that AP or client
  isolation is off, and allow PlexiChore in the firewall. You can also type one of the IP addresses
  listed under *Wi-Fi > Manual address* on the tablet.
- **USB not detected:** look at the USB card. It shows "unauthorized" until you accept the debugging
  prompt on the tablet. Press **Refresh** to run `adb reverse` again.
