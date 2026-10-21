import Foundation
import SystemConfiguration

/// Stable identity of this host (beacon `id`, CONFIG `hostName`).
enum HostIdentity {
    static let id: String = {
        let key = "hostId"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty { return existing }
        let new = UUID().uuidString.lowercased()
        UserDefaults.standard.set(new, forKey: key)
        return new
    }()

    static var computerName: String {
        if let name = SCDynamicStoreCopyComputerName(nil, nil) as String?, !name.isEmpty { return name }
        let h = ProcessInfo.processInfo.hostName
        return h.hasSuffix(".local") ? String(h.dropLast(6)) : h
    }
}

struct TrustedDevice: Codable, Identifiable, Hashable {
    var deviceId: String
    var name: String
    var model: String?
    var addedAt: Date
    var lastSeen: Date
    var id: String { deviceId }
}

/// Trusted tablets (approved once for Wi-Fi), persisted in UserDefaults.
enum TrustedDeviceStore {
    private static let key = "trustedDevices"

    static func load() -> [TrustedDevice] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let list = try? JSONDecoder().decode([TrustedDevice].self, from: data) else { return [] }
        return list
    }

    static func save(_ list: [TrustedDevice]) {
        if let data = try? JSONEncoder().encode(list) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}

/// Host-side preferences shown in the settings window.
struct HostPreferences: Codable, Equatable {
    var hiDPI = true
    var allowVirtualDisplay = true
    var requirePairing = true
    var wifiDiscovery = true
    var periodicKeyframes = true      // IDR every 5 s (otherwise only on request)
    var maxFps = 120
    var showStatsInMenu = true

    // --- Added for Windows UI parity (PlexiChore-Desktop AppSettings) ---
    /// Server paused from the sidebar / menu bar ("Pause server"). Persisted like Windows' `ServerPaused`.
    /// NEEDS CORE WIRING: HostController must stop/start HostServer + DiscoveryBeacon when this flips
    /// (and honour it at launch).
    var serverPaused = false
    /// "Notify when a tablet connects" (Windows `ShowConnectNotifications`). Wired in AppDelegate.
    var showConnectNotifications = true
    /// "Preferred video encoder": true = VideoToolbox hardware (recommended), false = software.
    /// NEEDS CORE WIRING: pass `kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder`
    /// / `EnableHardwareAcceleratedVideoEncoder = false` in Encode/H264Encoder.swift.
    var preferHardwareEncoder = true
    /// Virtual display scale used when the tablet's Display size is "Auto" (requested.scalePercent == 0):
    /// "auto" = Retina vs 1x from the tablet's densityDpi (Windows auto scale), "hidpi" = always Retina 2x,
    /// "standard" = always 1x. The UI keeps `hiDPI` in sync ("standard" -> false, otherwise true).
    /// NEEDS CORE WIRING for "auto" (pick HiDPI from densityDpi; today "auto" behaves like "hidpi").
    var displayScaleMode = "auto"
    /// Window appearance: "dark" (matches the Windows app, default) | "light" | "system". UI only.
    var appearance = "dark"
    /// Keep the tablet's virtual display when it is the only screen left (MacBook lid closed, no other monitor).
    /// Opt-in and honoured only on AC power; see `DisplaySafetyPolicy.decide`. Off = remove it after 10 s.
    var keepWithLidClosed = false

    private static let key = "hostPreferences"

    init() {}

    // Tolerant decoding: keys added in later versions fall back to their defaults.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = HostPreferences()
        hiDPI = try c.decodeIfPresent(Bool.self, forKey: .hiDPI) ?? d.hiDPI
        allowVirtualDisplay = try c.decodeIfPresent(Bool.self, forKey: .allowVirtualDisplay) ?? d.allowVirtualDisplay
        requirePairing = try c.decodeIfPresent(Bool.self, forKey: .requirePairing) ?? d.requirePairing
        wifiDiscovery = try c.decodeIfPresent(Bool.self, forKey: .wifiDiscovery) ?? d.wifiDiscovery
        periodicKeyframes = try c.decodeIfPresent(Bool.self, forKey: .periodicKeyframes) ?? d.periodicKeyframes
        maxFps = try c.decodeIfPresent(Int.self, forKey: .maxFps) ?? d.maxFps
        showStatsInMenu = try c.decodeIfPresent(Bool.self, forKey: .showStatsInMenu) ?? d.showStatsInMenu
        serverPaused = try c.decodeIfPresent(Bool.self, forKey: .serverPaused) ?? d.serverPaused
        showConnectNotifications = try c.decodeIfPresent(Bool.self, forKey: .showConnectNotifications) ?? d.showConnectNotifications
        preferHardwareEncoder = try c.decodeIfPresent(Bool.self, forKey: .preferHardwareEncoder) ?? d.preferHardwareEncoder
        displayScaleMode = try c.decodeIfPresent(String.self, forKey: .displayScaleMode) ?? d.displayScaleMode
        appearance = try c.decodeIfPresent(String.self, forKey: .appearance) ?? d.appearance
        keepWithLidClosed = try c.decodeIfPresent(Bool.self, forKey: .keepWithLidClosed) ?? d.keepWithLidClosed
    }

    static func load() -> HostPreferences {
        guard let data = UserDefaults.standard.data(forKey: key),
              let p = try? JSONDecoder().decode(HostPreferences.self, from: data) else { return HostPreferences() }
        return p
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
