import AppKit
import SwiftUI

/// The settings / status window.
struct MainWindowView: View {
    @EnvironmentObject private var controller: HostController
    @EnvironmentObject private var adb: ADBManager

    var body: some View {
        ZStack {
            BrandBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HeaderView()
                    if !controller.pendingPairings.isEmpty {
                        ForEach(controller.pendingPairings) { p in
                            PairingCard(pairing: p)
                        }
                    }
                    ConnectionCard()
                    if !controller.screenRecordingGranted || !controller.accessibilityGranted {
                        PermissionsCard()
                    }
                    HStack(alignment: .top, spacing: 18) {
                        VStack(spacing: 18) {
                            DisplayCard()
                            GeneralCard()
                        }
                        VStack(spacing: 18) {
                            USBCard()
                            WiFiCard()
                            TrustedDevicesCard()
                        }
                    }
                    if controller.screenRecordingGranted && controller.accessibilityGranted {
                        PermissionsCard()
                    }
                    FooterView()
                }
                .padding(.horizontal, 24)
                .padding(.top, 36)
                .padding(.bottom, 24)
            }
        }
        .frame(minWidth: 720, minHeight: 600)
        .preferredColorScheme(.dark)
        .animation(.easeInOut(duration: 0.25), value: controller.pendingPairings)
    }
}

// MARK: - Header

private struct HeaderView: View {
    @EnvironmentObject private var controller: HostController

    var body: some View {
        HStack(spacing: 14) {
            BrandMark(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text("PlexiChore")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.accentHorizontal)
                Text("Turn your Android tablet into a second display for \(controller.hostName)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            }
            Spacer()
            StatusPill(text: statusText, color: statusColor)
        }
    }

    private var statusText: String {
        if let s = controller.activeSummary, s.phase == .streaming { return "Streaming to \(s.deviceName)" }
        if !controller.pendingPairings.isEmpty { return "Approval needed" }
        return controller.serverListening ? "Ready" : controller.serverStatus
    }

    private var statusColor: Color {
        if let s = controller.activeSummary, s.phase == .streaming { return Theme.cyan }
        if !controller.pendingPairings.isEmpty { return Theme.warning }
        return controller.serverListening ? Theme.success : Theme.danger
    }
}

// MARK: - Pairing

struct PairingCard: View {
    @EnvironmentObject private var controller: HostController
    let pairing: PendingPairing

    var body: some View {
        GlassCard(padding: 18) {
            HStack(alignment: .center, spacing: 16) {
                ZStack {
                    Circle().fill(Theme.warning.opacity(0.15)).frame(width: 46, height: 46)
                    Image(systemName: "lock.shield")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(Theme.warning)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(pairing.deviceName) wants to connect")
                        .font(.system(size: 15, weight: .semibold))
                    Text("\(pairing.model.isEmpty ? "Tablet" : pairing.model) · \(pairing.address) · Check that the same code is shown on the tablet.")
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                CodeView(code: pairing.code)
            }
            HStack {
                Spacer()
                Button("Reject") { controller.rejectPairing(pairing.id) }
                    .buttonStyle(GlassButtonStyle(tint: Theme.danger))
                Button("Approve & Trust") { controller.approvePairing(pairing.id) }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Theme.warning.opacity(0.45), lineWidth: 1)
        )
    }
}

struct CodeView: View {
    let code: String
    var body: some View {
        HStack(spacing: 6) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 24, weight: .bold, design: .monospaced))
                    .frame(width: 32, height: 42)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.white.opacity(0.08)))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Theme.accent, lineWidth: 1))
            }
        }
    }
}

// MARK: - Connection

private struct ConnectionCard: View {
    @EnvironmentObject private var controller: HostController

