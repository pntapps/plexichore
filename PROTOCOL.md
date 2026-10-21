# PlexiChore Protocol v1 (shared contract — all components MUST follow this exactly)

PlexiChore turns an Android tablet into a portable monitor for a Windows or macOS host.

## Roles
- **Host** (Windows / macOS companion app) = TCP **server** on port **47800**. Captures screen, encodes, streams video. Injects input received from tablet.
- **Tablet** (Android app) = TCP **client**. Decodes + displays video full screen, sends touch/pen input.

## Transports
1. **USB**: Host runs `adb reverse tcp:47800 tcp:47800` for every authorized device (re-run whenever `adb devices` changes). Tablet connects to `127.0.0.1:47800`. Tablet should probe 127.0.0.1:47800 periodically and show it as a host labelled "USB".
2. **Wi-Fi**: Host broadcasts a UDP beacon to `255.255.255.255:47801` (and every interface's broadcast address) once per second. Tablet listens on UDP 47801. Tablet may also send the ASCII datagram `PLEXI?` to broadcast:47801; hosts reply unicast with the beacon to the sender's address/port (a probe matches when its first ≤ 16 bytes, with trailing NUL/CR/LF/space removed, are exactly `PLEXI?`). When broadcasts are filtered (AP isolation, multicast/broadcast enhancement, mesh, enterprise Wi-Fi) and nothing answered within ~4 s, the tablet also sends `PLEXI?` by unicast to every address of its own subnet (capped at a /24, batched, every 15 s) and to the last host it streamed from; hosts answer exactly as for a broadcast probe. Android 17+ (targetSdk 37) needs the runtime permission `ACCESS_LOCAL_NETWORK` for any of this; USB (adb reverse) does not.
   Beacon payload (UTF-8 JSON):
   ```json
   {"svc":"plexichore","v":1,"id":"<stable uuid>","name":"DESKTOP-ABC","os":"windows|macos","port":47800,"virtualDisplay":true}
   ```
3. **Manual IP**: user types host IP; port 47800.

## Framing (TCP, all integers BIG-ENDIAN)
Every message: `u8 type | u32 length | payload[length]`. Max payload 16 MiB. TCP_NODELAY on both sides.

| type | name | dir | payload |
|---|---|---|---|
| 0x01 | HELLO | T→H | UTF-8 JSON (below) |
| 0x02 | CONFIG | H→T | UTF-8 JSON (below). Sent after HELLO accepted and again whenever stream params change |
| 0x03 | VIDEO | H→T | `u64 ptsMicros, u8 flags, bytes data`. flags bit0=keyframe, bit1=codec-config (H.264 SPS/PPS only). data = H.264 Annex-B (with start codes) or a full JPEG for mjpeg |
| 0x04 | INPUT | T→H | binary pointer event (below) |
| 0x05 | KEY | T→H | UTF-8 JSON `{"action":"down|up","keyCode":<android keycode>,"text":"optional"}` (soft + physical keyboard; optional). Non-empty `text` is typed as Unicode on "down" only ("\n" = Return; keyCode then 0/ignored). Otherwise `keyCode` is pressed/released as given; modifiers are separate key codes (shift 59/60, ctrl 113/114, alt 57/58, meta 117/118 = ⌘ on macOS, Win on Windows) sent down before and up after the key; held modifiers apply to following key codes (not reliably to `text`), so the tablet sends a key code for a character typed with Ctrl/Alt/Meta. IME composition is resolved tablet-side (the host only sees backspaces (67) and text). |
| 0x06 | PING | both | `u64 senderTimeMicros` — receiver echoes the same payload back as PONG |
| 0x07 | PONG | both | echoed payload |
| 0x08 | REQUEST_KEYFRAME | T→H | empty. Host must emit IDR (with SPS/PPS before it) ASAP |
| 0x09 | SETTINGS | T→H | UTF-8 JSON partial of `requested` object (below). Host applies and resends CONFIG |
| 0x0A | BYE | both | UTF-8 reason string. Then close |
| 0x0B | STATS | H→T | UTF-8 JSON `{"captureFps":60,"encodeMs":4.1,"bitrateKbps":12000}` ~1/s, optional |
| 0x0C | PAIRING | H→T | UTF-8 JSON `{"status":"waiting|approved|rejected","code":"4821"}`. Wi-Fi connections from unknown tablets wait for user approval on host; USB (loopback) is auto-approved |

### HELLO (tablet → host), first message after connect
```json
{
  "protocol": 1,
  "deviceId": "<stable uuid>",
  "deviceName": "Galaxy Tab S8",
  "model": "SM-X700",
  "widthPx": 2560, "heightPx": 1600,      // physical landscape pixels of the tablet display
  "densityDpi": 320, "refreshHz": 120,     // densityDpi = Android DisplayMetrics.densityDpi (logical, follows Screen zoom)
  "codecs": ["h264", "mjpeg"],              // in preference order
  "maxDecodeWidth": 3840, "maxDecodeHeight": 2160,
  "touch": true, "pen": true,
  "requested": {
    "mode": "extend" | "primary" | "mirror", // extend = virtual secondary display; primary = virtual display becomes Windows/macOS MAIN display (host restores the original primary on detach); mirror = existing monitor
    "monitorIndex": 0,                    // mirror only: which host monitor (0 = primary)
    "resolutionScale": 1.0,               // 0.5..1.0 of tablet native resolution (extend mode)
    "fps": 60,                            // 30 | 60 | 90 | 120
    "bitrateKbps": 20000,
    "quality": "balanced",                // "performance" | "balanced" | "quality"
    "codec": "h264",
    "touchMode": "touch" | "mouse" | "none",
    "position": "right" | "left" | "top" | "bottom",  // extend: where the tablet sits relative to primary
    "scalePercent": 0,                    // additive, optional: host display scale (DPI) of the VIRTUAL monitor (extend/primary only).
                                          // 0 = auto (default), else 100|125|150|175|200|225|250|300 (other values snap to the nearest)
    "orientation": "landscape"            // additive, optional: "landscape" (default) | "portrait" — how the tablet is held (see below)
  },
  // ---- additive, optional (older hosts ignore them; older tablets do not send them) ----
  "decodeModes": [{"width":2560,"height":1600,"maxFps":120}, {"width":3840,"height":2160,"maxFps":60}],
                                          // sizes the tablet's H.264 decoder really handles (landscape; rotated sizes are
                                          // equally valid), with the highest fps at each size, largest first
  "h264Profiles": ["high","main","baseline"], // profiles the decoder supports, best first
  "h264MaxLevel": "5.1",
  "orientation": "landscape",             // same as requested.orientation, at connect time
  "viewportWidthPx": 2560, "viewportHeightPx": 1600 // current display window size (split screen / freeform / DeX may be smaller)
}
```
Missing fields (clarification, matches the Windows host): a `requested` member that is absent (or `requested` itself)
takes these defaults — `mode` **"mirror"**, `monitorIndex` 0, `resolutionScale` 1.0, `fps` 60, `bitrateKbps` 20000,
`quality` "balanced", `codec` "h264", `touchMode` "touch", `position` "right", `scalePercent` 0, `orientation`
"landscape". Unknown `mode` values also mean "mirror". Tablets should always send `mode`.

Decode capabilities: `maxDecodeWidth/Height` is the largest size in `decodeModes` (or the native size when the decoder
publishes nothing better). The host MUST NOT send a frame size/fps the tablet cannot decode: if the requested size fits a
mode but the fps is too high it lowers the fps (minimum 30); if the size fits no mode it shrinks to the largest mode with
≥ 30 fps. Without `decodeModes` the host only clamps to `maxDecodeWidth/Height` (long/short edges). When `h264Profiles`
is present without "high", the host encodes Main (or Baseline if only that is listed).

Orientation: on large screens (smallest width ≥ 600dp) Android 16+ ignores the app's landscape lock, so the stream
follows the tablet. With `orientation = "portrait"` in extend/primary mode the host builds a portrait virtual monitor
(e.g. 1600×2560) when its display driver has a portrait mode; otherwise it stays landscape (CONFIG width > height) and the
tablet shows a "rotate to landscape" hint. Mirror mode ignores orientation (the PC desktop is landscape). The tablet sends
SETTINGS `{"orientation":"portrait"}` when it is rotated (after ~0.7 s of stability); the host re-creates the virtual monitor
and resends CONFIG. Phones always send "landscape".
`scalePercent` auto: the host makes desktop UI the same physical size as the tablet's own UI —
scale ≈ densityDpi / 160 ÷ (tablet px per virtual-monitor px, > 1 when resolutionScale < 1), nearest step (ties → lower),
clamped to 125–250% (100% allowed when downscaled), then to what the OS allows for that monitor.
E.g. 240 dpi 10" 1920x1200 → 150%, Galaxy Tab S8/S8+ (320/340 dpi) → 200%. `densityDpi` must be Android's
`DisplayMetrics.densityDpi`. Mirror mode never changes a physical monitor's scale. SETTINGS may carry `scalePercent`
alone: the host re-applies it live (no re-attach, stream continues) and resends CONFIG.

### CONFIG (host → tablet)
```json
{"codec":"h264","width":2560,"height":1600,"fps":60,"bitrateKbps":20000,
 "mode":"extend","hostName":"DESKTOP-ABC","hostOs":"windows",
 "monitors":[{"index":0,"name":"Primary","width":1920,"height":1080}],
 "virtualDisplayAvailable":true,
 "scalePercent":200}
```
Width/height = encoded frame size (even numbers). Tablet scales to fit, preserving aspect (letterbox).
`scalePercent` (additive) = display scale actually applied to the virtual monitor (after clamping to the OS range);
0 = not applicable (mirror) or unknown/unsupported. Older tablets ignore it.
`link` (additive, optional) = physical path of the session as the host sees it: `"usb-cable"` (adb reverse over the
cable), `"usb-wireless-adb"` (adb reverse over wireless debugging), `"usb-tether"` (TCP over the tablet's USB
tethering network), `"wifi"` (any LAN). Omitted when unknown. Tablets use it for labels only.
A host MAY send CONFIG again mid-stream with the same `mode` but a different `width`/`height` (adaptive encode size)
and/or `fps` (cadence). A size change is followed by codec-config + IDR at the new size; a tablet whose decoder
handles in-band resolution changes (adaptive playback) can keep its decoder. An `fps`-only change keeps the stream
(no new IDR); it tells the tablet the frame cadence it now receives (e.g. a steady 40 on a 120 Hz panel).If extend/primary mode is not available the host falls back to mirror and says so in CONFIG `mode`. CONFIG `mode` is one of "extend" | "primary" | "mirror".

### INPUT (tablet → host), binary
```
u8  count                         // number of pointers in this event (1..10)
then count × {
  u8  kind      // 0=touch 1=pen 2=mouse 3=scroll
  u8  action    // 0=down 1=move 2=up 3=cancel 4=hover-move 5=hover-exit
  u8  pointerId
  u8  buttons   // bit0 primary, bit1 secondary(pen barrel / right), bit2 eraser
  f32 x         // 0..1 normalized within the VIDEO frame (after removing letterbox)
  f32 y         // 0..1   (for kind=3 scroll: x,y = scroll delta in "notches", +y = up)
  f32 pressure  // 0..1
  f32 tiltX     // degrees, pen only else 0
  f32 tiltY
}
```
Every pointer's current state is included in each event (like Android MotionEvent). Host maps to: touch → Windows touch injection (InjectSyntheticPointerInput / InjectTouchInput) or SendInput mouse when touchMode="mouse"; pen → pen injection; macOS → CGEvent mouse events.
Robustness (clarification, both hosts): hosts parse `min(count, (payloadLength - 1) / 24)` pointers: a truncated event keeps its complete pointers, extra
trailing bytes are ignored, an empty payload or `count` 0 is a no-op (tablets must still send 1..10 complete pointers).
A pointer with an unknown `kind` is ignored; an unknown `action` is ignored for touch/pen and treated as a move for
mouse/scroll.

## Session flow
1. Tablet connects, sends HELLO.
2. Host may send PAIRING {waiting, code} → shows code on both screens → user approves on host → PAIRING {approved}.
3. Host sends CONFIG, then VIDEO starting with codec-config + keyframe.
4. Tablet on decoder error/reset sends REQUEST_KEYFRAME. Host sends IDR at least every 5 s anyway (low cost) — or only on request if configured.
5. PING every 1 s each way for RTT display; 5 s without any message = dead connection.
6. BYE on clean exit.

## Encoding guidance (host)
H.264 High/Main profile (Main/Baseline when HELLO `h264Profiles` lacks "high"), low-latency: no B-frames, CABAC ok, CBR/VBR at requested bitrate, 1 slice, realtime. Repeat SPS/PPS before every IDR. Over TCP nothing is lost silently, so periodic IDRs are only a slow safety net (big IDRs burst through adb tunnels); keep the VBV buffer ~2 frames so an IDR stays small. Only send frames when screen changed, but send at least 1 frame / 500 ms (so tablet knows it's alive) — re-sending last frame is fine.

## Ports
- TCP 47800 stream, UDP 47801 discovery.
