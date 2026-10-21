import AppKit
import Combine
import SwiftUI
import XCTest
@testable import PlexiChore

// Offscreen screenshots of the main window pages / pairing card with fake state, for comparing against the Windows
// app (PlexiChore-Desktop/src/PlexiChore.App/Views). Nothing is started: no HostController, server, adb or display.
// Run:  PLEXI_UI_SHOTS=/some/dir swift test --filter UIRenderTests      (skipped when the variable is unset)

@MainActor
private final class FakeADB: ADBUIModel {
    @Published var adbPath: String? = "/opt/homebrew/bin/adb"
    @Published var adbVersion: String? = "36.0.0-13206524"
    @Published var devices: [ADBManager.Device] = []
    @Published var status = "adb running"
    @Published var downloading = false
    @Published var enabled = true
    @Published var phase: ADBManager.Phase = .running
    @Published var lastFailure: String?
    func refresh() {}
    func reapplyForwarding() {}
    func downloadPlatformTools() {}
}

@MainActor
private final class FakeHost: HostUIModel {
    let adb = FakeADB()
    @Published var serverStatus = "Listening on 47800"
    @Published var serverListening = true
    @Published var sessions: [SessionSummary] = []
    @Published var pendingPairings: [PendingPairing] = []
    @Published var trustedDevices: [TrustedDevice] = []
    @Published var screenRecordingGranted = true
    @Published var accessibilityGranted = true
    @Published var launchAtLogin = true
    @Published var lastMessage: String?
    @Published var localAddresses = ["192.168.1.42 (en0)", "10.0.0.7 (en5)"]
    @Published var prefs = HostPreferences()
    var virtualDisplaySupported = true
    var hostName = "Studio Mac"
    var hostId = "3f9c2a1e-7b4d-4e0f-9a51-c0ffee000042"
    var appVersion = "1.0.0 (1)"
    var displaySafetyHoldRemaining: TimeInterval?
    var virtualDisplayActive = false
    var activeVirtualScreen: VirtualScreenInfo?
    func requestScreenRecording() {}
    func requestAccessibility() {}
    func setLaunchAtLogin(_ enabled: Bool) { launchAtLogin = enabled }
    func removeTrusted(_ device: TrustedDevice) {}
    func emergencyReleaseDisplay() {}
    func clearDisplaySafetyHold() {}
    func disconnect(_ id: UUID) {}
}

@MainActor
final class UIRenderTests: XCTestCase {
    private var outDir: URL!

    override func setUp() async throws {
        guard let dir = ProcessInfo.processInfo.environment["PLEXI_UI_SHOTS"], !dir.isEmpty else {
            throw XCTSkip("Set PLEXI_UI_SHOTS=<dir> to render UI screenshots")
        }
        outDir = URL(fileURLWithPath: dir, isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        _ = NSApplication.shared
    }

    // MARK: Fixtures

    private func streamingSession(name: String, usb: Bool, mode: String, w: Int, h: Int, link: String) -> SessionSummary {
        var s = SessionSummary(id: UUID(), deviceName: name, model: "SM-X700", address: usb ? "127.0.0.1" : "192.168.1.77",
                               isUSB: usb, phase: .streaming)
        s.mode = mode; s.width = w; s.height = h; s.fps = 60; s.codec = "h264"; s.rttMs = 3.6
        s.stats.sentFps = 59.8; s.stats.bitrateKbps = 18450; s.stats.encodeMs = 4.2
        s.connectedSince = Date().addingTimeInterval(-754)
        s.transportLink = link; s.encoder = "hw:VideoToolbox H.264 High"
        s.scalePercent = mode == "mirror" ? 0 : 200; s.scaleAuto = true
        return s
    }

    private func devices() -> [ADBManager.Device] {
        [ADBManager.Device(serial: "R54T1234ABC", state: "device", model: "Galaxy Tab S8", reversed: true),
         ADBManager.Device(serial: "adb-R52N99-xyz._adb-tls-connect._tcp", state: "unauthorized", model: nil, reversed: false,
                           transport: .wirelessDebugging)]
    }

    private func trusted() -> [TrustedDevice] {
        let d = Date(timeIntervalSince1970: 1_790_000_000)
        return [TrustedDevice(deviceId: "a1b2c3d4e5f6a7b8", name: "Galaxy Tab S8", model: "SM-X700", addedAt: d, lastSeen: d),
                TrustedDevice(deviceId: "99ffee0011223344", name: "Pixel Tablet", model: nil, addedAt: d.addingTimeInterval(-86400 * 30), lastSeen: d)]
    }

    // MARK: Rendering

    private func render<V: View>(_ name: String, size: CGSize, _ view: V) {
        for dark in [true, false] {
            let root = view.frame(width: size.width, height: size.height)
            let hosting = NSHostingView(rootView: root)
            hosting.frame = CGRect(origin: .zero, size: size)
            let window = NSWindow(contentRect: hosting.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.backgroundColor = NSColor(Theme.base)
            window.contentView = hosting
            hosting.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.25))
            hosting.layoutSubtreeIfNeeded()
            guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { XCTFail("no rep"); return }
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            let url = outDir.appendingPathComponent("\(name)-\(dark ? "dark" : "light").png")
            XCTAssertNoThrow(try rep.representation(using: .png, properties: [:])?.write(to: url))
            window.contentView = nil
        }
    }

