import Foundation

/// Pure parsing / decision helpers for the adb integration (no I/O, deterministic, unit-testable).
/// Windows counterparts: PlexiChore-Desktop/src/PlexiChore.App/Services/Adb/AdbDevice.cs (AdbParser) and the
/// reverse bookkeeping in AdbManager.LoopAsync. Serial classification and the reverse-owner → link mapping are
/// delegated to `SessionPolicy` so CONFIG `link` and the USB page always agree.
enum ADBParsing {

    // MARK: - `adb devices -l`

    /// One line of `adb devices -l`.
    struct DeviceLine: Equatable {
        var serial: String
        /// "device" | "unauthorized" | "authorizing" | "offline" | "connecting" | "no permissions" | "recovery" | ...
        var state: String
        /// Known `key:value` attributes (usb, product, model, device, transport_id). Keys are lowercase.
        var props: [String: String] = [:]

        /// Model with adb's underscores turned back into spaces ("SM_X700" → "SM X700").
        var model: String? { props["model"].map { $0.replacingOccurrences(of: "_", with: " ") } }
        var product: String? { props["product"] }
        var deviceName: String? { props["device"] }
        var transportId: String? { props["transport_id"] }
        var isReady: Bool { state == "device" }
        /// Wireless debugging (mDNS tls-connect / `adb connect ip:port`) vs a physical cable.
        var isWireless: Bool { ADBParsing.isWireless(serial) }
    }

    /// Attribute keys accepted from `devices -l`. Anything else (e.g. the "[http://…]" hint printed after
    /// "no permissions") is ignored.
    static let knownDeviceKeys: Set<String> = ["usb", "product", "model", "device", "transport_id", "features"]

