import AppKit
import SwiftUI

/// Port of Views/Pages/HomePage.xaml: hero, connected tablets, empty-state "how to connect" cards.
struct HomePage<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host
    @EnvironmentObject private var adb: Host.ADB
    @EnvironmentObject private var ui: UIState

    var body: some View {
        PageScroll {
            HeroSection<Host>()

            if controller.permissionsMissing {
                PermissionsBanner<Host>().padding(.top, 14)
            }

            SectionHeader(title: "Connected tablets")

            if controller.sessions.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    ConnectCard(
                        systemImage: "cable.connector", tint: Theme.cyan, bubble: Theme.cyanSoft,
                        title: "Connect with USB", caption: "Lowest latency · charges while you work",
                        steps: [Text("Turn on USB debugging in the tablet's Developer options."),
                                Text("Plug it in and tap Allow on the debugging prompt."),
                                Text("Open PlexiChore on the tablet — this Mac shows up as USB.")],
                        link: "Check USB status  →") { ui.page = .usb }
                    ConnectCard(
                        systemImage: "wifi", tint: Theme.violetLight, bubble: Theme.violetSoft,
                        title: "Connect over Wi‑Fi", caption: "No cable · same network",
                        steps: [Text("Put the tablet on the same Wi‑Fi as this Mac."),
                                Text("Open PlexiChore and pick ") + Text(controller.hostName).fontWeight(.semibold).foregroundColor(Theme.text) + Text("."),
                                Text("Confirm the 4‑digit code here the first time.")],
                        link: "Firewall & pairing settings  →") { ui.page = .settings }
                }
                .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 12) {
                    ForEach(controller.sessions) { s in SessionCard<Host>(session: s) }
                }
            }

            if let msg = controller.lastMessage, !msg.isEmpty {
                HStack(spacing: 7) {
                    Image(systemName: "info.circle").font(.system(size: 12))
                    Text(msg).lineLimit(2)
                }
                .plexiCaption()
                .padding(.top, 14).padding(.leading, 4)
            }
        }
    }
}

// MARK: - Hero

private struct HeroSection<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host
    @EnvironmentObject private var adb: Host.ADB

    var body: some View {
        HeroCard {
            HStack(alignment: .center, spacing: 24) {
                VStack(alignment: .leading, spacing: 0) {
                    LivePill(text: controller.serverPill, tone: controller.heroTone)
                    Text(controller.heroTitle)
                        .font(.system(size: 32, weight: .semibold)).foregroundColor(.white)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 16)
                    if !controller.heroSubtitle.isEmpty {
                        Text(controller.heroSubtitle)
                            .font(.system(size: 14.5)).foregroundColor(Theme.heroSecondary).lineSpacing(3)
                            .frame(maxWidth: 560, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 8)
                    }
                    FlowChips(chips: [adb.usbChip, controller.wifiChip, controller.extendChip])
                        .padding(.top, 20)
                    HStack(spacing: 7) {
                        Image(systemName: "desktopcomputer").font(.system(size: 13))
                        Text(controller.hostName + (controller.ipAddressesText.isEmpty ? "" : "   " + controller.ipAddressesText))
                            .font(.system(size: 12.5)).lineLimit(1).truncationMode(.tail)
                            .textSelection(.enabled)
                    }
                    .foregroundColor(Theme.heroTertiary)
                    .padding(.top, 10).padding(.leading, 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                HeroIllustration()
                    .frame(width: 290, height: 196)
            }
        }
    }
}

