import AppKit
import SwiftUI

@main
struct PlexiChoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(openMainWindow: { appDelegate.showMainWindow() })
                .environmentObject(appDelegate.controller)
                .environmentObject(appDelegate.controller.adb)
        } label: {
            MenuBarLabel(controller: appDelegate.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let controller: HostController
    private var windows: WindowManager?

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

        let firstLaunch = !UserDefaults.standard.bool(forKey: "launchedBefore")
        UserDefaults.standard.set(true, forKey: "launchedBefore")
        if firstLaunch || !Permissions.screenRecordingGranted || !Permissions.accessibilityGranted {
            showMainWindow()
        }
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

    func showMainWindow() {
        windows?.showMain()
    }
}