    /// Parses `adb devices -l` (also plain `adb devices` and track-devices payloads, which are tab separated).
    /// Skips the header, "* daemon …" notices, "adb server version (…) doesn't match …" and "error:" lines.
    /// A serial listed twice keeps its first line.
    static func parseDevices(_ output: String) -> [DeviceLine] {
        var result: [DeviceLine] = []
        var seen = Set<String>()
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()
            if line.isEmpty || lower.hasPrefix("list of devices") || line.hasPrefix("*") ||
                lower.hasPrefix("adb ") || lower.hasPrefix("adb:") || lower.hasPrefix("error:") ||
                lower.hasPrefix("- waiting") || lower.hasPrefix("cannot ") { continue }
            let tokens = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard tokens.count >= 2 else { continue }
            let serial = tokens[0]
            let state: String
            var i: Int
            if tokens[1] == "no", tokens.count > 2, tokens[2].hasPrefix("permissions") {
                state = "no permissions"
                i = 3
            } else {
                state = tokens[1]
                i = 2
            }
            var props: [String: String] = [:]
            while i < tokens.count {
                let t = tokens[i]
                if let c = t.firstIndex(of: ":"), c != t.startIndex {
                    let key = t[..<c].lowercased()
                    if knownDeviceKeys.contains(key) { props[key] = String(t[t.index(after: c)...]) }
                }
                i += 1
            }
            if seen.insert(serial).inserted {
                result.append(DeviceLine(serial: serial, state: state, props: props))
            }
        }
        return result
    }

    // MARK: - Device state

    enum StateKind: String, Equatable {
        case ready            // "device"
        case unauthorized     // "unauthorized", "authorizing": waiting for "Allow USB debugging?"
        case offline          // "offline", "connecting"
        case noPermissions    // "no permissions"
        case bootMode         // recovery / sideload / bootloader / rescue
        case other
    }

    static func stateKind(_ state: String) -> StateKind {
        switch state.lowercased() {
        case "device": return .ready
        case "unauthorized", "authorizing": return .unauthorized
        case "offline", "connecting": return .offline
        case "no permissions": return .noPermissions
        case "recovery", "sideload", "bootloader", "rescue": return .bootMode
        default: return .other
        }
    }

    // MARK: - Serial classification (AdbDevice.IsWireless / PhysicalSerial)

    static func isWireless(_ serial: String) -> Bool { SessionPolicy.isWirelessAdbSerial(serial) }

    /// Hardware serial behind a transport: the serial itself for a cable, the one embedded in an mDNS name
    /// ("adb-<serial>-<id>._adb-tls-connect._tcp"); nil for "ip:port" (resolve with `adb -s … get-serialno`).
    static func hardwareSerial(_ serial: String) -> String? { SessionPolicy.physicalAdbSerial(serial) }

    /// Grouping key: resolved serial (get-serialno cache) → embedded serial → the transport serial. Uppercased.
    static func tabletKey(_ serial: String, resolved: [String: String] = [:]) -> String {
        (resolved[serial] ?? hardwareSerial(serial) ?? serial).uppercased()
    }

    /// `adb -s <serial> get-serialno` output → serial, nil for empty / "unknown" / errors.
    static func parseSerialNo(_ output: String) -> String? {
        let s = output.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        if s.isEmpty || s.lowercased() == "unknown" || s.lowercased().hasPrefix("error") || s.contains(" ") { return nil }
        return s
    }

    // MARK: - Dedupe (one tablet on cable + wireless debugging)

    struct TabletGroup: Equatable {
        var key: String
        /// The transport to show / use: ready before not ready, cable before wireless, then adb order.
        var primary: DeviceLine
        /// Other transports of the same tablet (e.g. the wireless-debugging twin of a cable).
        var twins: [DeviceLine]
        var members: [DeviceLine] { [primary] + twins }
    }

    /// Groups transports by physical tablet. Groups keep the order of their first transport in `lines`.
    static func groupByTablet(_ lines: [DeviceLine], resolved: [String: String] = [:]) -> [TabletGroup] {
        var order: [String] = []
        var buckets: [String: [(Int, DeviceLine)]] = [:]
        for (i, l) in lines.enumerated() {
            let k = tabletKey(l.serial, resolved: resolved)
            if buckets[k] == nil { order.append(k) }
            buckets[k, default: []].append((i, l))
        }
        return order.map { k in
            let sorted = buckets[k]!.sorted { a, b in
                let ra = (a.1.isReady ? 0 : 1, a.1.isWireless ? 1 : 0, a.0)
                let rb = (b.1.isReady ? 0 : 1, b.1.isWireless ? 1 : 0, b.0)
                return ra < rb
            }.map(\.1)
            return TabletGroup(key: k, primary: sorted[0], twins: Array(sorted.dropFirst()))
        }
    }

    // MARK: - Reverse plan (AdbManager.LoopAsync)

    struct ReversePlan: Equatable {
        /// Ready transports that should carry `reverse tcp:47800`, wireless first and cables last (so if a
        /// wireless twin could not be matched the cable still ends up owning the device-side listener).
        var targets: [String]
        /// Ready wireless transports skipped because the same tablet is ready on a cable. Never run
        /// `reverse --remove` on them: adbd has one listener per device port and that would delete the cable's.
        var cableTwinned: [String]
    }

    static func reversePlan(_ lines: [DeviceLine], resolved: [String: String] = [:]) -> ReversePlan {
        let ready = lines.filter(\.isReady)
        let cabled = Set(ready.filter { !$0.isWireless }.map { tabletKey($0.serial, resolved: resolved) })
        func hasCableTwin(_ d: DeviceLine) -> Bool {
            d.isWireless && (resolved[d.serial] ?? hardwareSerial(d.serial)) != nil
                && cabled.contains(tabletKey(d.serial, resolved: resolved))
        }
        let twinned = ready.filter(hasCableTwin).map(\.serial)
        let targets = ready.filter { !hasCableTwin($0) }.enumerated()
            .sorted { ($0.element.isWireless ? 0 : 1, $0.offset) < ($1.element.isWireless ? 0 : 1, $1.offset) }
            .map(\.element.serial)
        return ReversePlan(targets: targets, cableTwinned: twinned)
    }

    // MARK: - `adb reverse --list`

    struct ReverseEntry: Equatable {
        /// Device-side transport that owns the listener: "UsbFfs" (cable), "host-19" (wireless / TCP), …
        var owner: String
        var remote: String   // device side, "tcp:47800"
        var local: String    // host side,   "tcp:47800"
    }

    /// Parses `adb reverse --list` ("UsbFfs tcp:47800 tcp:47800" per line).
    static func parseReverseList(_ output: String) -> [ReverseEntry] {
        output.split(whereSeparator: \.isNewline).compactMap { raw in
            let t = raw.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard t.count >= 3, t[t.count - 1].contains(":"), t[t.count - 2].contains(":") else { return nil }
            return ReverseEntry(owner: t[0], remote: t[t.count - 2], local: t[t.count - 1])
        }
    }

    /// AdbParser.HasReverse: the PlexiChore mapping tcp:port → tcp:port is listed.
    static func hasReverse(_ output: String, port: Int = Int(PlexiProtocol.tcpPort)) -> Bool {
        parseReverseList(output).contains {
            $0.remote.lowercased() == "tcp:\(port)" && $0.local.lowercased() == "tcp:\(port)"
        }
    }

    /// Periodic verification: is the reverse still in place for this transport? A cable must also *own* the listener —
    /// adbd keeps one per device port, so a wireless twin that reversed later (e.g. wireless debugging reconnected while
    /// plugged in) silently moves the stream onto Wi-Fi while `--list` still shows the rule on both transports.
    static func reverseHeld(_ output: String, wireless: Bool, port: Int = Int(PlexiProtocol.tcpPort)) -> Bool {
        wireless ? hasReverse(output, port: port) : reverseLink(output, port: port) == .usbCable
    }

    /// AdbParser.ReverseLink: which transport serves the reverse (see `SessionPolicy.reverseLink`).
    static func reverseLink(_ output: String, port: Int = Int(PlexiProtocol.tcpPort)) -> SessionPolicy.Link? {
        SessionPolicy.reverseLink(reverseListOutput: output, port: port)
    }

    // MARK: - Versions

    struct ClientVersion: Equatable {
        /// The "1.0.41" protocol number (41) — what the adb client compares against the running server.
        var protocolVersion: Int
        /// Platform-tools release, e.g. "37.0.1-15733141".
        var release: String?
    }

    /// Parses `adb version`:
    ///   Android Debug Bridge version 1.0.41
    ///   Version 37.0.1-15733141
    static func parseClientVersion(_ output: String) -> ClientVersion? {
        var proto: Int?
        var release: String?
        for raw in output.split(whereSeparator: \.isNewline) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("Android Debug Bridge version"), let last = l.split(separator: " ").last {
                proto = last.split(separator: ".").last.flatMap { Int($0) }
            } else if l.hasPrefix("Version "), release == nil {
                release = String(l.dropFirst("Version ".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        return proto.map { ClientVersion(protocolVersion: $0, release: release) }
    }

    /// Reply of the adb server to "000chost:version": "OKAY" + 4 hex length + hex version ("OKAY00040029" → 41).
    static func parseServerVersionReply(_ reply: String) -> Int? {
        guard reply.hasPrefix("OKAY") else { return nil }
        let body = reply.dropFirst(4)
        guard body.count >= 4, let len = Int(body.prefix(4), radix: 16), len > 0, body.count >= 4 + len else { return nil }
        return Int(body.dropFirst(4).prefix(len), radix: 16)
    }

    /// Splits `adb track-devices` output (repeated "<4 hex length><payload>") into payloads, consuming complete
    /// frames from `buffer` and leaving a partial frame in it. `malformed` = garbage was found and dropped
    /// (the buffer is then cleared); treat it as "something changed".
    static func takeTrackFrames(_ buffer: inout [UInt8]) -> (frames: [String], malformed: Bool) {
        var frames: [String] = []
        var i = 0
        while buffer.count - i >= 4 {
            guard let header = String(bytes: buffer[i..<i + 4], encoding: .ascii),
                  let len = Int(header, radix: 16) else {
                buffer.removeAll()
                return (frames, true)
            }
            guard buffer.count - i - 4 >= len else { break }
            frames.append(String(decoding: buffer[(i + 4)..<(i + 4 + len)], as: UTF8.self))
            i += 4 + len
        }
        buffer.removeFirst(i)
        return (frames, false)
    }

    // MARK: - Retry policy

    /// Exponential backoff: 0 failures → 0, then base, 2·base, 4·base, … capped at `cap`.
    static func backoff(failures: Int, base: TimeInterval, cap: TimeInterval) -> TimeInterval {
        guard failures > 0 else { return 0 }
        return min(cap, base * pow(2, Double(min(failures - 1, 16))))
    }

    /// First line of a tool's stderr/stdout, trimmed, for status messages ("error: device offline").
    static func firstMessageLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("*") }
    }

    /// adb printed that it restarted a server of another version ("adb server version (40) doesn't match this
    /// client (41); killing...").
    static func reportsServerVersionKill(_ text: String) -> Bool {
        text.contains("doesn't match this client") || text.contains("does not match this client")
    }
}
