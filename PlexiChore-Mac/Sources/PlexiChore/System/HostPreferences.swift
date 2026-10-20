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
