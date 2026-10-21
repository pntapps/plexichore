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
    // Additive (PROTOCOL.md): 0 = auto, else 100|125|...|300 (snapped by SessionPolicy.sanitizeScaleRequest).
    var scalePercent: Int?
    // Additive: "landscape" (default) | "portrait"; also sent alone in SETTINGS when the tablet rotates.
    var orientation: String?

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
        if let v = other.scalePercent { r.scalePercent = v }
        if let v = other.orientation { r.orientation = v }
        return r
    }

    /// Values for fields a HELLO `requested` object leaves out — Windows `RequestedSettings` property initializers
    /// (Protocol.cs). In particular a HELLO without `requested.mode` (or without `requested`) means **mirror**, like
    /// Windows; PROTOCOL.md documents this. Android always sends `mode`.
    static let defaults = RequestedSettings(
        mode: "mirror", monitorIndex: 0, resolutionScale: 1.0, fps: 60, bitrateKbps: 20_000,
        quality: "balanced", codec: "h264", touchMode: "touch", position: "right",
        scalePercent: 0, orientation: "landscape")

    /// The session's initial `requested` from a HELLO: `defaults` overlaid with what the tablet sent
    /// (Windows: `_hello.Requested ??= new RequestedSettings()` → missing members keep their initializers).
    static func initial(from hello: HelloMessage) -> RequestedSettings {
        defaults.merged(with: hello.requested ?? RequestedSettings())
    }
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
    // ---- additive, optional (older tablets don't send them) ----
    /// Sizes the decoder really handles (landscape; rotated sizes equally valid) with their max fps.
    var decodeModes: [DecodeMode]?
    /// H.264 profiles the decoder supports, best first ("high", "main", "baseline").
    var h264Profiles: [String]?
    /// Highest H.264 level, e.g. "5.1" (Android sends "" when unknown).
    var h264MaxLevel: String?
    /// Orientation at connect time: "landscape" | "portrait".
    var orientation: String?
    /// Current display window size (split screen / freeform / DeX may be smaller than widthPx/heightPx).
    var viewportWidthPx: Int?
    var viewportHeightPx: Int?
}

/// One entry of HELLO `decodeModes`.
struct DecodeMode: Codable, Equatable {
    var width: Int
    var height: Int
    var maxFps: Int
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
    // ---- additive, optional (omitted from JSON when nil) ----
    /// Encoder in use (informational), e.g. "hw:VideoToolbox H.264".
    var encoder: String? = nil
    /// Display scale applied to the virtual display in percent; 0 = mirror / unknown.
    var scalePercent: Int? = nil
    /// "usb-cable" | "usb-wireless-adb" | "usb-tether" | "wifi"; nil = unknown (omitted).
    var link: String? = nil
}

struct PairingMessage: Codable {
    var status: String      // "waiting" | "approved" | "rejected"
    var code: String
}

struct StatsMessage: Codable {
    var captureFps: Double      // frames encoded + sent per second, 1 decimal (Windows: Math.Round(fps, 1))
    var encodeMs: Double        // 2 decimals (Windows: Math.Round(encMs, 2))
    var bitrateKbps: Int        // integer like Windows `int BitrateKbps`
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

// MARK: - Lenient JSON decoding (Windows parity: Wire.Json = case-insensitive keys, numbers from strings)

/// Any JSON value. Decoding never fails on a type, so one odd field can't reject a whole HELLO / SETTINGS
/// (Windows `JsonSerializerOptions { PropertyNameCaseInsensitive, AllowReadingFromString }`).
enum JSONValue: Decodable, Equatable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let d = try? c.decode(Double.self) { self = .number(d) }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else if let o = try? c.decode([String: JSONValue].self) { self = .object(o) }
        else { self = .null }
    }

    var intValue: Int? {
        switch self {
        case .number(let d): return d.isFinite && abs(d) < 1e15 ? Int(d.rounded(.toNearestOrEven)) : nil
        case .string(let s):
            let t = s.trimmingCharacters(in: .whitespaces)
            if let i = Int(t) { return i }
            if let d = Double(t), d.isFinite, abs(d) < 1e15 { return Int(d.rounded(.toNearestOrEven)) }
            return nil
        default: return nil
        }
    }

    var doubleValue: Double? {
        switch self {
        case .number(let d): return d
        case .string(let s): return Double(s.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    var stringValue: String? {
        switch self {
        case .string(let s): return s
        case .number(let d): return d == d.rounded() && abs(d) < 1e15 ? String(Int(d)) : String(d)
        case .bool(let b): return b ? "true" : "false"
        default: return nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case .bool(let b): return b
        case .number(let d): return d != 0
        case .string(let s):
            switch s.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "1": return true
            case "false", "0": return false
            default: return nil
            }
        default: return nil
        }
    }
}

/// Coding key for arbitrary member names.
struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}

