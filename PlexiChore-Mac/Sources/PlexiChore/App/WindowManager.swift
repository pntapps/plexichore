import AppKit
import SwiftUI

/// Owns the main settings/status window (an AppKit window hosting SwiftUI so it can be shown
/// from anywhere — e.g. when a pairing request arrives).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let controller: HostController
    private var window: NSWindow?

    init(controller: HostController) {
        self.controller = controller
        super.init()
    }

    func showMain() {
        if window == nil {
            let root = MainWindowView()
                .environmentObject(controller)
                .environmentObject(controller.adb)
            let hosting = NSHostingView(rootView: root)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 820, height: 720),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            w.title = "PlexiChore"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.appearance = NSAppearance(named: .darkAqua)
            w.isOpaque = false
            w.backgroundColor = .clear
            w.contentMinSize = NSSize(width: 720, height: 600)
            w.contentView = hosting
            w.delegate = self
            w.setFrameAutosaveName("PlexiChoreMainWindow")
            if !w.setFrameUsingName("PlexiChoreMainWindow") { w.center() }
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    func windowWillClose(_ notification: Notification) {
        // Keep the window object for fast reopening; the app keeps running in the menu bar.
    }
}
