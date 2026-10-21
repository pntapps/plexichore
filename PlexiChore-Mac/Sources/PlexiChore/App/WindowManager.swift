import AppKit
import Combine
import SwiftUI

/// Owns the main window and the pairing approval panels (AppKit windows hosting SwiftUI so they can be shown
/// from anywhere — menu bar, notifications, pairing requests).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private let controller: HostController
    let ui = UIState()
    private var window: NSWindow?
    private var pairingPanels: [UUID: NSPanel] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var toldAboutMenuBar = false

    init(controller: HostController) {
        self.controller = controller
        super.init()

        controller.$pendingPairings
            .receive(on: RunLoop.main)
            .sink { [weak self] list in self?.syncPairingPanels(list) }
            .store(in: &cancellables)
        controller.$prefs
            .map(\.appearance)
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.applyAppearance() }
            .store(in: &cancellables)
    }

    // MARK: Main window

    func showMain(page: MainPage? = nil) {
        if let page { ui.page = page }
        if window == nil {
            let root = MainWindowView<HostController>()
                .environmentObject(controller)
                .environmentObject(controller.adb)
                .environmentObject(ui)
            let hosting = NSHostingView(rootView: root)
            let w = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                backing: .buffered,
                defer: false)
            w.title = "PlexiChore Desktop"
            w.titlebarAppearsTransparent = true
            w.titleVisibility = .hidden
            w.isMovableByWindowBackground = true
            w.isReleasedWhenClosed = false
            w.contentMinSize = NSSize(width: 980, height: 640)
            w.contentView = hosting
            w.delegate = self
            w.setFrameAutosaveName("PlexiChoreMainWindow.v2")
            if !w.setFrameUsingName("PlexiChoreMainWindow.v2") {
                // Fit the Windows default (1200 x 800) on smaller screens.
                if let vis = NSScreen.main?.visibleFrame {
                    let size = NSSize(width: min(1200, vis.width - 40), height: min(800, vis.height - 40))
                    w.setContentSize(size)
                }
                w.center()
            }
            window = w
            applyAppearance()
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        window?.orderFrontRegardless()
    }

    private func applyAppearance() {
        let appearance: NSAppearance?
        switch controller.prefs.appearance {
        case "light": appearance = NSAppearance(named: .aqua)
        case "system": appearance = nil
        default: appearance = NSAppearance(named: .darkAqua)
        }
        window?.appearance = appearance
        window?.backgroundColor = NSColor(Theme.base)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        // Keep the window object for fast reopening; the app keeps running in the menu bar
        // (Windows: "hidden to tray" notification, once per run).
        if !toldAboutMenuBar {
            toldAboutMenuBar = true
            Notifier.post(title: "PlexiChore is still running",
                          body: "Tablets can keep connecting. Use the menu bar icon to open or quit.")
        }
    }

    // MARK: Pairing panels (PairingWindow.xaml)

    func showPairing(_ id: UUID) {
        if let panel = pairingPanels[id] {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        } else if let p = controller.pendingPairings.first(where: { $0.id == id }) {
            openPairingPanel(p)
        }
    }

    private func syncPairingPanels(_ list: [PendingPairing]) {
        let ids = Set(list.map(\.id))
        for (id, panel) in pairingPanels where !ids.contains(id) {
            pairingPanels[id] = nil
            panel.close()
        }
        for p in list where pairingPanels[p.id] == nil {
            openPairingPanel(p)
        }
    }

    private func openPairingPanel(_ p: PendingPairing) {
        let id = p.id
        let view = PairingWindowView(pairing: p) { [weak self] approve, remember in
            guard let self else { return }
            if approve { self.controller.approvePairing(id, remember: remember) }
            else { self.controller.rejectPairing(id) }
            if let panel = self.pairingPanels.removeValue(forKey: id) { panel.close() }
        }
        let hosting = NSHostingView(rootView: view)
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        let panel = KeyablePanel(contentRect: NSRect(origin: .zero, size: size),
                                 styleMask: [.borderless, .fullSizeContentView],
                                 backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.title = "PlexiChore — Approve tablet"
        panel.contentView = hosting
        panel.center()
        // Cascade several simultaneous requests.
        if !pairingPanels.isEmpty {
            let f = panel.frame
            panel.setFrameOrigin(NSPoint(x: f.minX + CGFloat(pairingPanels.count) * 28, y: f.minY - CGFloat(pairingPanels.count) * 28))
        }
        pairingPanels[id] = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        NSSound(named: "Glass")?.play()
    }
}

/// Borderless panels can't become key by default; the pairing card needs Return / Esc.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}
