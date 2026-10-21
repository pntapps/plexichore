import AppKit
import Combine
import CoreGraphics
import Foundation

// UI-facing derived state, a port of PlexiChore-Desktop MainViewModel / SessionViewModel / AdbDeviceViewModel.
// The views talk to `HostUIModel` / `ADBUIModel` (HostController / ADBManager conform below) so they can also be
// rendered with fake state in tests (Tests/PlexiChoreTests/UIRenderTests.swift) without starting anything.
// Only uses HostController's public API so it never conflicts with core edits.

enum ServerUIState { case starting, online, paused, error, stopped }

/// Extended display availability (Windows: VddState).
enum ExtendState { case ready, inUse, disabled, unsupported }

/// The PlexiChore virtual display currently attached (Windows: VirtualDisplayDriverProvider.ActiveMonitors).
struct VirtualScreenInfo: Equatable {
    let name: String
    let displayID: CGDirectDisplayID
    let pixelWidth: Int
    let pixelHeight: Int
    let pointWidth: Int
    let pointHeight: Int
    let isMain: Bool
    var scaleFactor: Double { pointWidth > 0 ? Double(pixelWidth) / Double(pointWidth) : 1 }
}

/// What the main window needs from the host (raw state + actions). Everything derived lives in the extension.
@MainActor
protocol HostUIModel: ObservableObject where ObjectWillChangePublisher == ObservableObjectPublisher {
    associatedtype ADB: ADBUIModel
    var adb: ADB { get }

    var serverStatus: String { get }
    var serverListening: Bool { get }
    var sessions: [SessionSummary] { get }
    var pendingPairings: [PendingPairing] { get }
    var trustedDevices: [TrustedDevice] { get }
    var screenRecordingGranted: Bool { get }
    var accessibilityGranted: Bool { get }
    var launchAtLogin: Bool { get }
    var lastMessage: String? { get }
    var localAddresses: [String] { get }
    var prefs: HostPreferences { get set }
    var virtualDisplaySupported: Bool { get }
    var hostName: String { get }
    var hostId: String { get }
    var appVersion: String { get }
    var displaySafetyHoldRemaining: TimeInterval? { get }
    var virtualDisplayActive: Bool { get }
    var activeVirtualScreen: VirtualScreenInfo? { get }

    func requestScreenRecording()
    func requestAccessibility()
    func setLaunchAtLogin(_ enabled: Bool)
    func removeTrusted(_ device: TrustedDevice)
    func emergencyReleaseDisplay()
    func clearDisplaySafetyHold()
    func disconnect(_ id: UUID)
}

/// What the USB page needs from ADBManager.
@MainActor
protocol ADBUIModel: ObservableObject {
    var adbPath: String? { get }
    var adbVersion: String? { get }
    var devices: [ADBManager.Device] { get }
    var status: String { get }
    var downloading: Bool { get }
    var enabled: Bool { get set }
    var phase: ADBManager.Phase { get }
    var lastFailure: String? { get }

    func refresh()
    func reapplyForwarding()
    func downloadPlatformTools()
}

extension ADBManager: ADBUIModel {}

extension HostController: HostUIModel {
    var appVersion: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return b.map { "\(v) (\($0))" } ?? v
    }

    var hostId: String { HostIdentity.id }

    /// The PlexiChore virtual display, if one is currently attached (looked up by name like Windows does).
    var activeVirtualScreen: VirtualScreenInfo? {
        for screen in NSScreen.screens where screen.localizedName.hasPrefix("PlexiChore") {
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            let mode = CGDisplayCopyDisplayMode(id)
            return VirtualScreenInfo(
                name: screen.localizedName, displayID: id,
                pixelWidth: mode?.pixelWidth ?? Int(screen.frame.width * screen.backingScaleFactor),
                pixelHeight: mode?.pixelHeight ?? Int(screen.frame.height * screen.backingScaleFactor),
                pointWidth: Int(screen.frame.width), pointHeight: Int(screen.frame.height),
                isMain: CGDisplayIsMain(id) != 0)
        }
        return nil
    }

    /// Windows PairingWindow semantics: approve, and only keep the trust entry when "Trust this tablet
    /// next time" is ticked. (HostController.approvePairing always trusts.)
    func approvePairing(_ id: UUID, remember: Bool) {
        let deviceId = pendingPairings.first { $0.id == id }?.deviceId
        approvePairing(id)
        if !remember, let deviceId, !deviceId.isEmpty,
           let t = trustedDevices.first(where: { $0.deviceId == deviceId }) {
            removeTrusted(t)
        }
    }
}

