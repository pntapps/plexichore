# CLAUDE.md — PlexiChore (monorepo)

PlexiChore turns an Android tablet into a portable monitor (extend / primary / mirror) for Windows and macOS. Read this first, then the component CLAUDE.md you're working in, then `ROADMAP.md` for what to do next.

## Layout
- `PROTOCOL.md` — **authoritative wire protocol** (TCP 47800 stream, UDP 47801 discovery, big-endian `u8 type | u32 len | payload`). Every host and the tablet must match it byte-for-byte. Changes are **additive only** (new optional JSON fields with defaults), and must be implemented in all three components or documented as "not yet" in the lagging one.
- `PlexiChore/` — Android app (Kotlin/Compose). See `PlexiChore/CLAUDE.md`.
- `PlexiChore-Desktop/` — Windows host (.NET 10 WPF + Engine + tools). See `PlexiChore-Desktop/CLAUDE.md`.
- `PlexiChore-Mac/` — macOS host (Swift, **never compiled yet**). See `PlexiChore-Mac/CLAUDE.md`.
- `ROADMAP.md` — status, prioritized TODO, known limits. **Update it when you finish or discover something.**

## Architecture in one paragraph
Host = TCP server. Tablet discovers hosts via UDP beacons (or probes 127.0.0.1:47800 for USB via `adb reverse`), sends HELLO (display size, densityDpi, decoder caps, requested mode/fps/bitrate/scale/orientation), host replies CONFIG then streams VIDEO (H.264 Annex-B; SPS/PPS before IDR, flag bit1 = codec config) and receives INPUT (normalized pointer events). Extend/Primary require a *virtual monitor* on the host: Windows uses the signed open-source Virtual Display Driver (IddCx "MttVDD"); macOS uses the private `CGVirtualDisplay` API.

## Shared contracts (keep in sync)
- Android: `PlexiChore/app/src/main/java/com/pntapps/plexichore/core/Contracts.kt` (core ↔ UI API).
- Windows: `PlexiChore-Desktop/src/PlexiChore.Engine/Contracts.cs` (Engine ↔ App; `IVirtualDisplayProvider` uses default interface methods for additive members — **also forward new members in `Streaming/VirtualDisplayLeases.cs`**).

## Working rules learned the hard way
- **One physical tablet and one port 47800**: never run two things that use the tablet or the host port at the same time (parallel agents corrupted each other's benchmarks). Always pass `adb -s <serial>` — a tablet often shows up twice (USB serial + `adb-<serial>-xxxx._adb-tls-connect._tcp` wireless).
- **Never approve pairing prompts by UI automation and never change firewall rules** — those are the user's security decisions. Ask the user.
- Elevated actions (driver install/repair/restart) show a UAC prompt; ask the user before triggering them.
- Virtual Display Driver gotchas (see `PlexiChore-Desktop/driver/README.md`): no `RELOAD_DRIVER`-type pipe commands (crash), keep the mode list small (≤ ~48 generated modes), mode changes need elevated `pnputil /restart-device`.
- Don't commit benchmark run folders (`PlexiChore-Desktop/tools/Bench/results/*/`) — they contain screenshots of the user's desktop. `results.md` is fine.
- Don't commit `local.properties`, keystores, `settings.json` from `%APPDATA%`, or `dist/`/`artifacts/`.
- Measure smoothness with the bench harness (`PlexiChore-Desktop/tools/Bench/bench.ps1`), not by eye. A "stutter" = frame gap > 2× interval; the Tab S8 panel is 120 Hz so 25 ms gaps are normal 1-refresh slips.

## Where to continue
1. On a **Mac**: `PlexiChore-Mac/CLAUDE.md` → get it compiling, then end-to-end with the tablet, then protocol parity.
2. On a **Windows PC**: build/publish desktop, build/install Android, then pick from `ROADMAP.md` P0/P1 (release readiness, CI, keyboard forwarding, rotation polish).
3. Before any protocol change: edit `PROTOCOL.md` first, then Android core `Protocol.kt`, Windows `Engine/Protocol/Protocol.cs`, Mac `Sources/PlexiChore/Protocol/Protocol.swift`.

## Owner / accounts
GitHub: `pntapps` (pntapps.dev@gmail.com). Android package `com.pntapps.plexichore`.