/// A JSON object with case-insensitive member lookup; `null` members count as absent.
struct LenientObject {
    private var members: [String: JSONValue] = [:]

    init(_ decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyCodingKey.self)   // throws when the payload isn't an object
        for key in c.allKeys {
            guard let v = try? c.decode(JSONValue.self, forKey: key), v != .null else { continue }
            members[key.stringValue.lowercased()] = v
        }
    }

    init(_ members: [String: JSONValue]) {
        for (k, v) in members where v != .null { self.members[k.lowercased()] = v }
    }

    subscript(_ key: String) -> JSONValue? { members[key.lowercased()] }
    func int(_ key: String) -> Int? { self[key]?.intValue }
    func double(_ key: String) -> Double? { self[key]?.doubleValue }
    func string(_ key: String) -> String? { self[key]?.stringValue }
    func bool(_ key: String) -> Bool? { self[key]?.boolValue }
    func strings(_ key: String) -> [String]? {
        guard case .array(let a)? = self[key] else { return nil }
        return a.compactMap(\.stringValue)
    }
    func object(_ key: String) -> LenientObject? {
        guard case .object(let o)? = self[key] else { return nil }
        return LenientObject(o)
    }
    func objects(_ key: String) -> [LenientObject]? {
        guard case .array(let a)? = self[key] else { return nil }
        return a.compactMap { if case .object(let o) = $0 { return LenientObject(o) } else { return nil } }
    }
}

extension RequestedSettings {
    init(from decoder: Decoder) throws {
        self.init(try LenientObject(decoder))
    }

    init(_ o: LenientObject) {
        self.init()
        mode = o.string("mode")
        monitorIndex = o.int("monitorIndex")
        resolutionScale = o.double("resolutionScale")
        fps = o.int("fps")
        bitrateKbps = o.int("bitrateKbps")
        quality = o.string("quality")
        codec = o.string("codec")
        touchMode = o.string("touchMode")
        position = o.string("position")
        scalePercent = o.int("scalePercent")
        orientation = o.string("orientation")
    }
}

extension DecodeMode {
    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        self.init(o)
    }

    init(_ o: LenientObject) {
        self.init(width: o.int("width") ?? 0, height: o.int("height") ?? 0, maxFps: o.int("maxFps") ?? 0)
    }
}

extension HelloMessage {
    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        self.init()
        `protocol` = o.int("protocol")
        deviceId = o.string("deviceId")
        deviceName = o.string("deviceName")
        model = o.string("model")
        widthPx = o.int("widthPx")
        heightPx = o.int("heightPx")
        densityDpi = o.int("densityDpi")
        refreshHz = o.double("refreshHz")
        codecs = o.strings("codecs")
        maxDecodeWidth = o.int("maxDecodeWidth")
        maxDecodeHeight = o.int("maxDecodeHeight")
        touch = o.bool("touch")
        pen = o.bool("pen")
        requested = o.object("requested").map(RequestedSettings.init(_:))
        decodeModes = o.objects("decodeModes")?.map(DecodeMode.init(_:))
        h264Profiles = o.strings("h264Profiles")
        h264MaxLevel = o.string("h264MaxLevel")
        orientation = o.string("orientation")
        viewportWidthPx = o.int("viewportWidthPx")
        viewportHeightPx = o.int("viewportHeightPx")
    }
}

extension KeyMessage {
    init(from decoder: Decoder) throws {
        let o = try LenientObject(decoder)
        self.init(action: o.string("action"), keyCode: o.int("keyCode"), text: o.string("text"))
    }
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

    /// Parses an INPUT payload exactly like Windows `PointerSample.Parse` (Protocol.cs): an empty payload yields no
    /// pointers, and `count` is clamped to the whole 24-byte records actually present — `min(count, (len - 1) / 24)` —
    /// so a truncated event still delivers its complete pointers (no 1...10 range check either; trailing bytes are
    /// ignored). Unknown values follow what Windows' InputInjector does with them: an unknown kind is skipped; an
    /// unknown action is skipped for touch/pen (their switches have no default) but behaves like a move for mouse
    /// (`HandleMouse` presses `buttons` for any action other than down/up/cancel) and scroll (`HandleScroll` ignores
    /// the action).
    static func parse(_ payload: Data) -> [PointerState] {
        guard payload.count >= 1 else { return [] }
        let count = min(Int(payload.u8(at: 0)), (payload.count - 1) / pointerSize)
        var result: [PointerState] = []
        result.reserveCapacity(count)
        for i in 0..<count {
            let o = 1 + i * pointerSize
            guard let kind = PointerKind(rawValue: payload.u8(at: o)) else { continue }
            let action: PointerAction
            if let a = PointerAction(rawValue: payload.u8(at: o + 1)) { action = a }
            else if kind == .mouse || kind == .scroll { action = .move }
            else { continue }
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