extension HostUIModel {
    // MARK: Server / hero

    var serverUIState: ServerUIState {
        if prefs.serverPaused { return .paused }
        if serverListening { return .online }
        if serverStatus.hasPrefix("Starting") { return .starting }
        if serverStatus == "Stopped" { return .stopped }
        return .error
    }

    var isPaused: Bool { serverUIState == .paused }

    /// Sidebar "Server <pill>" and hero pill text.
    var serverPill: String {
        switch serverUIState {
        case .starting: return "Starting"
        case .online: return "Online"
        case .paused: return "Paused"
        case .error: return "Error"
        case .stopped: return "Stopped"
        }
    }

    var streamingSessions: [SessionSummary] { sessions.filter { $0.phase == .streaming } }

    var heroTone: Tone {
        switch serverUIState {
        case .paused: return .warn
        case .error: return .bad
        case .starting: return .info
        case .stopped: return .neutral
        case .online: return sessions.isEmpty ? .good : .accent
        }
    }

    var heroTitle: String {
        switch serverUIState {
        case .paused: return "Paused"
        case .error: return "Server couldn't start"
        case .starting: return "Starting…"
        case .stopped: return "Stopped"
        case .online:
            let n = sessions.count
            if n == 0 { return "Ready — waiting for tablet" }
            return n == 1 ? "\(sessions[0].displayName) connected" : "\(n) tablets connected"
        }
    }

    var heroSubtitle: String {
        switch serverUIState {
        case .paused: return "Tablets can't connect while the server is paused. Resume to make this Mac visible again."
        case .error: return serverStatus.isEmpty ? "Unknown error." : serverStatus
        case .starting: return "Preparing the display server."
        case .stopped: return ""
        case .online:
            let n = sessions.count
            if n == 0 {
                return "Open PlexiChore on your tablet. Connect with a USB cable, or pick this Mac on the same Wi‑Fi network."
            }
            if n == 1 {
                let s = sessions[0]
                if s.phase != .streaming { return "\(s.phase.rawValue) · \(s.transportText)" }
                return "\(s.modeText) over \(s.transportText) · \(s.resolutionText)"
            }
            return sessions.map(\.displayName).joined(separator: " · ")
        }
    }

    /// "192.168.1.5  ·  10.0.0.2" (first three, interface names stripped).
    var ipAddressesText: String {
        localAddresses.prefix(3).map { $0.split(separator: " ").first.map(String.init) ?? $0 }
            .joined(separator: "  ·  ")
    }

    var wifiChip: (String, Tone) {
        if serverUIState == .online && prefs.wifiDiscovery { return ("Wi‑Fi discovery on", .good) }
        return ("Wi‑Fi discovery off", .neutral)
    }

    /// Windows ExtendChip: "Extend: ready" / "not installed" / "checking" / "needs repair".
    var extendChip: (String, Tone) {
        switch extendState {
        case .ready: return ("Extend: ready", .good)
        case .inUse: return ("Extend: in use", .good)
        case .disabled: return ("Extend: off", .neutral)
        case .unsupported: return ("Extend: unavailable", .warn)
        }
    }

    // MARK: Extended display (CGVirtualDisplay)

    var extendState: ExtendState {
        if !virtualDisplaySupported { return .unsupported }
        if !prefs.allowVirtualDisplay { return .disabled }
        return activeVirtualScreen != nil ? .inUse : .ready
    }

    /// The Display page's scale picker writes both the new mode and the wired `hiDPI` flag.
    func setDisplayScaleMode(_ mode: String) {
        var p = prefs
        p.displayScaleMode = mode
        p.hiDPI = mode != "standard"
        prefs = p
    }

    // MARK: Display safety (emergency release / safety hold)

    /// Menu bar "Release Extended Display (⌃⌥⌘D)": same path as the hotkey.
    func releaseVirtualDisplayNow() { emergencyReleaseDisplay(); objectWillChange.send() }

    /// Seconds left on a safety hold (emergency / sleep / watchdog), nil when the virtual display may be created.
    var virtualDisplaySafetyHold: TimeInterval? { displaySafetyHoldRemaining }

    /// "Resume now": lift the hold. The active session switches back to Extend right away.
    func resumeVirtualDisplay() { clearDisplaySafetyHold(); objectWillChange.send() }

    var hasVirtualDisplay: Bool { virtualDisplayActive || activeVirtualScreen != nil }

