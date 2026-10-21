import AppKit
import SwiftUI

/// Pages of the main window, same order and names as the Windows app (MainWindow.xaml nav rail).
enum MainPage: Int, CaseIterable, Identifiable {
    case home, display, usb, settings, help, about
    var id: Int { rawValue }

    var title: String {
        switch self {
        case .home: return "Home"
        case .display: return "Extended display"
        case .usb: return "USB"
        case .settings: return "Settings"
        case .help: return "Help"
        case .about: return "About"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .display: return "display"
        case .usb: return "cable.connector"
        case .settings: return "gearshape"
        case .help: return "questionmark.circle"
        case .about: return "info.circle"
        }
    }
}

/// Shared navigation state (so the menu bar / notifications can open a specific page).
@MainActor
final class UIState: ObservableObject {
    @Published var page: MainPage = .home
}

/// The main window: 252 pt navigation rail + page area (port of MainWindow.xaml).
/// Generic over the host so tests can render it with fake state (HostController in the app).
struct MainWindowView<Host: HostUIModel>: View {
    @EnvironmentObject private var ui: UIState

    var body: some View {
        ZStack {
            BrandBackground()
            HStack(spacing: 0) {
                NavigationRail<Host>()
                    .frame(width: 252)
                ZStack {
                    switch ui.page {
                    case .home: HomePage<Host>()
                    case .display: DisplayPage<Host>()
                    case .usb: UsbPage<Host>()
                    case .settings: SettingsPage<Host>()
                    case .help: HelpPage<Host>()
                    case .about: AboutPage<Host>()
                    }
                }
                .padding(.top, 40)   // Windows: 40 px title bar row
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .frame(minWidth: 980, minHeight: 640)
        .foregroundColor(Theme.text)
    }
}

/// Standard page scaffold: margin 28,6,36,36, max width 1040, vertical scroll.
struct PageScroll<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                content()
            }
            .frame(maxWidth: 1040, alignment: .leading)
            .padding(.leading, 28).padding(.trailing, 36).padding(.top, 6).padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct PageHeader: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).plexiPageTitle()
            Text(subtitle).plexiPageSubtitle()
        }
    }
}

// MARK: - Navigation rail

private struct NavigationRail<Host: HostUIModel>: View {
    @EnvironmentObject private var ui: UIState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Brand (below the traffic lights)
            HStack(spacing: 12) {
                LogoMark(size: 38)
                VStack(alignment: .leading, spacing: 0) {
                    GradientText(text: "PlexiChore", font: .system(size: 19, weight: .bold))
                    Text("Desktop companion").font(.system(size: 11.5)).foregroundColor(Theme.textTertiary)
                }
            }
            .padding(.leading, 6).padding(.top, 6).padding(.bottom, 26)

            VStack(spacing: 4) {
                ForEach(MainPage.allCases) { page in
                    NavItem(page: page, selected: ui.page == page) { ui.page = page }
                }
            }
            Spacer(minLength: 12)
            ServerStatusCard<Host>()
        }
        .padding(.leading, 18).padding(.trailing, 10).padding(.top, 14 + 34).padding(.bottom, 18)
    }
}

private struct NavItem: View {
    let page: MainPage
    let selected: Bool
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: page.systemImage).font(.system(size: 16)).frame(width: 20)
                Text(page.title).font(.system(size: 14))
                Spacer()
            }
            .foregroundColor(selected || hover ? Theme.text : Theme.textSecondary)
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Color(hex: "#1A9A7BFF") : (hover ? Color(hex: "#0FFFFFFF") : .clear))
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2).fill(Theme.accentGradient).frame(width: 3, height: 18)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
    }
}

private struct ServerStatusCard<Host: HostUIModel>: View {
    @EnvironmentObject private var controller: Host

    var body: some View {
        PlexiCard(padding: EdgeInsets(top: 14, leading: 16, bottom: 14, trailing: 16), cornerRadius: 14) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 9) {
                    Circle().fill(controller.heroTone.color).frame(width: 10, height: 10)
                    Text("Server \(controller.serverPill)").font(.system(size: 13, weight: .semibold))
                }
                Text("\(controller.hostName) · port \(String(PlexiProtocol.tcpPort))")
                    .plexiCaption().lineLimit(1).truncationMode(.middle)
                    .padding(.leading, 19).padding(.top, 3).padding(.bottom, 10)
                Button { controller.togglePause() } label: {
                    IconLabel(text: controller.isPaused ? "Resume" : "Pause",
                              systemImage: controller.isPaused ? "play" : "pause")
                }
                .buttonStyle(SecondaryButtonStyle(fullWidth: true))
            }
        }
    }
}
