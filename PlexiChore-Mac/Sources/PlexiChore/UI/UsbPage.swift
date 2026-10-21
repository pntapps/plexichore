import AppKit
import SwiftUI

/// Port of Views/Pages/UsbPage.xaml.
struct UsbPage<Host: HostUIModel>: View {
    @EnvironmentObject private var adb: Host.ADB

    var body: some View {
        PageScroll {
            PageHeader(title: "USB",
                       subtitle: "Over USB the tablet reaches this Mac through Android Debug Bridge (adb). PlexiChore forwards port 47800 to every authorized tablet automatically.")

            AdbStatusCard<Host>().padding(.top, 22)

            if adb.isMissing || adb.downloading {
                GetAdbCard<Host>().padding(.top, 12)
            }

            SectionHeader(title: "Detected devices")
            if adb.devices.isEmpty {
                PlexiCard {
                    VStack(spacing: 0) {
                        Image(systemName: "ipad.landscape").font(.system(size: 30)).foregroundColor(Theme.textTertiary)
                        Text("No Android devices detected").plexiCardTitle().padding(.top, 10).padding(.bottom, 4)
                        Text(adb.enabled ? "Plug in your tablet with a data-capable USB cable and make sure USB debugging is on."
                                         : "USB is turned off. Turn it on above to detect tablets.")
                            .plexiBody().multilineTextAlignment(.center)
                    }
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity)
                }
            } else {
                VStack(spacing: 10) {
                    ForEach(adb.devices) { d in DeviceCard(device: d) }
                }
            }

            SectionHeader(title: "First-time setup on the tablet")
            PlexiCard {
                HStack(alignment: .top, spacing: 18) {
                    SetupStep(title: "1 · Developer options", tint: Theme.cyan,
                              text: "Settings → About tablet → Software information → tap Build number seven times.")
                    SetupStep(title: "2 · USB debugging", tint: Theme.violetLight,
                              text: "Settings → Developer options → turn on USB debugging (or Wireless debugging).")
                    SetupStep(title: "3 · Allow this Mac", tint: Theme.green,
                              text: "When the tablet asks “Allow USB debugging?”, tick Always allow and tap Allow.")
                }
            }
        }
    }
}

private struct AdbStatusCard<Host: HostUIModel>: View {
    @EnvironmentObject private var adb: Host.ADB

    var body: some View {
        let (text, tone) = adb.statusSummary
        PlexiCard(padding: EdgeInsets(top: 22, leading: 24, bottom: 22, trailing: 24)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 16) {
                    IconBubble(systemImage: "cable.connector", size: 52, cornerRadius: 15, iconSize: 24, tone: tone)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(text).font(.system(size: 19, weight: .semibold))
                        Text(adb.adbPathText ?? (adb.enabled ? "adb not found" : "Turn on to use tablets over a USB cable"))
                            .font(.system(size: 11.5, design: .monospaced)).foregroundColor(Theme.textTertiary)
                            .lineLimit(1).truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: 16)
                    if adb.enabled && adb.adbPath != nil {
                        Button { adb.reapplyForwarding() } label: { IconLabel(text: "Re-apply forwarding", systemImage: "arrow.forward") }
                            .buttonStyle(SecondaryButtonStyle())
                        Button { adb.refresh() } label: { IconLabel(text: "Rescan", systemImage: "arrow.triangle.2.circlepath") }
                            .buttonStyle(SecondaryButtonStyle())
                    }
                    PlexiToggle(isOn: Binding(get: { adb.enabled }, set: { adb.enabled = $0 }))
                        .help("Use USB (adb) connections")
                }
                if let err = adb.lastError {
                    Text(err).font(.system(size: 13)).foregroundColor(Theme.errorText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 68).padding(.top, 10)
                }
            }
        }
    }
}

private struct GetAdbCard<Host: HostUIModel>: View {
    @EnvironmentObject private var adb: Host.ADB

    var body: some View {
        VStack(spacing: 0) {
            HeroCard(cornerRadius: 16, padding: EdgeInsets(top: 20, leading: 24, bottom: 20, trailing: 24)) {
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Get Android platform-tools").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        Text("One click downloads Google's official adb (about 7 MB) into your user Library. No admin rights needed.")
                            .font(.system(size: 13)).foregroundColor(Theme.heroSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text("Or install it with Homebrew:  brew install android-platform-tools")
                            .font(.system(size: 11.5, design: .monospaced)).foregroundColor(Theme.heroTertiary)
                            .textSelection(.enabled).padding(.top, 4)
                    }
                    Spacer(minLength: 16)
                    Button { adb.downloadPlatformTools() } label: {
                        IconLabel(text: adb.downloading ? "Downloading…" : "Download adb", systemImage: "arrow.down.circle")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(adb.downloading)
                }
            }
            if adb.downloading {
                // Windows: determinate ThinProgress; ADBManager doesn't report download progress, so indeterminate.
                ThinProgress().padding(.top, 10)
            }
        }
    }
}

private struct DeviceCard: View {
    let device: ADBManager.Device

    var body: some View {
        PlexiCard(padding: EdgeInsets(top: 16, leading: 20, bottom: 16, trailing: 20)) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 14) {
                    IconBubble(systemImage: "ipad.landscape", size: 40, iconSize: 18, fill: Theme.subtle2, tint: Theme.text)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name).plexiCardTitle()
                        HStack(spacing: 5) {
                            Image(systemName: device.connectionIcon).font(.system(size: 10))
                            Text("\(device.connectionText)  ·  \(device.serial)").lineLimit(1).truncationMode(.middle)
                        }
                        .font(.system(size: 11.5)).foregroundColor(Theme.textTertiary)
                    }
                    Spacer(minLength: 12)
                    HStack(spacing: 7) {
                        Circle().fill(device.tone.color).frame(width: 7, height: 7)
                        Text(device.stateText).font(.system(size: 11.5, weight: .semibold)).foregroundColor(device.tone.color)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Capsule().fill(device.tone.soft))
                }
                if let hint = device.hint {
                    HStack(alignment: .top, spacing: 9) {
                        Image(systemName: "lightbulb").font(.system(size: 14)).foregroundColor(Theme.amber)
                        Text(hint).font(.system(size: 13)).foregroundColor(Theme.hintText)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: 760, alignment: .leading)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Theme.amberSoft))
                    .padding(.leading, 54).padding(.top, 12)
                }
            }
        }
    }
}

private struct SetupStep: View {
    let title: String
    let tint: Color
    let text: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundColor(tint)
            Text(text).plexiBody()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