    private func page(_ name: String, _ page: MainPage, host: FakeHost, height: CGFloat = 800) {
        let ui = UIState()
        ui.page = page
        let view = MainWindowView<FakeHost>()
            .environmentObject(host).environmentObject(host.adb).environmentObject(ui)
        render(name, size: CGSize(width: 1200, height: height), view)
    }

    // MARK: Shots

    func testHome() {
        let h = FakeHost()
        page("home-empty", .home, host: h)
        h.sessions = [streamingSession(name: "Galaxy Tab S8", usb: true, mode: "extend", w: 2560, h: 1600, link: "usb-cable")]
        h.adb.devices = Array(devices().prefix(1))
        h.activeVirtualScreen = VirtualScreenInfo(name: "PlexiChore Galaxy Tab S8", displayID: 5, pixelWidth: 2560, pixelHeight: 1600,
                                                  pointWidth: 1280, pointHeight: 800, isMain: false)
        page("home-session", .home, host: h)
        h.sessions.append(streamingSession(name: "Pixel Tablet", usb: false, mode: "mirror", w: 1920, h: 1200, link: "wifi"))
        page("home-two", .home, host: h, height: 1000)
        let p = FakeHost()
        p.prefs.serverPaused = true
        p.serverListening = false
        p.screenRecordingGranted = false
        page("home-paused-perms", .home, host: p)
    }

    func testDisplay() {
        let h = FakeHost()
        page("display-ready", .display, host: h, height: 1500)
        h.activeVirtualScreen = VirtualScreenInfo(name: "PlexiChore Galaxy Tab S8", displayID: 5, pixelWidth: 2560, pixelHeight: 1600,
                                                  pointWidth: 1280, pointHeight: 800, isMain: false)
        h.virtualDisplayActive = true
        page("display-inuse", .display, host: h)
        let u = FakeHost()
        u.virtualDisplaySupported = false
        page("display-unsupported", .display, host: u)
    }

    func testUsb() {
        let h = FakeHost()
        h.adb.devices = devices()
        page("usb-devices", .usb, host: h, height: 1000)
        let m = FakeHost()
        m.adb.adbPath = nil; m.adb.adbVersion = nil; m.adb.phase = .notFound
        page("usb-missing", .usb, host: m)
    }

    func testSettings() {
        let h = FakeHost()
        h.trustedDevices = trusted()
        page("settings", .settings, host: h, height: 1900)
    }

    func testHelp() {
        page("help", .help, host: FakeHost(), height: 1900)
        let h = FakeHost()
        h.virtualDisplayActive = true
        page("help-active", .help, host: h)
    }

    func testAbout() {
        page("about", .about, host: FakeHost())
    }

    func testPairing() {
        let p = PendingPairing(id: UUID(), deviceId: "abc", deviceName: "Galaxy Tab S8", model: "SM-X700",
                               address: "192.168.1.77", code: "4821")
        render("pairing", size: CGSize(width: 440, height: 600), PairingWindowView(pairing: p) { _, _ in })
    }
}
