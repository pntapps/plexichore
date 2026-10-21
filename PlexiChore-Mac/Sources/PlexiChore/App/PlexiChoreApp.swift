import AppKit
import Combine
import SwiftUI

@main
struct PlexiChoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(openMainWindow: { page in appDelegate.showMainWindow(page: page) },
                        showPairing: { id in appDelegate.showPairing(id) })
                .environmentObject(appDelegate.controller)
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.menu)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: HostController
    private var windows: WindowManager?
    private var cancellables: Set<AnyCancellable> = []
    private var notifiedSessions: Set<UUID> = []

    override init() {
        controller = HostController()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar app: no Dock icon (also when run unbundled via `swift run`).
        NSApp.setActivationPolicy(.accessory)
        let wm = WindowManager(controller: controller)
        windows = wm
        controller.presentMainWindow = { [weak self] in self?.showMainWindow() }
        controller.start()
        observeConnections()

        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        if firstLaunch || !Permissions.screenRecordingGranted || !Permissions.accessibilityGranted {
            showMainWindow()
        }
    }

    /// "Notify when a tablet connects" (App.xaml.cs OnTabletConnected): once per session, when it starts streaming.
    private func observeConnections() {
        controller.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] list in
                guard let self else { return }
                let ids = Set(list.map(\.id))
                self.notifiedSessions.formIntersection(ids)
                for s in list where s.phase == .streaming && !self.notifiedSessions.contains(s.id) {
                    self.notifiedSessions.insert(s.id)
                    if self.controller.prefs.showConnectNotifications { Notifier.tabletConnected(s) }
                }
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showMainWindow()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func showMainWindow(page: MainPage? = nil) {
        windows?.showMain(page: page)
    }

    func showPairing(_ id: UUID) {
        windows?.showPairing(id)
    }
}