/// Pill with a pulsing halo (HomePage.xaml "live pill" storyboard: 0.6 → 1.25 scale, 1.6 s, forever).
private struct LivePill: View {
    let text: String
    let tone: Tone
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                Circle().fill(tone.color)
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulse ? 1.25 : 0.6)
                    .opacity(pulse ? 0 : 0.55)
                Circle().fill(tone.color).frame(width: 7, height: 7)
            }
            .frame(width: 14, height: 14)
            Text(text).font(.system(size: 12, weight: .semibold)).foregroundColor(tone.color)
        }
        .padding(.leading, 10).padding(.trailing, 12).padding(.vertical, 4)
        .background(Capsule().fill(tone.soft))
        .onAppear {
            withAnimation(.easeOut(duration: 1.6).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

private struct FlowChips: View {
    let chips: [(String, Tone)]
    var body: some View {
        // Three chips: a simple HStack that wraps to a VStack when narrow (macOS 13 has no Layout-free wrap panel).
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 6) { content }
        }
    }
    @ViewBuilder private var content: some View {
        ForEach(chips.indices, id: \.self) { i in StatusChip(text: chips[i].0, tone: chips[i].1) }
    }
}

/// Monitor + tablet illustration from HomePage.xaml (Canvas 290 x 196).
private struct HeroIllustration: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Ellipse()
                .fill(RadialGradient(colors: [Color(hex: "#667C4DFF"), Color(hex: "#0000E5FF")], center: .center, startRadius: 0, endRadius: 130))
                .frame(width: 260, height: 190).opacity(0.55)
                .offset(x: 20, y: 10)
            // monitor
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(hex: "#33130E2E"))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color(hex: "#E6FFFFFF"), lineWidth: 3))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(LinearGradient(colors: [Color(hex: "#557C4DFF"), Color(hex: "#2200E5FF")], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 7) {
                                Capsule().fill(Color(hex: "#55FFFFFF")).frame(width: 64, height: 7)
                                Capsule().fill(Color(hex: "#33FFFFFF")).frame(width: 96, height: 7)
                                Capsule().fill(Color(hex: "#33FFFFFF")).frame(width: 44, height: 7)
                            }
                            .padding(10)
                        }
                        .padding(8 + 3)
                )
                .frame(width: 176, height: 114)
                .offset(x: 14, y: 18)
            Rectangle().fill(Color(hex: "#E6FFFFFF")).frame(width: 20, height: 20).offset(x: 92, y: 132)
            Capsule().fill(Color(hex: "#E6FFFFFF")).frame(width: 72, height: 10).offset(x: 66, y: 150)
            // link dots
            Circle().fill(Color(hex: "#AA00E5FF")).frame(width: 6, height: 6).offset(x: 196, y: 70)
            Circle().fill(Color(hex: "#7700E5FF")).frame(width: 6, height: 6).offset(x: 208, y: 70)
            // tablet
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color(hex: "#F2FFFFFF"))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Theme.accentGradient)
                        .overlay(alignment: .topLeading) {
                            VStack(alignment: .leading, spacing: 6) {
                                Capsule().fill(Color(hex: "#66FFFFFF")).frame(width: 40, height: 6)
                                Capsule().fill(Color(hex: "#44FFFFFF")).frame(width: 62, height: 6)
                            }
                            .padding(.leading, 10).padding(.top, 10)
                        }
                        .overlay(alignment: .bottomTrailing) {
                            Image(systemName: "pencil.tip").font(.system(size: 17, weight: .medium))
                                .foregroundColor(Color(hex: "#CCFFFFFF")).padding(.trailing, 10).padding(.bottom, 8)
                        }
                        .padding(7)
                )
                .frame(width: 132, height: 92)
                .shadow(color: Color(hex: "#73140A33"), radius: 12, x: 0, y: 6)
                .offset(x: 150, y: 70)
        }
        .frame(width: 290, height: 196, alignment: .topLeading)
        .allowsHitTesting(false)
    }
}

// MARK: - Permissions (macOS only)