    var body: some View {
        GlassCard {
            HStack {
                SectionHeader(title: "Connection", systemImage: "dot.radiowaves.left.and.right")
                Spacer()
                if !controller.sessions.isEmpty {
                    Button("Disconnect") { controller.disconnectAll() }
                        .buttonStyle(GlassButtonStyle(tint: Theme.danger))
                }
            }
            if controller.sessions.isEmpty {
                HStack(spacing: 14) {
                    Image(systemName: "ipad.landscape")
                        .font(.system(size: 34, weight: .light))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Waiting for a tablet")
                            .font(.system(size: 14, weight: .semibold))
                        Text("Open PlexiChore on your tablet. Plug it in over USB (with USB debugging enabled), or join the same Wi-Fi network — this Mac will appear automatically.")
                            .font(.system(size: 11.5))
                            .foregroundColor(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            } else {
                ForEach(controller.sessions) { s in
                    SessionRow(summary: s)
                }
            }
            if let msg = controller.lastMessage {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").foregroundColor(Theme.textTertiary)
                    Text(msg).font(.system(size: 11)).foregroundColor(Theme.textTertiary)
                        .lineLimit(2)
                }
            }
        }
    }
}

struct SessionRow: View {
    @EnvironmentObject private var controller: HostController
    let summary: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: summary.isUSB ? "cable.connector" : "wifi")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(summary.deviceName).font(.system(size: 14, weight: .semibold))
                    Text("\(summary.model.isEmpty ? "" : summary.model + " · ")\(summary.isUSB ? "USB" : summary.address)")
                        .font(.system(size: 11))
                        .foregroundColor(Theme.textSecondary)
                }
                Spacer()
                StatusPill(text: summary.phase.rawValue, color: phaseColor)
                Button {
                    controller.disconnect(summary.id)
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(GlassButtonStyle())
                .help("Disconnect this tablet")
            }
            if summary.phase == .streaming {
                HStack(spacing: 8) {
                    StatTile(label: "Mode", value: summary.mode == "extend" ? "Extend" : "Mirror")
                    StatTile(label: "Resolution", value: "\(summary.width)×\(summary.height)")
                    StatTile(label: "FPS", value: String(format: "%.0f", summary.stats.sentFps), unit: "/ \(summary.fps)")
                    StatTile(label: "Bitrate", value: String(format: "%.1f", summary.stats.bitrateKbps / 1000), unit: "Mbps")
                    StatTile(label: "Latency", value: String(format: "%.0f", summary.rttMs), unit: "ms RTT")
                    StatTile(label: "Encode", value: String(format: "%.1f", summary.stats.encodeMs), unit: "ms")
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.white.opacity(0.035)))
    }

    private var phaseColor: Color {
        switch summary.phase {
        case .streaming: return Theme.cyan
        case .pairing: return Theme.warning
        case .error: return Theme.danger
        default: return Theme.violet
        }
    }
}

// MARK: - Permissions

private struct PermissionsCard: View {
    @EnvironmentObject private var controller: HostController

    var body: some View {
        GlassCard {
            SectionHeader(title: "Permissions", systemImage: "hand.raised")
            PermissionRow(
                title: "Screen Recording",
                detail: "Needed to capture the display that is streamed to the tablet.",
                granted: controller.screenRecordingGranted,
                action: { controller.requestScreenRecording() },
                openSettings: { Permissions.openScreenRecordingSettings() })
            Divider().overlay(Theme.cardStroke)
            PermissionRow(
                title: "Accessibility",
                detail: "Needed so touches and pen strokes on the tablet can move the pointer and click.",
                granted: controller.accessibilityGranted,
                action: { controller.requestAccessibility() },
                openSettings: { Permissions.openAccessibilitySettings() })
            if !controller.screenRecordingGranted {
                Text("After enabling Screen Recording, macOS may ask you to quit and reopen PlexiChore.")
                    .font(.system(size: 11))
                    .foregroundColor(Theme.textTertiary)
            }
        }
    }
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: () -> Void
    let openSettings: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: granted ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 18))
                .foregroundColor(granted ? Theme.success : Theme.warning)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(detail).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Allowed").font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.success)
            } else {
                Button("Open Settings", action: openSettings).buttonStyle(GlassButtonStyle())
                Button("Allow", action: action).buttonStyle(GradientButtonStyle())
            }
        }
    }
}

// MARK: - Display

private struct DisplayCard: View {
    @EnvironmentObject private var controller: HostController

    var body: some View {
        GlassCard {
            SectionHeader(title: "Display", systemImage: "display.2")
            ToggleRow(title: "Extended display",
                      detail: controller.virtualDisplaySupported
                        ? "Create a virtual monitor sized to the tablet."
                        : "Not available on this macOS version — mirroring is used.",
                      isOn: $controller.prefs.allowVirtualDisplay)
                .disabled(!controller.virtualDisplaySupported)
            ToggleRow(title: "Retina (HiDPI)",
                      detail: "Render at 2× for crisp text; the tablet looks like half its pixel size.",
                      isOn: $controller.prefs.hiDPI)
            ToggleRow(title: "Keyframe every 5 s",
                      detail: "Faster recovery from Wi-Fi glitches at a small bitrate cost.",
                      isOn: $controller.prefs.periodicKeyframes)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Maximum frame rate").font(.system(size: 13, weight: .medium))
                    Text("The tablet's request is capped to this.").font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                }
                Spacer()
                Picker("", selection: $controller.prefs.maxFps) {
                    Text("30").tag(30)
                    Text("60").tag(60)
                    Text("90").tag(90)
                    Text("120").tag(120)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 180)
            }
            Text("Resolution, position, mode and bitrate are chosen on the tablet.")
                .font(.system(size: 11))
                .foregroundColor(Theme.textTertiary)
        }
    }
}

struct ToggleRow: View {
    let title: String
    let detail: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .medium))
                Text(detail).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.violet)
    }
}

// MARK: - General

private struct GeneralCard: View {
    @EnvironmentObject private var controller: HostController

