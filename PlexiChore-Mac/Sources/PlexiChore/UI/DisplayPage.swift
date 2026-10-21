import AppKit
import SwiftUI

/// Port of Views/Pages/DisplayPage.xaml. On Windows this page installs/repairs the Virtual Display Driver;
/// on macOS the virtual monitor comes from CoreGraphics (CGVirtualDisplay), so the page shows its availability,
/// the live virtual monitor and the Retina/scale options instead.
struct DisplayPage<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host

    var body: some View {
        PageScroll {
            PageHeader(title: "Extended display",
                       subtitle: "Use the tablet as a real second monitor. PlexiChore asks macOS for a virtual screen (CGVirtualDisplay) only while a tablet is in Extend or Primary mode — no driver to install.")

            StatusCard<Host>().padding(.top, 22)

            SectionHeader(title: "Details")
            DetailsCard<Host>()

            SectionHeader(title: "Options")
            OptionsRows<Host>()

            SectionHeader(title: "Display modes")
            HStack(alignment: .top, spacing: 12) {
                InfoCard(systemImage: "arrow.left.arrow.right", tint: Theme.cyan, title: "Extend",
                         text: "The tablet becomes an extra monitor beside your screen. Your main display keeps the menu bar and Dock.")
                InfoCard(systemImage: "star", tint: Theme.violetLight, title: "Primary",
                         text: "The tablet becomes the Mac's main display: the menu bar and new windows open there. Your display stays on beside it, and your original main display is restored when the tablet disconnects.")
                InfoCard(systemImage: "rectangle.on.rectangle", tint: Theme.green, title: "Mirror",
                         text: "The tablet shows one of your existing displays. Always available — also used automatically when Extend or Primary is unavailable.")
            }
            .fixedSize(horizontal: false, vertical: true)

            SectionHeader(title: "How it works")
            HStack(alignment: .top, spacing: 12) {
                InfoCard(systemImage: "ipad.landscape", tint: Theme.cyan, title: "Tablet asks to extend",
                         text: "A virtual monitor matching the tablet's resolution and refresh rate is plugged in on demand.")
                InfoCard(systemImage: "arrow.left.arrow.right", tint: Theme.violetLight, title: "Placed beside your screen",
                         text: "It sits left, right, above or below your main display — whichever side the tablet chose. Rearrange it any time in System Settings › Displays.")
                InfoCard(systemImage: "powerplug", tint: Theme.green, title: "Gone when you disconnect",
                         text: "macOS moves your windows back to the main screen a few seconds after the tablet leaves (kept briefly so a quick reconnect doesn't reshuffle them).")
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct StatusCard<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host

    var body: some View {
        let (title, detail, tone) = status
        PlexiCard(padding: EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    IconBubble(systemImage: "display", size: 52, cornerRadius: 15, iconSize: 24, tone: tone)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(title).font(.system(size: 19, weight: .semibold))
                        Text(detail).plexiBody()
                    }
                    Spacer(minLength: 16)
                    HStack(spacing: 8) {
                        if controller.virtualDisplaySupported {
                            if controller.prefs.allowVirtualDisplay {
                                Button { controller.prefs.allowVirtualDisplay = false } label: {
                                    IconLabel(text: "Turn off", systemImage: "power")
                                }
                                .buttonStyle(SecondaryButtonStyle(danger: true))
                            } else {
                                Button { controller.prefs.allowVirtualDisplay = true } label: {
                                    IconLabel(text: "Turn on", systemImage: "power")
                                }
                                .buttonStyle(PrimaryButtonStyle())
                            }
                        }
                        Button { SystemLinks.displaysSettings() } label: {
                            IconLabel(text: "Arrange displays", systemImage: "rectangle.3.group")
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                }

                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    if let hold = controller.virtualDisplaySafetyHold {
                        NoticeStrip(systemImage: "pause.circle",
                                    text: "Extended display paused for safety – \(Int(hold.rounded(.up))) s. Tablets mirror until then.",
                                    tone: .warn, textColor: Theme.hintText) {
                            Button("Resume now") { controller.resumeVirtualDisplay() }.buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(.leading, 68).padding(.top, 14)
                    }
                }

                if !controller.virtualDisplaySupported {
                    NoticeStrip(systemImage: "exclamationmark.triangle",
                                text: "This version of macOS doesn't offer virtual displays to PlexiChore, so tablets mirror an existing display instead. Updating macOS usually brings it back.",
                                tone: .bad, textColor: Theme.errorText)
                        .padding(.leading, 68).padding(.top, 14)
                } else if !controller.screenRecordingGranted {
                    NoticeStrip(systemImage: "info.circle",
                                text: "Screen Recording permission is needed to show the virtual display on the tablet.",
                                tone: .neutral) {
                        Button("Allow") { controller.requestScreenRecording() }.buttonStyle(SecondaryButtonStyle())
                    }
                    .padding(.leading, 68).padding(.top, 14)
                }
            }
        }
    }

    private var status: (String, String, Tone) {
        switch controller.extendState {
        case .ready: return ("Virtual display ready", "Tablets that ask for “Extend” get their own monitor next to your main screen.", .good)
        case .inUse: return ("Virtual display in use", "A tablet is using its own monitor next to your main screen.", .good)
        case .disabled: return ("Turned off", "Tablets can only mirror an existing display. Turn it on to use your tablet as a second screen.", .warn)
        case .unsupported: return ("Not available", "Virtual displays aren't available on this Mac, so tablets mirror instead.", .bad)
        }
    }
}

private struct DetailsCard<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host

    var body: some View {
        let vs = controller.activeVirtualScreen
        PlexiCard(padding: EdgeInsets()) {
            VStack(spacing: 0) {
                DetailRow(label: "Virtual monitor") {
                    Text(monitorText(vs)).fontWeight(.semibold)
                }
                divider
                DetailRow(label: "Display modes") {
                    Text(modesText).fixedSize(horizontal: false, vertical: true)
                        .help("macOS accepts any resolution for a virtual display, so the tablet's exact size is always used (no mode list to repair).")
                }
                divider
                DetailRow(label: "Display ID") {
                    Text(vs.map { String($0.displayID) } ?? "—").font(Theme.mono)
                } trailing: {
                    Button("Displays settings") { SystemLinks.displaysSettings() }.buttonStyle(GhostButtonStyle())
                }
                divider
                DetailRow(label: "Provider") {
                    (Text("CGVirtualDisplay (CoreGraphics)").fontWeight(.semibold)
                        + Text("  ·  built into macOS · private API").foregroundColor(Theme.textTertiary))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.subtle).frame(height: 1) }

    private func monitorText(_ vs: VirtualScreenInfo?) -> String {
        if let vs {
            var s = "In use: \(vs.name) · \(vs.pixelWidth) × \(vs.pixelHeight)"
            if vs.scaleFactor >= 1.5 { s += " · Retina (looks like \(vs.pointWidth) × \(vs.pointHeight))" }
            if vs.isMain { s += " · main display" }
            return s
        }
        switch controller.extendState {
        case .unsupported: return "Not available on this macOS version"
        case .disabled: return "None — turned off"
        default: return "None — created when a tablet asks for Extend"
        }
    }

    private var modesText: String {
        controller.prefs.hiDPI
            ? "Any tablet resolution · Retina (HiDPI): text drawn at 2×, the screen looks like half its pixel size"
            : "Any tablet resolution · Standard (1×): one pixel per point, more room but smaller text"
    }
}

private struct DetailRow<Value: View, Trailing: View>: View {
    let label: String
    @ViewBuilder var value: () -> Value
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 0) {
            Text(label).foregroundColor(Theme.textSecondary).frame(width: 210, alignment: .leading)
            value().frame(maxWidth: .infinity, alignment: .leading)
            trailing()
        }
        .font(.system(size: 13))
        .padding(.horizontal, 22).padding(.vertical, 16)
    }
}

