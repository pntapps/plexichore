import AppKit
import SwiftUI

/// Compact popover shown from the menu bar icon (MenuBarExtra, .window style).
struct MenuBarView: View {
    @EnvironmentObject private var controller: HostController
    @EnvironmentObject private var adb: ADBManager
    let openMainWindow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                BrandMark(size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("PlexiChore")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.accentHorizontal)
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
            }

            ForEach(controller.pendingPairings) { p in
                VStack(alignment: .leading, spacing: 8) {
                    Text("\(p.deviceName) wants to connect")
                        .font(.system(size: 12.5, weight: .semibold))
                    HStack {
                        CodeView(code: p.code).scaleEffect(0.8, anchor: .leading)
                        Spacer()
                    }
                    HStack {
                        Button("Reject") { controller.rejectPairing(p.id) }
                            .buttonStyle(GlassButtonStyle(tint: Theme.danger))
                        Spacer()
                        Button("Approve") { controller.approvePairing(p.id) }
                            .buttonStyle(GradientButtonStyle())
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.warning.opacity(0.10)))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.warning.opacity(0.4)))
            }

            if let s = controller.activeSummary, s.phase == .streaming {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: s.isUSB ? "cable.connector" : "wifi").foregroundStyle(Theme.accent)
                        Text(s.deviceName).font(.system(size: 13, weight: .semibold))
                        Spacer()
                        StatusPill(text: s.mode == "extend" ? "Extended" : "Mirrored", color: Theme.cyan)
                    }
                    HStack(spacing: 6) {
                        StatTile(label: "FPS", value: String(format: "%.0f", s.stats.sentFps))
                        StatTile(label: "Mbps", value: String(format: "%.1f", s.stats.bitrateKbps / 1000))
                        StatTile(label: "RTT", value: String(format: "%.0f", s.rttMs), unit: "ms")
                    }
                }
            } else if controller.pendingPairings.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "ipad.landscape").font(.system(size: 22, weight: .light)).foregroundStyle(Theme.accent)
                    Text("Open PlexiChore on your tablet to connect over USB or Wi-Fi.")
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !controller.screenRecordingGranted || !controller.accessibilityGranted {
                Button {
                    openMainWindow()
                } label: {
                    Label("Permissions needed", systemImage: "exclamationmark.triangle.fill")
                }
                .buttonStyle(GlassButtonStyle(tint: Theme.warning))
            }

            Divider().overlay(Theme.cardStroke)

            HStack {
                if !controller.sessions.isEmpty {
                    Button("Disconnect") { controller.disconnectAll() }
                        .buttonStyle(GlassButtonStyle(tint: Theme.danger))
                }
                Spacer()
                Button("Settings…") { openMainWindow() }
                    .buttonStyle(GlassButtonStyle())
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(GlassButtonStyle())
            }
        }
        .padding(14)
        .frame(width: 320)
        .background(BrandBackground())
        .preferredColorScheme(.dark)
    }

    private var subtitle: String {
        if !controller.serverListening { return controller.serverStatus }
        let usb = adb.devices.filter(\.reversed).count
        var parts = ["Ready"]
        if usb > 0 { parts.append("\(usb) USB") }
        if controller.prefs.wifiDiscovery { parts.append("Wi-Fi on") }
        return parts.joined(separator: " · ")
    }
}

/// Menu bar icon; tinted while streaming or when an approval is pending.
struct MenuBarLabel: View {
    @ObservedObject var controller: HostController

    var body: some View {
        let streaming = controller.sessions.contains { $0.phase == .streaming }
        let pending = !controller.pendingPairings.isEmpty
        Image(systemName: pending ? "exclamationmark.triangle.fill"
              : (streaming ? "rectangle.inset.filled.on.rectangle" : "rectangle.on.rectangle"))
    }
}