    var body: some View {
        GlassCard {
            SectionHeader(title: "General", systemImage: "gearshape")
            ToggleRow(title: "Open at login",
                      detail: LaunchAtLogin.isAvailable
                        ? "Start PlexiChore quietly in the menu bar."
                        : "Available when running the bundled PlexiChore.app.",
                      isOn: Binding(get: { controller.launchAtLogin },
                                    set: { controller.setLaunchAtLogin($0) }))
                .disabled(!LaunchAtLogin.isAvailable)
            ToggleRow(title: "Require approval for Wi-Fi tablets",
                      detail: "New tablets must be approved here with a 4-digit code. USB is always trusted.",
                      isOn: $controller.prefs.requirePairing)
        }
    }
}

// MARK: - USB

private struct USBCard: View {
    @EnvironmentObject private var adb: ADBManager

    var body: some View {
        GlassCard {
            HStack {
                SectionHeader(title: "USB", systemImage: "cable.connector")
                Spacer()
                Toggle("", isOn: $adb.enabled).toggleStyle(.switch).labelsHidden().tint(Theme.violet)
            }
            Text(adb.status)
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let path = adb.adbPath {
                Text(path)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if adb.enabled {
                HStack {
                    Button(adb.downloading ? "Downloading…" : "Download platform-tools") {
                        adb.downloadPlatformTools()
                    }
                    .buttonStyle(GradientButtonStyle())
                    .disabled(adb.downloading)
                    if adb.downloading { ProgressView().controlSize(.small) }
                }
                Text("Or install with Homebrew: brew install android-platform-tools")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundColor(Theme.textTertiary)
                    .textSelection(.enabled)
            }
            ForEach(adb.devices) { d in
                HStack(spacing: 8) {
                    Image(systemName: d.reversed ? "checkmark.circle.fill" : (d.isAuthorized ? "arrow.triangle.2.circlepath" : "exclamationmark.circle"))
                        .foregroundColor(d.reversed ? Theme.success : Theme.warning)
                    Text(d.model ?? d.serial).font(.system(size: 12, weight: .medium))
                    Spacer()
                    Text(d.reversed ? "Ready" : d.state).font(.system(size: 11)).foregroundColor(Theme.textSecondary)
                }
            }
            if adb.enabled && adb.adbPath != nil {
                Button("Refresh") { adb.refresh() }.buttonStyle(GlassButtonStyle())
            }
        }
    }
}

// MARK: - Wi-Fi

private struct WiFiCard: View {
    @EnvironmentObject private var controller: HostController

    var body: some View {
        GlassCard {
            HStack {
                SectionHeader(title: "Wi-Fi", systemImage: "wifi")
                Spacer()
                Toggle("", isOn: $controller.prefs.wifiDiscovery).toggleStyle(.switch).labelsHidden().tint(Theme.violet)
            }
            Text(controller.prefs.wifiDiscovery
                 ? "Announcing this Mac on the local network."
                 : "Discovery is off — connect from the tablet by IP address.")
                .font(.system(size: 12))
                .foregroundColor(Theme.textSecondary)
            if !controller.localAddresses.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Manual address").font(.system(size: 10, weight: .bold)).foregroundColor(Theme.textTertiary)
                    ForEach(controller.localAddresses, id: \.self) { a in
                        Text(a).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                    }
                }
            }
            HStack(spacing: 6) {
                Circle().fill(controller.serverListening ? Theme.success : Theme.danger).frame(width: 6, height: 6)
                Text(controller.serverStatus).font(.system(size: 11)).foregroundColor(Theme.textTertiary)
            }
        }
    }
}

// MARK: - Trusted devices

private struct TrustedDevicesCard: View {
    @EnvironmentObject private var controller: HostController

    var body: some View {
        GlassCard {
            SectionHeader(title: "Trusted tablets", systemImage: "checkmark.shield")
            if controller.trustedDevices.isEmpty {
                Text("Tablets you approve over Wi-Fi appear here.")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.textSecondary)
            } else {
                ForEach(controller.trustedDevices) { d in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(d.name).font(.system(size: 12.5, weight: .medium))
                            Text("Last seen \(d.lastSeen.formatted(date: .abbreviated, time: .shortened))")
                                .font(.system(size: 10.5)).foregroundColor(Theme.textTertiary)
                        }
                        Spacer()
                        Button("Forget") { controller.removeTrusted(d) }
                            .buttonStyle(GlassButtonStyle(tint: Theme.danger))
                    }
                }
            }
        }
    }
}

// MARK: - Footer

private struct FooterView: View {
    var body: some View {
        HStack {
            Text("PlexiChore for Mac · protocol v\(PlexiProtocol.version) · TCP \(String(PlexiProtocol.tcpPort)) · UDP \(String(PlexiProtocol.udpPort))")
                .font(.system(size: 10.5))
                .foregroundColor(Theme.textTertiary)
            Spacer()
            Button("Quit PlexiChore") { NSApp.terminate(nil) }
                .buttonStyle(GlassButtonStyle())
        }
    }
}
