# PlexiChore for Mac

The macOS host for **PlexiChore**. It turns an Android tablet into a portable monitor, either as an
**extended** secondary display (a virtual monitor) or as a **mirror** of an existing display.
It speaks PlexiChore protocol v1 (`../PROTOCOL.md`), the same protocol as the Windows host, so one Android
client works with both.

It runs as a menu-bar app (SwiftUI `MenuBarExtra`, `LSUIElement`, so there is no Dock icon) with a dark
settings and status window that uses the violet-to-cyan brand gradient.

---

## Requirements

- **Run:** macOS 13 Ventura or later, Apple silicon or Intel. Release builds are universal (arm64 + x86_64).
- **Build:** Xcode 15 or later (Swift 5.9+ toolchain). Full Xcode is needed for universal builds.
  The Command Line Tools are enough for a host-architecture build.
- **USB:** Android `adb`. The app finds it in Homebrew (`/opt/homebrew/bin`, `/usr/local/bin`), the
  Android Studio SDK, or `PATH`, and can also download Google's `platform-tools` for you.
- **Tablet:** the PlexiChore Android app (`../PlexiChore`).

## Build

### Command line

```bash
cd PlexiChore-Mac
swift build                       # debug compile
swift test                        # unit tests (pure logic: protocol JSON, session policy, …)
./scripts/build-app.sh            # release build → build/PlexiChore.app (signed, hardened runtime)
open build/PlexiChore.app
```

Options for `scripts/build-app.sh` (all environment variables):

| Variable | Meaning |
|---|---|
| `UNIVERSAL=1` | Universal arm64 + x86_64 binary (what a release ships). Needs full Xcode. |
| `SIGN_IDENTITY="…"` | Signing identity (name or SHA-1). Default: the *PlexiChore Local Dev* identity if `make-dev-cert.sh` was run, otherwise ad-hoc (`-`). |
| `TIMESTAMP=1` | Request a secure timestamp. Automatic for `Developer ID Application: …` identities. |
| `CONFIG=debug` | Debug build (default `release`). |
| `VERSION=1.2.0`, `BUILD_NUMBER=42` | Override `CFBundleShortVersionString` / `CFBundleVersion` in the built bundle only. |
| `OUT_DIR=/path` | Where `PlexiChore.app` (and `PlexiChore.app.dSYM`) go. Default `build/`. |
| `SCRATCH_PATH=/path` | SwiftPM build directory (default `.build/`). |
| `INSTALL=1` | Also copy the app to `~/Applications/PlexiChore.app`. |

What the script does: `swift build`, assembles `PlexiChore.app` from `Resources/Info.plist`
(bundle id `com.pntapps.plexichore.mac`, `LSUIElement`, usage descriptions) plus `Resources/AppIcon.icns`
if present, then signs it with the hardened runtime and `Resources/PlexiChore.entitlements` (no App
Sandbox). Assembly and signing happen in a temporary folder, because iCloud Drive and File Provider
folders such as `~/Documents` keep adding extended attributes that `codesign` rejects.

**Version:** the single source of truth is `CFBundleShortVersionString` / `CFBundleVersion` in
`Resources/Info.plist`. The About page reads the values from the bundle. Bump them there for a release.

### Stable local signing (recommended for development)

```bash
./scripts/make-dev-cert.sh        # once: self-signed "PlexiChore Local Dev" identity in its own keychain
./scripts/build-app.sh            # picks it up automatically
```

macOS ties Screen Recording and Accessibility grants to the app's **code signature**. An ad-hoc
signature changes on every build, so macOS asks for the permissions again after each rebuild. The
dev identity keeps the signature stable. It lives in `~/Library/Keychains/plexichore-dev.keychain-db`
and never touches your login keychain. It is only for your own Mac, never for distribution.

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

## Release (Developer ID, DMG, notarization)

**There is no App Sandbox.** The private `CGVirtualDisplay` API, `CGEvent` injection and launching
`adb` all need that, so **PlexiChore cannot be distributed through the Mac App Store.** It is
distributed directly: Developer ID signature, hardened runtime, notarization, DMG.

One-time setup on the release Mac:

1. Install a **Developer ID Application** certificate (Xcode > Settings > Accounts > Manage
   Certificates, or developer.apple.com). Check with `security find-identity -p codesigning -v`.
2. Store notary credentials in the keychain (nothing goes into the repo):
   ```bash
   xcrun notarytool store-credentials plexichore-notary \
       --apple-id "<apple id>" --team-id "<TEAMID>" --password "<app-specific password>"
   ```

Each release:

