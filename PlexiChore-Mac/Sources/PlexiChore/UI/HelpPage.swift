import AppKit
import SwiftUI

/// Troubleshooting tips, so nobody has to search elsewhere (macOS only; the tablet app has its own Help screen).
struct HelpPage<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host
    @EnvironmentObject private var ui: UIState

    var body: some View {
        PageScroll {
            PageHeader(title: "Help", subtitle: "Quick fixes for the most common problems.")

            // ===== EMERGENCY =====
            SectionHeader(title: "Emergency")
            EmergencyCard<Host>()

            // ===== PICTURE AND SPEED =====
            SectionHeader(title: "Picture and speed")
            HelpTopic(icon: "tortoise", title: "Laggy or choppy", steps: [
                "Use the USB cable rather than Wi‑Fi.",
                "On the tablet choose H.264 (not MJPEG) in Settings › Video codec.",
                "If wireless debugging is also on while plugged in, the stream can go over Wi‑Fi instead of the cable. The USB page shows how each tablet is connected.",
                "Close heavy apps on the Mac.",
            ])
            HelpTopic(icon: "textformat.size", title: "Text and windows too small or too large", steps: [
                "On the tablet, show the controls: swipe down from the top edge or tap with three fingers.",
                "Use − / + to change the size. Tablet Settings › Display size does the same.",
                "Each change blanks the tablet for about a second while the display is rebuilt.",
            ])
            HelpTopic(icon: "rectangle.dashed", title: "Black borders on the tablet", steps: [
                "Update the PlexiChore app on the tablet.",
                "Make sure the stream fills the screen (immersive mode, no system bars).",
                "Rotate the tablet once.",
            ])

            // ===== CONNECTING =====
            SectionHeader(title: "Connecting")
            HelpTopic(icon: "magnifyingglass", title: "Tablet not found", steps: [
                "USB: turn on USB debugging on the tablet and allow this computer when the tablet asks. The USB page should show adb installed and the tablet listed.",
                "Wi‑Fi: both on the same network, and Wi‑Fi discovery on in Settings.",
                "Allow PlexiChore in System Settings › Privacy & Security › Local Network.",
                "If the macOS firewall is on, allow incoming connections for PlexiChore.",
            ]) {
                Button("Local Network") { Permissions.openLocalNetworkSettings() }.buttonStyle(SecondaryButtonStyle())
                Button("Firewall settings") { SystemLinks.firewallSettings() }.buttonStyle(SecondaryButtonStyle())
                Button("USB page") { ui.page = .usb }.buttonStyle(SecondaryButtonStyle())
            }
            HelpTopic(icon: "lock.shield", title: "Pairing code", steps: [
                "The first Wi‑Fi connection shows a 4‑digit code on the tablet.",
                "Check it matches and approve it on the Mac (pop-up window or menu bar).",
                "USB never needs pairing. Remove trusted tablets in Settings.",
            ]) {
                Button("Trusted tablets") { ui.page = .settings }.buttonStyle(SecondaryButtonStyle())
            }

            // ===== YOUR MAC =====
            SectionHeader(title: "Your Mac")
            HelpTopic(icon: "checkmark.shield", title: "Permissions", steps: [
                "Screen Recording is needed to show anything on the tablet.",
                "Accessibility is needed for touch, mouse and keyboard input.",
                "macOS may ask again after an app update (“…bypass the system private window picker…”). Choose Allow.",
            ]) {
                Button("Screen Recording") { Permissions.openScreenRecordingSettings() }.buttonStyle(SecondaryButtonStyle())
                Button("Accessibility") { Permissions.openAccessibilitySettings() }.buttonStyle(SecondaryButtonStyle())
            }
            HelpTopic(icon: "laptopcomputer", title: "Lid closed", steps: [
                "Turn on Extended display › Options › “Keep the tablet on with the lid closed”. The charger must be connected.",
                "Otherwise the tablet display is removed 10 s after you close the lid.",
                "If the tablet disconnects while the lid is closed, open the lid to get your screen back.",
            ]) {
                Button("Extended display") { ui.page = .display }.buttonStyle(SecondaryButtonStyle())
            }
            HelpTopic(icon: "menubar.dock.rectangle", title: "Primary mode", steps: [
                "The tablet gets the menu bar and Dock.",
                "When the tablet disconnects, or PlexiChore quits or crashes, your MacBook screen becomes main again.",
                "If the MacBook screen goes away during Primary (lid or hub), the main display is handed back to it when it returns.",
            ])

            // ===== ON THE TABLET =====
            SectionHeader(title: "On the tablet")
            HelpTopic(icon: "cursorarrow.rays", title: "Mouse pointer and touch", steps: [
                "Show the controls (swipe down from the top edge or tap with three fingers).",
                "Tap the input button to cycle Touch › Mouse › Input off.",
            ])

            // ===== FOOTER =====
            HStack(spacing: 12) {
                Text("PlexiChore Desktop \(controller.appVersion)  ·  Still stuck? Settings › Diagnostics shows the last event.")
                    .plexiCaption()
                Spacer(minLength: 12)
                Button("Diagnostics") { ui.page = .settings }.buttonStyle(GhostButtonStyle())
                Button("About") { ui.page = .about }.buttonStyle(GhostButtonStyle())
            }
            .padding(.leading, 4).padding(.top, 20)
        }
    }
}

/// The emergency release card: hotkey, menu item, button, and the last-resort ways out.
private struct EmergencyCard<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host

    var body: some View {
        PlexiCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top, spacing: 16) {
                    IconBubble(systemImage: "exclamationmark.octagon", tone: .bad)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Screen black or display stuck").plexiCardTitle()
                        Text("Press \(EmergencyHotKey.displayString) (Control‑Option‑Command‑D) or choose “Release Extended Display” in the menu bar. The tablet display is removed instantly and your displays are restored; tablets mirror for a short while.")
                            .plexiBody()
                    }
                    Spacer(minLength: 12)
                    Button { controller.releaseVirtualDisplayNow() } label: {
                        IconLabel(text: "Release now", systemImage: "eject")
                    }
                    .buttonStyle(SecondaryButtonStyle(danger: true))
                    .disabled(!controller.hasVirtualDisplay)
                }
                NoticeStrip(systemImage: "keyboard",
                            text: "Keyboard not responding either? Quitting PlexiChore also releases it, or run  killall -USR1 PlexiChore  in Terminal. Force-quitting is safe too: macOS removes the display and your arrangement is restored at next launch.",
                            tone: .neutral)
                    .padding(.top, 14)
            }
        }
    }
}

/// One troubleshooting topic: icon + title, short bullet steps, optional buttons underneath.
private struct HelpTopic<Actions: View>: View {
    let icon: String
    let title: String
    let steps: [String]
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        SettingRow {
            HStack(alignment: .top, spacing: 16) {
                RowIcon(icon).padding(.top, 1)
                VStack(alignment: .leading, spacing: 5) {
                    Text(title).font(.system(size: 14, weight: .semibold))
                    ForEach(steps.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").font(.system(size: 13)).foregroundColor(Theme.textTertiary)
                            Text(steps[i]).plexiBody()
                        }
                    }
                    if Actions.self != EmptyView.self {
                        HStack(spacing: 8) { actions() }.padding(.top, 6)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

extension HelpTopic where Actions == EmptyView {
    init(icon: String, title: String, steps: [String]) {
        self.init(icon: icon, title: title, steps: steps, actions: { EmptyView() })
    }
}
