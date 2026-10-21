import AppKit
import SwiftUI

/// Port of Views/Pages/SettingsPage.xaml (+ macOS-only Permissions / Network rows).
struct SettingsPage<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host
    @State private var firewallOn: Bool?
    @State private var firewallChecked = false

    var body: some View {
        PageScroll {
            PageHeader(title: "Settings", subtitle: "Startup, security and streaming preferences.")

            // ===== GENERAL =====
            SectionHeader(title: "General")
            ToggleSettingRow(icon: "power", title: "Open at login",
                             caption: LaunchAtLogin.isAvailable
                                ? "Launch quietly in the menu bar when you log in, so tablets can connect any time."
                                : "Available when running the bundled PlexiChore.app.",
                             isOn: Binding(get: { controller.launchAtLogin }, set: { controller.setLaunchAtLogin($0) }))
                .disabled(!LaunchAtLogin.isAvailable)
            ToggleSettingRow(icon: "bell", title: "Notify when a tablet connects",
                             caption: "Show a macOS notification. Allow PlexiChore in System Settings › Notifications if none appear.",
                             isOn: $controller.prefs.showConnectNotifications)
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("circle.lefthalf.filled")
                    RowText(title: "Appearance", caption: "Dark matches the Windows app. System follows your macOS setting.")
                    Spacer(minLength: 12)
                    Picker("", selection: $controller.prefs.appearance) {
                        Text("Dark").tag("dark")
                        Text("Light").tag("light")
                        Text("System").tag("system")
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
            }

            // ===== SECURITY =====
            SectionHeader(title: "Security")
            ToggleSettingRow(icon: "lock.shield", title: "Require approval for new Wi‑Fi tablets",
                             caption: "Unknown tablets must show a matching 4‑digit code before they can see your screen. USB is always trusted.",
                             isOn: $controller.prefs.requirePairing)
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("shield")
                    RowText(title: "macOS Firewall", caption: firewallText)
                    Spacer(minLength: 12)
                    if firewallOn == false {
                        Badge(text: "Not blocking", systemImage: "checkmark", fill: Theme.greenSoft, tint: Theme.green)
                    }
                    Button("Firewall settings") { SystemLinks.firewallSettings() }.buttonStyle(SecondaryButtonStyle())
                }
            }
            TrustedTabletsRow<Host>()

            // ===== NETWORK (macOS: Windows shows this in the hero chips) =====
            SectionHeader(title: "Network")
            ToggleSettingRow(icon: "wifi", title: "Wi‑Fi discovery",
                             caption: controller.prefs.wifiDiscovery
                                ? "Announcing this Mac on the local network so tablets find it automatically."
                                : "Off — connect from the tablet by IP address: \(controller.ipAddressesText.isEmpty ? "no network" : controller.ipAddressesText).",
                             isOn: $controller.prefs.wifiDiscovery)
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("network")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Addresses").font(.system(size: 14))
                        Text(controller.localAddresses.isEmpty ? "No network connection" : controller.localAddresses.joined(separator: "   ·   "))
                            .font(.system(size: 11.5, design: .monospaced)).foregroundColor(Theme.textTertiary)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 12)
                    Text("TCP \(String(PlexiProtocol.tcpPort)) · UDP \(String(PlexiProtocol.udpPort))").plexiCaption()
                }
            }

            // ===== STREAMING =====
            SectionHeader(title: "Streaming")
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("video")
                    RowText(title: "Preferred video encoder",
                            caption: "Hardware H.264 (VideoToolbox) is fastest. Use software if you see artifacts.")
                    Spacer(minLength: 12)
                    Picker("", selection: $controller.prefs.preferHardwareEncoder) {
                        Text("Hardware (GPU) — recommended").tag(true)
                        Text("Software (CPU)").tag(false)
                    }
                    .labelsHidden().frame(width: 290)
                }
            }
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("speedometer")
                    RowText(title: "Maximum frame rate", caption: "The tablet's request is capped to this.")
                    Spacer(minLength: 12)
                    Picker("", selection: $controller.prefs.maxFps) {
                        Text("30").tag(30); Text("60").tag(60); Text("90").tag(90); Text("120").tag(120)
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
            }
            ToggleSettingRow(icon: "key", title: "Keyframe every 5 s",
                             caption: "Faster recovery from Wi‑Fi glitches at a small bitrate cost.",
                             isOn: $controller.prefs.periodicKeyframes)
            ToggleSettingRow(icon: "menubar.rectangle", title: "Show live stats in the menu bar menu",
                             caption: "Frame rate, bitrate and latency under each connected tablet.",
                             isOn: $controller.prefs.showStatsInMenu)

            // ===== PERMISSIONS (macOS) =====
            SectionHeader(title: "Permissions")
            PermissionRow(icon: "rectangle.dashed.badge.record", title: "Screen Recording",
                          caption: "Needed to show your screen on the tablet. macOS may ask you to reopen PlexiChore after allowing it.",
                          granted: controller.screenRecordingGranted,
                          allow: { controller.requestScreenRecording() },
                          open: { Permissions.openScreenRecordingSettings() })
            PermissionRow(icon: "hand.point.up.left", title: "Accessibility",
                          caption: "Needed so touches and pen strokes on the tablet move the pointer, click and type.",
                          granted: controller.accessibilityGranted,
                          allow: { controller.requestAccessibility() },
                          open: { Permissions.openAccessibilitySettings() })
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("antenna.radiowaves.left.and.right")
                    RowText(title: "Local Network",
                            caption: "Needed on macOS 15+ for Wi‑Fi tablets. If they can't find this Mac, allow PlexiChore here.")
                    Spacer(minLength: 12)
                    Button("Open settings") { Permissions.openLocalNetworkSettings() }.buttonStyle(SecondaryButtonStyle())
                }
            }

            // ===== DIAGNOSTICS =====
            SectionHeader(title: "Diagnostics")
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("doc.text")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Last event").font(.system(size: 14))
                        Text(controller.lastMessage ?? "Nothing to report.")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundColor(Theme.textTertiary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    Button("Open Console") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Console.app"))
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
        .task {
            firewallOn = await MacFirewall.isEnabled()
            firewallChecked = true
        }
    }

    private var firewallText: String {
        guard firewallChecked else { return "Checking…" }
        switch firewallOn {
        case .some(true): return "On. If Wi‑Fi tablets can't connect, allow incoming connections for PlexiChore when macOS asks, or in Firewall settings."
        case .some(false): return "Off — tablets on Wi‑Fi can reach port 47800 and find this Mac on UDP 47801."
        case .none: return "Status unknown. If Wi‑Fi tablets can't connect, check the Firewall settings."
        }
    }
}