```bash
cd PlexiChore-Mac
# 1. bump CFBundleShortVersionString / CFBundleVersion in Resources/Info.plist
export SIGN_IDENTITY="Developer ID Application: <Name> (<TEAMID>)"
UNIVERSAL=1 ./scripts/build-app.sh                 # build/PlexiChore.app (+ .dSYM: keep it for crash logs)
./scripts/package-dmg.sh                           # build/PlexiChore-<ver>.dmg (+ .sha256), DMG signed too
./scripts/notarize.sh build/PlexiChore-<ver>.dmg   # notarytool submit --wait, staple, Gatekeeper check
```

- `scripts/package-dmg.sh [app]` builds a compressed (UDZO) DMG with the app and an `/Applications`
  link. It signs the DMG when `SIGN_IDENTITY` is set to a real identity. `OUT_DIR` overrides the output folder.
- `scripts/notarize.sh <dmg|app>` uses the `plexichore-notary` keychain profile
  (`NOTARY_PROFILE=…` to change it). Before submitting it checks the app (inside the DMG, mounted
  read-only) for a Developer ID Application signature, the hardened runtime, a secure timestamp and
  `codesign --verify --deep --strict`, so a dev/ad-hoc build is refused locally instead of by Apple.
  For an `.app` it zips the bundle first. When Apple rejects the submission it prints the notary log.
- Always pass `SIGN_IDENTITY` for a release: without it `build-app.sh` silently uses the
  *PlexiChore Local Dev* identity (if `make-dev-cert.sh` was run) or ad-hoc.
- Verify on a clean Mac (or another user account): open the DMG, drag to Applications, launch. There
  must be no "unidentified developer" warning. `spctl --assess --type execute -vv /Applications/PlexiChore.app`
  should report `source=Notarized Developer ID`.

CI (`.github/workflows/mac.yml`) runs `swift build --build-tests`, `swift test`, the fake-tablet tool tests, a universal
ad-hoc `build-app.sh` and `package-dmg.sh` on every push or PR that touches `PlexiChore-Mac/`. The
DMG (+ `.sha256` and the zipped dSYM) is uploaded as an artifact. It is **not** notarized: Gatekeeper blocks it on other Macs, so use it
for testing only. The workflow has not run on GitHub yet.

### Release pipeline: verified locally (2026-10-21, macOS 27, Xcode 27.0, Swift 6.4, Apple silicon)

- `swift build -c release`, `swift test` (196/196), fake-tablet tool tests (25/25).
- `build-app.sh` (thin arm64, dev identity) and `UNIVERSAL=1 SIGN_IDENTITY=- build-app.sh`: bundle has
  `Contents/{Info.plist,PkgInfo,MacOS/PlexiChore,Resources/AppIcon.icns,_CodeSignature}`; Info.plist has
  `com.pntapps.plexichore.mac`, 1.0.0 (`BUILD_NUMBER` override works), `LSMinimumSystemVersion` 13.0,
  `LSUIElement`, Screen Recording / Accessibility / Local Network usage strings; `lipo` = `x86_64 arm64`,
  both slices `minos 13.0`; dSYM UUIDs match the binary; icon has all 10 iconset sizes;
  `codesign --verify --deep --strict` passes; flags `runtime` (hardened); entitlements = no sandbox +
  network client/server only. No extra entitlement is needed: CGEvent and ScreenCaptureKit are TCC grants,
  `CGVirtualDisplay` is looked up at runtime, `adb` is a separate process.
- `package-dmg.sh`: UDZO/HFS+ DMG, volume `PlexiChore 1.0.0`, mounts read-only with `PlexiChore.app` (signature
  still valid) and an `Applications → /Applications` link; `.sha256` checks out.
- `notarize.sh` preflight correctly refuses the ad-hoc and dev-signed builds. Submission, stapling and
  `spctl` were **not** run (needs a Developer ID certificate and the notary profile).
- Known quirk: with the default SwiftPM build system (swiftbuild) the linker stamps `sdk 13.0` (= deployment
  target) instead of the real SDK into `LC_BUILD_VERSION` (`--build-system native` stamps the real SDK).
  macOS therefore runs the app with macOS 13-SDK compatibility behaviour (e.g. no new system look on
  macOS 26+). Debug builds behave the same, so this is what has been tested; `build-app.sh` prints the stamp.

## Permissions