    // MARK: Actions

    /// Pause / resume (sidebar button, menu bar). Persists `prefs.serverPaused`; HostController.prefs didSet
    /// disconnects tablets and stops / restarts the server and discovery, like Windows.
    func togglePause() {
        prefs.serverPaused.toggle()
    }

    var permissionsMissing: Bool { !screenRecordingGranted || !accessibilityGranted }
}

// MARK: - Session presentation (SessionViewModel)

extension SessionSummary {
    var displayName: String { deviceName.trimmingCharacters(in: .whitespaces).isEmpty ? "Tablet" : deviceName }
    var modelText: String { model.trimmingCharacters(in: .whitespaces).isEmpty ? "Android tablet" : model }

    /// CONFIG `link`: usb-cable | usb-wireless-adb | usb-tether | wifi (nil until known).
    var link: String? { transportLink.isEmpty ? nil : transportLink }

    var transportText: String {
        switch link {
        case "usb-wireless-adb": return "Wireless debugging"
        case "usb-tether": return "USB tethering"
        case "usb-cable": return "USB"
        case "wifi": return "Wi‑Fi"
        default: return isUSB ? "USB" : "Wi‑Fi"
        }
    }

    var transportIcon: String {
        switch link {
        case "usb-cable": return "cable.connector"
        case "usb-wireless-adb", "wifi": return "wifi"
        case "usb-tether": return "cable.connector"
        default: return isUSB ? "cable.connector" : "wifi"
        }
    }

    var isExtend: Bool { mode.lowercased() == "extend" }
    var isPrimaryDisplay: Bool { mode.lowercased() == "primary" }
    var modeText: String {
        if phase != .streaming { return phase.rawValue }
        return isPrimaryDisplay ? "Primary display" : isExtend ? "Extended display" : "Mirrored"
    }

    var resolutionText: String { width > 0 ? "\(width) × \(height)" : "—" }
    var codecText: String { codec.isEmpty ? "—" : codec.uppercased() }

    var scaleText: String? {
        guard scalePercent > 0 else { return nil }
        return scaleAuto ? "Scale \(scalePercent)% (auto)" : "Scale \(scalePercent)%"
    }

    var encoderText: String? { encoder.isEmpty ? nil : encoder }

    var fpsText: String { stats.sentFps > 0 ? String(format: "%.0f", stats.sentFps) : "—" }
    var bitrateText: String {
        let k = stats.bitrateKbps
        if k <= 0 { return "—" }
        return k >= 1000 ? String(format: "%.1f Mbps", k / 1000) : String(format: "%.0f kbps", k)
    }
    var rttText: String { rttMs > 0 ? String(format: "%.0f ms", rttMs) : "—" }
    var encodeText: String { stats.encodeMs > 0 ? String(format: "%.1f ms", stats.encodeMs) : "—" }

    @MainActor func durationText(now: Date = Date()) -> String {
        let d = now.timeIntervalSince(connectedSince)
        if d < 60 { return "just now" }
        if d < 3600 { return "\(Int(d / 60)) min" }
        return "\(Int(d / 3600)) h \(Int(d.truncatingRemainder(dividingBy: 3600) / 60)) min"
    }
}

// MARK: - USB presentation (AdbDeviceViewModel + MainViewModel.RefreshAdb)

extension ADBManager.Device {
    /// Wireless-debugging transport (classified by ADBManager from the `adb devices -l` line).
    var isWireless: Bool { transport == .wirelessDebugging }

    /// Physical serial (dedupes a tablet that shows up via cable *and* wireless debugging).
    var physicalSerial: String { hardwareSerial ?? serial }

    var name: String { model ?? serial }
    var connectionText: String {
        let base = isWireless ? "Wireless debugging" : "USB cable"
        return twinSerials.isEmpty || isWireless ? base : base + " + wireless debugging"
    }
    var connectionIcon: String { isWireless ? "wifi" : "cable.connector" }

    var stateText: String {
        switch stateKind {
        case .ready:
            if reversed { return "Ready · port 47800 forwarded" }
            return reverseError != nil ? "Forwarding failed – retrying" : "Connected · forwarding…"
        case .unauthorized: return state == "authorizing" ? "Authorizing…" : "Waiting for authorization"
        case .offline: return "Offline"
        case .noPermissions: return "No permission"
        case .bootMode: return "In \(state) mode"
        case .other: return state
        }
    }