struct PermissionsBanner<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host
    @EnvironmentObject private var ui: UIState

    var body: some View {
        PlexiCard {
            HStack(spacing: 14) {
                IconBubble(systemImage: "exclamationmark.triangle", size: 40, iconSize: 18, tone: .warn)
                VStack(alignment: .leading, spacing: 2) {
                    Text("macOS permissions needed").plexiCardTitle()
                    Text(missingText).plexiCaption()
                }
                Spacer(minLength: 12)
                if !controller.screenRecordingGranted {
                    Button { controller.requestScreenRecording() } label: { Text("Allow Screen Recording") }
                        .buttonStyle(PrimaryButtonStyle())
                } else if !controller.accessibilityGranted {
                    Button { controller.requestAccessibility() } label: { Text("Allow Accessibility") }
                        .buttonStyle(PrimaryButtonStyle())
                }
                Button("Details") { ui.page = .settings }.buttonStyle(GhostButtonStyle())
            }
        }
    }

    private var missingText: String {
        var parts: [String] = []
        if !controller.screenRecordingGranted { parts.append("Screen Recording (to show your screen on the tablet)") }
        if !controller.accessibilityGranted { parts.append("Accessibility (for touch and pen input)") }
        return "PlexiChore needs " + parts.joined(separator: " and ") + "."
    }
}

// MARK: - Session card

private struct SessionCard<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host
    let session: SessionSummary

    var body: some View {
        PlexiCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    IconBubble(systemImage: "ipad.landscape", iconSize: 20, fill: Theme.accentGradient, tint: .white)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(session.displayName).font(.system(size: 16.5, weight: .semibold)).lineLimit(1)
                        HStack(spacing: 0) {
                            Badge(text: session.transportText, systemImage: session.transportIcon,
                                  fill: Theme.cyanSoft, tint: Theme.cyan).padding(.trailing, 6)
                            Badge(text: session.modeText, fill: session.phase == .streaming ? Theme.violetSoft : Theme.amberSoft,
                                  tint: session.phase == .streaming ? Theme.violetLight : Theme.amber).padding(.trailing, 6)
                            if let scale = session.scaleText {
                                Badge(text: scale, fill: Theme.violetSoft, tint: Theme.violetLight).padding(.trailing, 6)
                                    .help("Display scale of the tablet's virtual monitor (text and pointer size). Change it on the tablet: Settings › Display size.")
                            }
                            TimelineView(.periodic(from: .now, by: 10)) { tl in
                                // Windows: "{Model} · {Codec} · connected {Duration}" (encoder in the tooltip).
                                Text("\(session.modelText) · \(session.codecText) · connected \(session.durationText(now: tl.date))")
                                    .plexiCaption().lineLimit(1)
                                    .help(session.encoderText.map { "Encoder: \($0)" } ?? "")
                            }
                            .padding(.leading, 4)
                        }
                    }
                    Spacer(minLength: 12)
                    Button { controller.disconnect(session.id) } label: {
                        IconLabel(text: "Disconnect", systemImage: "cable.connector.slash")
                    }
                    .buttonStyle(SecondaryButtonStyle(danger: true))
                }

                if session.phase == .streaming {
                    HStack(spacing: 8) {
                        StatTile(label: "Resolution", value: session.resolutionText)
                        StatTile(label: "Frame rate", value: session.fpsText, suffix: " / \(session.fps) fps")
                        StatTile(label: "Bitrate", value: session.bitrateText)
                        StatTile(label: "Latency (RTT)", value: session.rttText)
                        StatTile(label: "Encode", value: session.encodeText)
                    }
                    .padding(.top, 18)
                }
            }
        }
    }
}

// MARK: - Empty state card

private struct ConnectCard: View {
    let systemImage: String
    let tint: Color
    let bubble: Color
    let title: String
    let caption: String
    let steps: [Text]
    let link: String
    let action: () -> Void

    var body: some View {
        PlexiCard(fillHeight: true) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 12) {
                    IconBubble(systemImage: systemImage, size: 40, iconSize: 18, fill: bubble, tint: tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title).plexiCardTitle()
                        Text(caption).plexiCaption()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(steps.indices, id: \.self) { i in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text("\(i + 1)").fontWeight(.bold).foregroundColor(tint).frame(width: 20, alignment: .leading)
                            steps[i]
                        }
                        .plexiBody()
                    }
                }
                .padding(.top, 16).padding(.leading, 2)
                Button(link, action: action).buttonStyle(GhostButtonStyle())
                    .padding(.top, 12).padding(.leading, -6)
            }
        }
    }
}
