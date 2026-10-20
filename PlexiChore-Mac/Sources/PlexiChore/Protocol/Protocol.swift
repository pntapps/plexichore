import Foundation

/// PlexiChore wire protocol v1 — see PROTOCOL.md (authoritative).
/// Every TCP message: `u8 type | u32 length (big-endian) | payload[length]`.
enum PlexiProtocol {
    static let version = 1
    static let tcpPort: UInt16 = 47800
    static let udpPort: UInt16 = 47801
    static let maxPayload = 16 * 1024 * 1024
    static let headerSize = 5
    static let discoveryQuery = "PLEXI?"
}

enum MessageType: UInt8 {
    case hello = 0x01
    case config = 0x02
    case video = 0x03
    case input = 0x04
    case key = 0x05
    case ping = 0x06
    case pong = 0x07
    case requestKeyframe = 0x08
    case settings = 0x09
    case bye = 0x0A
    case stats = 0x0B
    case pairing = 0x0C
}

struct VideoFlags: OptionSet {
    let rawValue: UInt8
    static let keyframe = VideoFlags(rawValue: 1 << 0)
    static let codecConfig = VideoFlags(rawValue: 1 << 1)
}

// MARK: - Big-endian helpers

extension Data {
    mutating func appendBE(_ v: UInt8) { append(v) }
    mutating func appendBE(_ v: UInt32) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }
    mutating func appendBE(_ v: UInt64) {
        var be = v.bigEndian
        Swift.withUnsafeBytes(of: &be) { append(contentsOf: $0) }
    }

    /// Reads relative to `startIndex` (safe for slices).
    func u8(at offset: Int) -> UInt8 { self[startIndex + offset] }

    func u32BE(at offset: Int) -> UInt32 {
        var v: UInt32 = 0
        for i in 0..<4 { v = (v << 8) | UInt32(self[startIndex + offset + i]) }
        return v
    }

    func u64BE(at offset: Int) -> UInt64 {
        var v: UInt64 = 0
        for i in 0..<8 { v = (v << 8) | UInt64(self[startIndex + offset + i]) }
        return v
    }

    func f32BE(at offset: Int) -> Float {
        Float(bitPattern: u32BE(at: offset))
    }
}

enum Frame {
    /// Builds a complete framed message.
    static func make(_ type: MessageType, _ payload: Data = Data()) -> Data {
        var d = Data(capacity: PlexiProtocol.headerSize + payload.count)
        d.append(type.rawValue)
        d.appendBE(UInt32(payload.count))
        d.append(payload)
        return d
    }

    /// VIDEO payload: `u64 ptsMicros, u8 flags, bytes data`.
    static func video(ptsMicros: UInt64, flags: VideoFlags, data: Data) -> Data {
        var payload = Data(capacity: 9 + data.count)
        payload.appendBE(ptsMicros)
        payload.append(flags.rawValue)
        payload.append(data)
        return make(.video, payload)
    }

    static func json<T: Encodable>(_ type: MessageType, _ value: T) -> Data {
        let encoder = JSONEncoder()
        let payload = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return make(type, payload)
    }

    static func text(_ type: MessageType, _ s: String) -> Data {
        make(type, Data(s.utf8))
    }
}

// MARK: - JSON models

/// `requested` object of HELLO, also the (partial) payload of SETTINGS. All optional so partial
/// updates decode cleanly and unknown/missing keys never fail.
struct RequestedSettings: Codable, Equatable {
    var mode: String?            // "extend" | "mirror"
    var monitorIndex: Int?
    var resolutionScale: Double?
    var fps: Int?
    var bitrateKbps: Int?
    var quality: String?         // "performance" | "balanced" | "quality"
    var codec: String?           // "h264" | "mjpeg"
    var touchMode: String?       // "touch" | "mouse" | "none"
    var position: String?        // "right" | "left" | "top" | "bottom"

