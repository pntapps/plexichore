# CLAUDE.md — PlexiChore for Mac (macOS host)

Read `../CLAUDE.md` and `../PROTOCOL.md` first. Human docs: `README.md`.

## Status (2026-10-21)
Compiles and runs on macOS 27 (Apple Silicon). Verified with the fake tablet (`tools/faketablet/faketablet.py --scenario …`,
58/58) and end-to-end with the real Tab S8: mirror / extend / primary / portrait over USB and direct Wi-Fi (pairing),
quit / `kill -9` / ⌃⌥⌘D restore, lid closed (opt-in), cable replug, − / + display size. First notarized DMG built
(1.0.0, Developer ID, universal). Remaining hands-on items: `../ROADMAP.md` P0 #1.
- Release: `SIGN_IDENTITY="Developer ID Application: Md Imran Ansari (5ZKLJ5PZ6K)" UNIVERSAL=1 ./scripts/build-app.sh`,
  same `SIGN_IDENTITY` for `./scripts/package-dmg.sh`, then `./scripts/notarize.sh build/PlexiChore-<ver>.dmg` (keychain
  profile `plexichore-notary`). Submitting uploads to Apple — ask the user first. Every new build needs a new notarization.
  `notarize.sh` wrongly warns "the DMG itself is not Developer ID signed" (spctl confirms it is) — fix the check.
- The app's TCC grants (Screen Recording, Accessibility) follow the signing identity; dev builds use the "PlexiChore
  Local Dev" identity from `make-dev-cert.sh` (own keychain). macOS re-asks "bypass the private window picker" after
  updates — the user must click Allow; never automate permission or pairing prompts.
- Build: `swift build`; tests: `swift test`. App: `OUT_DIR=<dir> ./scripts/build-app.sh` (`INSTALL=1` copies to
  ~/Applications). Keep the repo out of iCloud-synced folders (it used to live in ~/Documents: codesigning the test bundle
  failed on iCloud xattrs and conflict copies like `HostController 2.swift` broke the build). It lives in ~/Developer now.
- Only one host on port 47800 and one user of the tablet at a time; never run the fake tablet and the real tablet together.
- Display safety (after a black-screen incident with a flapping USB-C hub): `Display/DisplaySafety.swift`. Emergency release
  ⌃⌥⌘D or `killall -USR1 PlexiChore`. Don't weaken the safety net without testing a real monitor hot-unplug.

## Code map (`Sources/PlexiChore/`)
`App/` (PlexiChoreApp MenuBarExtra, HostController @MainActor hub, WindowManager) · `Protocol/Protocol.swift` (framing, JSON models, 24-byte INPUT pointers) · `Network/` (HostServer NWListener :47800, ClientSession, DiscoveryBeacon BSD-socket UDP broadcast :47801) · `Display/` (VirtualDisplayManager via `CVirtualDisplay` ObjC wrapper `PXVirtualDisplay`, DisplayCatalog, DisplayArrangement primary/restore, DisplaySafety) · `Capture/ScreenCapturer.swift` (ScreenCaptureKit, 420v) · `Encode/` (VideoToolbox H.264 low-latency, AVCC→Annex-B, SPS/PPS sent as separate VIDEO packet flags=0x02; MJPEG) · `Stream/` (pipeline, keep-alive frames, STATS) · `Input/` (CGEvent mouse/scroll/keys) · `USB/ADBManager.swift` · `System/` (permissions, SMAppService login item, prefs/trusted devices) · `UI/`.
`Sources/CVirtualDisplay/` — private `CGVirtualDisplay*` declarations + `PXVirtualDisplay` wrapper (classes looked up via `NSClassFromString`, so missing API ⇒ mirror fallback).