extension DetailRow where Trailing == EmptyView {
    init(label: String, @ViewBuilder value: @escaping () -> Value) {
        self.init(label: label, value: value, trailing: { EmptyView() })
    }
}

private struct OptionsRows<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host

    var body: some View {
        VStack(spacing: 0) {
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("textformat.size")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Display scale").font(.system(size: 14))
                        Text("Used when the tablet's Display size is set to Auto. Retina makes text crisp; Standard gives more room.").plexiCaption()
                    }
                    Spacer(minLength: 12)
                    Picker("", selection: Binding(get: { controller.prefs.displayScaleMode },
                                                  set: { controller.setDisplayScaleMode($0) })) {
                        Text("Auto (from tablet density)").tag("auto")
                        Text("Retina (2×)").tag("hidpi")
                        Text("Standard (1×)").tag("standard")
                    }
                    .labelsHidden().frame(width: 240)
                }
            }
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("display.2")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Allow Extend and Primary").font(.system(size: 14))
                        Text("When off, every tablet mirrors an existing display.").plexiCaption()
                    }
                    Spacer(minLength: 12)
                    PlexiToggle(isOn: $controller.prefs.allowVirtualDisplay)
                        .disabled(!controller.virtualDisplaySupported)
                }
            }
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("laptopcomputer")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep the tablet on with the lid closed").font(.system(size: 14))
                        Text("Lets the tablet stay your only screen when you close the MacBook lid. Works only while the charger is connected; if the tablet disconnects, the virtual display is removed so opening the lid brings your screen back. Off: removed 10 s after the lid closes.").plexiCaption()
                    }
                    Spacer(minLength: 12)
                    PlexiToggle(isOn: $controller.prefs.keepWithLidClosed)
                        .disabled(!controller.virtualDisplaySupported || !controller.prefs.allowVirtualDisplay)
                }
            }
            SettingRow {
                HStack(spacing: 16) {
                    RowIcon("exclamationmark.octagon")
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Emergency release  \(EmergencyHotKey.displayString)").font(.system(size: 14))
                        Text("If the virtual display ever leaves your Mac unusable, press \(EmergencyHotKey.displayString) (or use the menu bar) to remove it instantly and restore your displays. Tablets mirror for a short while afterwards.").plexiCaption()
                    }
                    Spacer(minLength: 12)
                    Button { controller.releaseVirtualDisplayNow() } label: {
                        IconLabel(text: "Release now", systemImage: "eject")
                    }
                    .buttonStyle(SecondaryButtonStyle(danger: true))
                    .disabled(!controller.hasVirtualDisplay)
                }
            }
            Text("Mode (Extend, Primary or Mirror), position, resolution and Display size are chosen on the tablet.")
                .plexiCaption().padding(.leading, 4).padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct RowIcon: View {
    let name: String
    init(_ name: String) { self.name = name }
    var body: some View {
        Image(systemName: name).font(.system(size: 17)).foregroundColor(Theme.textSecondary).frame(width: 22)
    }
}

struct InfoCard: View {
    let systemImage: String
    let tint: Color
    let title: String
    let text: String

    var body: some View {
        PlexiCard(fillHeight: true) {
            VStack(alignment: .leading, spacing: 0) {
                // Fixed icon box so titles line up across the row (Windows: 22 px SymbolIcon).
                Image(systemName: systemImage).font(.system(size: 20)).foregroundColor(tint)
                    .frame(width: 26, height: 24, alignment: .leading)
                Text(title).plexiCardTitle().padding(.top, 10).padding(.bottom, 4)
                Text(text).plexiBody()
            }
        }
    }
}