// MARK: - Rows

struct RowText: View {
    let title: String
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 14))
            Text(caption).plexiCaption()
        }
    }
}

struct ToggleSettingRow: View {
    let icon: String
    let title: String
    let caption: String
    @Binding var isOn: Bool
    var body: some View {
        SettingRow {
            HStack(spacing: 16) {
                RowIcon(icon)
                RowText(title: title, caption: caption)
                Spacer(minLength: 12)
                PlexiToggle(isOn: $isOn)
            }
        }
    }
}

private struct PermissionRow: View {
    let icon: String
    let title: String
    let caption: String
    let granted: Bool
    let allow: () -> Void
    let open: () -> Void

    var body: some View {
        SettingRow {
            HStack(spacing: 16) {
                RowIcon(icon)
                RowText(title: title, caption: caption)
                Spacer(minLength: 12)
                if granted {
                    Badge(text: "Allowed", systemImage: "checkmark", fill: Theme.greenSoft, tint: Theme.green)
                } else {
                    Button("Open settings", action: open).buttonStyle(SecondaryButtonStyle())
                    Button("Allow", action: allow).buttonStyle(PrimaryButtonStyle())
                }
            }
        }
    }
}

private struct TrustedTabletsRow<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host

    var body: some View {
        SettingRow {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    RowIcon("person.crop.circle.badge.checkmark")
                    RowText(title: "Trusted tablets",
                            caption: "These tablets connect over Wi‑Fi without asking. Remove one to require the code again.")
                }
                VStack(spacing: 6) {
                    ForEach(controller.trustedDevices.sorted { $0.addedAt > $1.addedAt }) { d in
                        HStack(spacing: 12) {
                            Image(systemName: "ipad.landscape").font(.system(size: 15))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(d.name).fontWeight(.semibold)
                                Text("Trusted since \(trustedSinceFormat.string(from: d.addedAt))  ·  id \(String(d.deviceId.prefix(8)))")
                                    .plexiCaption()
                            }
                            Spacer()
                            Button("Remove") { controller.removeTrusted(d) }.buttonStyle(GhostButtonStyle(tint: Theme.dangerText))
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.subtle))
                    }
                }
                .padding(.leading, 38).padding(.top, 10)
                if controller.trustedDevices.isEmpty {
                    Text("No trusted tablets yet.").plexiCaption().padding(.leading, 38).padding(.bottom, 2)
                }
            }
        }
    }
}

/// Windows TrustedDevice.AddedText: "Trusted since 21 Oct 2026".
private let trustedSinceFormat: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "d MMM yyyy"
    return f
}()