    /// Returns self overlaid with every non-nil field of `other`.
    func merged(with other: RequestedSettings) -> RequestedSettings {
        var r = self
        if let v = other.mode { r.mode = v }
        if let v = other.monitorIndex { r.monitorIndex = v }
        if let v = other.resolutionScale { r.resolutionScale = v }
        if let v = other.fps { r.fps = v }
        if let v = other.bitrateKbps { r.bitrateKbps = v }
        if let v = other.quality { r.quality = v }
        if let v = other.codec { r.codec = v }
        if let v = other.touchMode { r.touchMode = v }
        if let v = other.position { r.position = v }
        return r
    }

    static let defaults = RequestedSettings(
        mode: "extend", monitorIndex: 0, resolutionScale: 1.0, fps: 60, bitrateKbps: 20_000,
        quality: "balanced", codec: "h264", touchMode: "touch", position: "right")
}

struct HelloMessage: Codable {
    var `protocol`: Int?
    var deviceId: String?
    var deviceName: String?
    var model: String?
    var widthPx: Int?
    var heightPx: Int?
    var densityDpi: Int?
    var refreshHz: Double?
    var codecs: [String]?
    var maxDecodeWidth: Int?
    var maxDecodeHeight: Int?
    var touch: Bool?
    var pen: Bool?
    var requested: RequestedSettings?
}

struct MonitorInfo: Codable, Equatable, Identifiable, Hashable {
    var index: Int
    var name: String
    var width: Int
    var height: Int
    var id: Int { index }
}

struct ConfigMessage: Codable, Equatable {
    var codec: String
    var width: Int
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    var mode: String
    var hostName: String
    var hostOs: String
    var monitors: [MonitorInfo]
    var virtualDisplayAvailable: Bool
}

struct PairingMessage: Codable {
    var status: String      // "waiting" | "approved" | "rejected"
    var code: String
}

struct StatsMessage: Codable {
    var captureFps: Double
    var encodeMs: Double
    var bitrateKbps: Double
}

struct KeyMessage: Codable {
    var action: String?     // "down" | "up"
    var keyCode: Int?
    var text: String?
}

struct BeaconMessage: Codable {
    var svc = "plexichore"
    var v = 1
    var id: String
    var name: String
    var os = "macos"
    var port = Int(PlexiProtocol.tcpPort)
    var virtualDisplay: Bool
}

// MARK: - INPUT

enum PointerKind: UInt8 { case touch = 0, pen = 1, mouse = 2, scroll = 3 }
enum PointerAction: UInt8 { case down = 0, move = 1, up = 2, cancel = 3, hoverMove = 4, hoverExit = 5 }

struct PointerState {
    var kind: PointerKind
    var action: PointerAction
    var pointerId: UInt8
    var buttons: UInt8
    var x: Float
    var y: Float
    var pressure: Float
    var tiltX: Float
    var tiltY: Float

    var primaryButton: Bool { buttons & 0x01 != 0 }
    var secondaryButton: Bool { buttons & 0x02 != 0 }
    var eraser: Bool { buttons & 0x04 != 0 }
}

enum InputParser {
    static let pointerSize = 4 + 5 * 4   // 4 x u8 + 5 x f32 = 24 bytes

    /// Parses an INPUT payload. Returns nil when malformed.
    static func parse(_ payload: Data) -> [PointerState]? {
        guard payload.count >= 1 else { return nil }
        let count = Int(payload.u8(at: 0))
        guard count >= 1, count <= 10, payload.count >= 1 + count * pointerSize else { return nil }
        var result: [PointerState] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let o = 1 + i * pointerSize
            guard let kind = PointerKind(rawValue: payload.u8(at: o)),
                  let action = PointerAction(rawValue: payload.u8(at: o + 1)) else { continue }
            let p = PointerState(
                kind: kind,
                action: action,
                pointerId: payload.u8(at: o + 2),
                buttons: payload.u8(at: o + 3),
                x: payload.f32BE(at: o + 4),
                y: payload.f32BE(at: o + 8),
                pressure: payload.f32BE(at: o + 12),
                tiltX: payload.f32BE(at: o + 16),
                tiltY: payload.f32BE(at: o + 20))
            result.append(p)
        }
        return result
    }
}

// MARK: - Time

enum Clock {
    /// Monotonic microseconds (mach uptime based).
    static func nowMicros() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds / 1_000
    }
}
