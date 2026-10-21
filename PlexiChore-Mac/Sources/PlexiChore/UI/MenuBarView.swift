import AppKit
import SwiftUI
import UserNotifications

/// Menu bar menu — same items as the Windows tray menu (Services/TrayService.cs):
/// Open PlexiChore · connected tablets (each with Disconnect) · Pause/Resume server · Quit PlexiChore.
/// Used with `.menuBarExtraStyle(.menu)` so it is a native NSMenu.
struct MenuBarView: View {
    @EnvironmentObject private var controller: HostController
    let openMainWindow: (MainPage?) -> Void
    let showPairing: (UUID) -> Void

    var body: some View {
        Button("Open PlexiChore") { openMainWindow(nil) }
        Divider()

        ForEach(controller.pendingPairings) { p in
            Button("Approve \(p.deviceName)… (code \(p.code))") { showPairing(p.id) }
        }
        if !controller.pendingPairings.isEmpty { Divider() }

        if controller.sessions.isEmpty {
            Text(controller.isPaused ? "Server paused" : "No tablets connected")
        } else {
            Text("Connected tablets")
            ForEach(controller.sessions) { s in
                Menu("\(s.displayName)  ·  \(s.transportText) · \(s.modeText)") {
                    if controller.prefs.showStatsInMenu && s.phase == .streaming {
                        Text("\(s.resolutionText) · \(s.fpsText) fps · \(s.bitrateText) · RTT \(s.rttText)")
                        Divider()
                    }
                    Button("Disconnect") { controller.disconnect(s.id) }
                }
            }
        }

        if controller.hasVirtualDisplay {
            Divider()
            Button("Release Extended Display (\(EmergencyHotKey.displayString))") { controller.releaseVirtualDisplayNow() }
        } else if let hold = controller.virtualDisplaySafetyHold {
            Divider()
            Button("Re-enable Extended Display (paused \(Int(hold.rounded(.up))) s)") { controller.resumeVirtualDisplay() }
        }

        if controller.permissionsMissing {
            Divider()
            Button("Permissions needed…") { openMainWindow(.settings) }
        }

        Divider()
        Button("Help…") { openMainWindow(.help) }
        Button(controller.isPaused ? "Resume server" : "Pause server") { controller.togglePause() }
        Button("Quit PlexiChore") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}

/// Menu bar icon; changes while streaming or when an approval is pending.
struct MenuBarLabel: View {
    @ObservedObject var controller: HostController

    var body: some View {
        let streaming = controller.sessions.contains { $0.phase == .streaming }
        let pending = !controller.pendingPairings.isEmpty
        Image(systemName: pending ? "exclamationmark.triangle.fill"
              : (controller.isPaused ? "pause.rectangle"
                 : (streaming ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle")))
    }
}

/// Tray-style notifications (TrayService.Notify): tablet connected, "still running" hint.
@MainActor
enum Notifier {
    static var available: Bool { Bundle.main.bundleIdentifier != nil }

    static func post(id: String = UUID().uuidString, title: String, body: String) {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: id, content: content, trigger: nil)) { _ in }
    }

    /// Same text as App.xaml.cs OnTabletConnected.
    static func tabletConnected(_ s: SessionSummary) {
        let mode: String
        switch s.mode.lowercased() {
        case "extend": mode = "extended display"
        case "primary": mode = "primary display"
        default: mode = "mirrored display"
        }
        post(title: "\(s.displayName) connected",
             body: "\(s.transportText) · \(mode) · \(s.width)×\(s.height) @ \(s.fps) fps")
    }
}
