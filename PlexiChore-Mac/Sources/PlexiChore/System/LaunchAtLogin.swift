import Foundation
import ServiceManagement

/// "Open at login" via SMAppService.mainApp (macOS 13+). Requires running from a .app bundle.
enum LaunchAtLogin {
    static var isAvailable: Bool { Bundle.main.bundleIdentifier != nil && Bundle.main.bundlePath.hasSuffix(".app") }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var requiresApproval: Bool {
        SMAppService.mainApp.status == .requiresApproval
    }

    /// Open at login is on by default: registers once, on the first launch of the bundled app (like Windows'
    /// "Start with Windows"). Turning it off in Settings sticks. No System Settings prompt here.
    static func applyDefaultOnFirstLaunch() {
        let key = "launchAtLoginDefaultApplied"
        guard isAvailable, !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
    }

    /// Returns an error message on failure.
    static func set(_ enabled: Bool) -> String? {
        guard isAvailable else { return "Launch at login needs the bundled PlexiChore.app (see README)." }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled { try SMAppService.mainApp.register() }
            } else {
                if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            }
            if enabled && SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
                return "Approve PlexiChore in System Settings › General › Login Items."
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }
}