    var tone: Tone {
        switch stateKind {
        case .ready: return reversed ? .good : (reverseError != nil ? .warn : .info)
        case .unauthorized: return .warn
        default: return .bad
        }
    }

    var hint: String? {
        if needsAuthorization {
            return state == "authorizing"
                ? "Keep the tablet unlocked while it authorizes this Mac."
                : "Unlock the tablet and tap “Allow” on the “Allow USB debugging?” prompt. Tick “Always allow from this computer” so it is remembered."
        }
        if isOffline { return "Unplug and replug the cable, or toggle USB debugging off and on in Developer options." }
        switch stateKind {
        case .noPermissions: return "Reconnect the tablet and accept the debugging prompt."
        case .ready where !reversed && reverseError != nil:
            return "adb reverse failed: \(reverseError ?? ""). PlexiChore keeps retrying — or click Re-apply forwarding."
        default: return nil
        }
    }
}

extension ADBUIModel {
    var isMissing: Bool { enabled && adbPath == nil && !downloading }
    var readyCount: Int { Set(devices.filter(\.isAuthorized).map(\.physicalSerial)).count }
    var unauthorizedCount: Int { devices.filter(\.needsAuthorization).count }
    /// Windows AdbPathText: "<path>  ·  <version>".
    var adbPathText: String? {
        guard let adbPath else { return nil }
        guard let v = adbVersion, !v.isEmpty else { return adbPath }
        return "\(adbPath)  ·  \(v)"
    }

    var lastError: String? {
        lastFailure ?? (status.hasPrefix("Download failed") ? status : nil)
    }

    var statusSummary: (String, Tone) {
        if !enabled || phase == .disabled { return ("USB is turned off", .neutral) }
        if case .versionMismatch = phase { return ("adb version conflict", .bad) }
        if downloading || phase == .downloading { return ("Downloading platform-tools…", .info) }
        if adbPath == nil || phase == .notFound { return ("Android platform-tools not found", .warn) }
        if phase == .unresponsive { return ("adb error", .bad) }
        if phase == .searching || phase == .startingServer { return ("Looking for adb…", .info) }
        let ready = readyCount
        if ready > 0 {
            let allWireless = devices.filter(\.isAuthorized).allSatisfy(\.isWireless)
            return ((ready == 1 ? "1 tablet ready" : "\(ready) tablets ready") + (allWireless ? " via wireless debugging" : " over USB"), .good)
        }
        if unauthorizedCount > 0 { return ("Authorize this Mac on your tablet", .warn) }
        return ("adb running — no tablet detected", .neutral)
    }

    var usbChip: (String, Tone) {
        if !enabled || phase == .disabled { return ("USB: off", .neutral) }
        if case .versionMismatch = phase { return ("USB: adb version conflict", .bad) }
        if downloading || phase == .downloading || phase == .searching || phase == .startingServer { return ("USB: starting", .info) }
        if adbPath == nil || phase == .notFound { return ("USB: adb missing", .warn) }
        if phase == .unresponsive { return ("USB: adb error", .bad) }
        let ready = readyCount
        if ready > 0 { return (ready == 1 ? "USB: 1 tablet" : "USB: \(ready) tablets", .good) }
        if unauthorizedCount > 0 { return ("USB: authorize tablet", .warn) }
        return ("USB: no tablet", .neutral)
    }
}

// MARK: - Misc system helpers

enum SystemLinks {
    static func open(_ s: String) {
        if let url = URL(string: s) { NSWorkspace.shared.open(url) }
    }
    static func displaysSettings() { open("x-apple.systempreferences:com.apple.Displays-Settings.extension") }
    static func firewallSettings() { open("x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall") }
    static func notificationSettings() { open("x-apple.systempreferences:com.apple.Notifications-Settings.extension") }
}

/// Reads (never changes) the macOS application firewall state.
enum MacFirewall {
    /// nil = unknown.
    static func isEnabled() async -> Bool? {
        await Task.detached(priority: .utility) { () -> Bool? in
            let tool = "/usr/libexec/ApplicationFirewall/socketfilterfw"
            guard FileManager.default.isExecutableFile(atPath: tool),
                  let out = ADBManager.run(tool, ["--getglobalstate"], captureOutput: true, timeout: 5) else { return nil }
            let s = out.lowercased()
            if s.contains("enabled") || s.contains("state = 1") || s.contains("state = 2") { return true }
            if s.contains("disabled") || s.contains("state = 0") { return false }
            return nil
        }.value
    }
}