| Permission | Why | Where |
|---|---|---|
| **Screen Recording** | Capture the extended or mirrored display (ScreenCaptureKit) | System Settings > Privacy & Security > Screen Recording (macOS 15+: *Screen & System Audio Recording*) |
| **Accessibility** | Turn tablet touches and pen input into mouse and keyboard events (`CGEvent`) | System Settings > Privacy & Security > Accessibility |
| **Local Network** (macOS 15+) | UDP discovery beacon and accepting Wi-Fi tablets | Prompted on first use. Later: System Settings > Privacy & Security > Local Network |
| Incoming connections (firewall) | TCP 47800 / UDP 47801 | Prompted by the macOS firewall if it is on |

The status window shows each permission with **Allow** and **Open Settings** buttons. After you
enable Screen Recording, macOS may require you to quit and relaunch PlexiChore. USB-only use does not need
Local Network, because `adb reverse` traffic arrives on the loopback interface.

## Running it

1. Copy `PlexiChore.app` to `/Applications` (needed for **Open at login**; it also keeps permission
   grants tied to one location) and launch it. An icon appears in the menu bar.
2. Grant Screen Recording and Accessibility when asked, then relaunch if macOS says so.
3. **USB:** enable *USB debugging* on the tablet (Settings > Developer options), plug it in and accept
   the RSA prompt on the tablet. PlexiChore runs `adb reverse tcp:47800 tcp:47800` for every
   authorized device, and the tablet lists the Mac as "USB". The equivalent manual command is
   `adb -s <serial> reverse tcp:47800 tcp:47800`.
4. **Wi-Fi:** put both devices on the same network. The Mac broadcasts a beacon every second, so it
   shows up on the tablet automatically. The first time a tablet connects over Wi-Fi, a
   **4-digit code** appears on both screens. Approve it on the Mac and the tablet is remembered.
   You can manage remembered tablets under *Trusted tablets*. USB (loopback) connections skip pairing.
5. Choose **Extend** or **Mirror** on the tablet, along with resolution, position (left, right,
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
    └── UI/           Theme (glass + gradient), MainWindowView, MenuBarView, pages (Home, Display, USB,
                      Settings, About), PairingWindowView
Resources/            Info.plist (bundle id, version, usage strings), PlexiChore.entitlements
scripts/              build-app.sh, make-dev-cert.sh, package-dmg.sh, notarize.sh
Tests/PlexiChoreTests XCTest unit tests (swift test)
tools/faketablet/     Python fake tablet + mock host for protocol testing without hardware
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

- **The Mac's screen goes black, or windows end up on a display you can't see** (for example the
  virtual display became the main display and the tablet disconnected):
  1. Press **⌃⌥⌘D** (Control-Option-Command-D), the emergency hotkey. It removes PlexiChore's virtual
     display and restores your original display arrangement.
  2. If that doesn't help, disconnect the tablet or unplug the USB hub/dock it's attached to. The
     virtual display is released at the latest 6 s after the tablet disconnects.
  3. As a last resort, quit PlexiChore (`killall PlexiChore` over SSH or from a Terminal you can still
     reach). The virtual display only exists while the app is running, so macOS falls back to the
     physical displays.
- **Black screen on the tablet:** check the Screen Recording permission, then quit and relaunch
  PlexiChore. After a rebuild with a new ad-hoc signature, remove the old PlexiChore entry in System
  Settings and add it again, or use `make-dev-cert.sh` (see above).
- **Touches do nothing:** grant Accessibility. If PlexiChore is already listed, remove it and add it
  again after a rebuild with a new signature.
- **Tablet not found over Wi-Fi:** make sure both devices are on the same subnet and that AP or client
  isolation is off, that Local Network access is allowed (macOS 15+), and that the firewall allows
  PlexiChore. You can also type one of the IP addresses listed under *Wi-Fi > Manual address* on the tablet.
- **USB not detected:** look at the USB card. It shows "unauthorized" until you accept the debugging
  prompt on the tablet. Press **Refresh** to run `adb reverse` again. If the tablet appears twice in
  `adb devices` (cable serial plus `adb-…._adb-tls-connect._tcp`), that's normal for wireless debugging.
- **Extend falls back to Mirror:** the private `CGVirtualDisplay` API isn't available
  on this macOS release (see above). The beacon then reports `"virtualDisplay": false`.
- **"PlexiChore is damaged / can't be opened" on another Mac:** the build isn't notarized (CI
  artifacts, ad-hoc or dev builds). Use a notarized release, or for your own testing only:
  `xattr -dr com.apple.quarantine /Applications/PlexiChore.app`.
- **`codesign` fails with "resource fork, Finder information, or similar detritus not allowed":** the
  build script already signs in a temporary folder. If you sign by hand, copy the app out of
  `~/Documents` or iCloud Drive first, or run `xattr -cr PlexiChore.app`.
