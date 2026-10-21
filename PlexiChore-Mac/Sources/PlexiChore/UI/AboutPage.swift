import AppKit
import SwiftUI

/// Port of Views/Pages/AboutPage.xaml.
struct AboutPage<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host

    var body: some View {
        PageScroll {
            HeroCard(padding: EdgeInsets(top: 28, leading: 32, bottom: 28, trailing: 32)) {
                HStack(spacing: 24) {
                    LogoMark(size: 88)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("PlexiChore Desktop").font(.system(size: 28, weight: .semibold)).foregroundColor(.white)
                        Text("Version \(controller.appVersion)  ·  Turn your Android tablet into a portable monitor.")
                            .font(.system(size: 14)).foregroundColor(Theme.heroSecondary).padding(.top, 4)
                        (Text("Host ID ") + Text(controller.hostId).font(.system(size: 11.5, design: .monospaced)))
                            .font(.system(size: 11.5)).foregroundColor(Theme.heroTertiary)
                            .textSelection(.enabled)
                            .padding(.top, 10)
                        Text("macOS host · protocol v\(PlexiProtocol.version) · TCP \(String(PlexiProtocol.tcpPort)) · UDP \(String(PlexiProtocol.udpPort))")
                            .font(.system(size: 11.5)).foregroundColor(Theme.heroTertiary).padding(.top, 2)
                    }
                }
            }

            SectionHeader(title: "Components")
            PlexiCard(padding: EdgeInsets()) {
                VStack(spacing: 0) {
                    ComponentRow(title: "CGVirtualDisplay (CoreGraphics)",
                                 caption: "macOS virtual monitor used for Extend and Primary — built into macOS (private API)",
                                 button: nil, url: nil)
                    divider
                    ComponentRow(title: "ScreenCaptureKit · VideoToolbox",
                                 caption: "Apple frameworks for low-latency screen capture and hardware H.264 encoding",
                                 button: "Docs", url: "https://developer.apple.com/documentation/screencapturekit")
                    divider
                    ComponentRow(title: "Android SDK Platform-Tools (adb)",
                                 caption: "Downloaded on demand from Google under the Android SDK license",
                                 button: "Website", url: "https://developer.android.com/tools/releases/platform-tools")
                    divider
                    ComponentRow(title: "SwiftUI · AppKit",
                                 caption: "Native user interface and menu bar extra",
                                 button: nil, url: nil)
                }
            }
        }
    }

    private var divider: some View { Rectangle().fill(Theme.subtle).frame(height: 1) }
}

private struct ComponentRow: View {
    let title: String
    let caption: String
    let button: String?
    let url: String?

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13, weight: .semibold))
                Text(caption).plexiCaption()
            }
            Spacer()
            if let button, let url {
                Button(button) { SystemLinks.open(url) }.buttonStyle(GhostButtonStyle())
            }
        }
        .padding(.horizontal, 22).padding(.vertical, 14)
    }
}