## Protocol fields the Mac host doesn't implement yet (Windows does)
Byte-level parity with `../PROTOCOL.md` / Windows Engine was implemented (unverified on a tablet): framing, HELLO (all
additive fields, lenient JSON like Windows `Wire.Json`; missing `requested` members take the Windows defaults, so no
`mode` = mirror — `RequestedSettings.initial(from:)`), INPUT (`min(count, (len-1)/24)` pointers like Windows
`PointerSample.Parse`; unknown action = move for mouse/scroll), `PLEXI?` probe matching (Windows rules,
NUL-trimmed), CONFIG (sent after the encoder exists: real `codec`, `encoder`, `scalePercent`, `link` with ≤ 0.4 s wait), SETTINGS (live bitrate/fps without IDR; size/codec/quality via in-place
encoder swap = mid-stream CONFIG + codec-config + IDR; orientation/scale/mode recreate the virtual display), PING/PONG
(self-stall guard, 5 s timeout), STATS (int kbps), PAIRING, BYE, encoder chain hw H.264 → sw H.264 → MJPEG with
Windows failure escalation (`SessionPolicy.onPipelineEnded`). Remaining gaps — "not yet" on the Mac:
- **Live `scalePercent` change** (SETTINGS with only `scalePercent`): Windows re-applies DPI without re-attaching. macOS
  scale = the virtual display's backing/HiDPI mode: with the default `ScaleStrategy.scaled` every step except 100↔200
  changes the backing size, which is the descriptor's fixed `maxPixelsWide/High`, and `PXVirtualDisplay` has no
  live re-`applySettings` (flipping `hiDPI` on a live CGVirtualDisplay is undocumented and unverified). So the display
  is re-created (windows on it get reshuffled; the stream restarts with a new IDR) unless the resolved mode is
  unchanged (`VirtualDisplayRequest.sameDisplay`). CONFIG `scalePercent` is still correct. A live path would need a
  display created with a large `maxPixels` + a multi-mode list, measured on hardware first.
- **Adaptive encode-size ladder / steady-cadence fallback** (Windows `StreamPipeline.StatsWindow`: 1.0 → 0.75 → 0.625
  under encoder backpressure, 40 fps on 120 Hz). The Mac has the mechanism (`StreamPipeline.reconfigure`) but no
  heuristic (VideoToolbox is expected not to need it — unmeasured). Add only if the bench shows encoder-limited fps.
- **Portrait "driver has no portrait mode" fallback**: n/a — CGVirtualDisplay takes any size, so portrait is always built.
- Deliberate small differences (not wire format): SETTINGS received during pairing are merged and used once approved
  (Windows drops them, so a rotation while the code is shown is lost); the Mac PINGs from connect instead of after
  HELLO and answers a PING sent before HELLO (Windows answers anything but HELLO first with BYE "expected HELLO");
  a JSON `null` in SETTINGS is "absent" (Windows resets strings to their default / rejects the whole SETTINGS for
  numbers); STATS round half-away-from-zero instead of .NET's half-to-even (±0.1 fps cosmetic).
- `viewportWidthPx/HeightPx` and `h264MaxLevel` are parsed but unused (Windows ignores them too).
Then update this list and `../ROADMAP.md`.

## Notes
- Not sandboxed (private API + CGEvent) → not App Store eligible; distribute notarized outside the store.
- Pairing: loopback (USB) and trusted device IDs skip PAIRING; others get a 4-digit code (auto-reject after 2 min).
- Lid closed: `HostPreferences.keepWithLidClosed` (Extended display → Options) lets a watched tablet stay the only display
  on AC power (`DisplaySafetySnapshot.virtualOnlyAllowed`); without it the display goes after `virtualOnlyGrace` (10 s).
- adb: a cable must *own* the 47800 reverse (`ADBParsing.reverseHeld`); a wireless-debugging twin that reverses later
  would otherwise move the stream onto Wi-Fi. Testing tip: `adb disconnect` the wireless transport when measuring USB.
- Help page (`UI/HelpPage.swift`, menu bar "Help…") holds the user-facing troubleshooting; keep it in sync with
  behaviour changes (emergency key, permissions, lid option, scaling).
- Logs: only errors are logged (`/usr/bin/log show --predicate 'subsystem == "com.pntapps.plexichore"'` — zsh has a
  `log` builtin, use the full path).
