import CoreGraphics
import Foundation

/// KEY message (0x05, optional; the tablet does not send it yet). Same semantics as the Windows host
/// (`InputInjector.HandleKey`):
/// - `text` non-empty: typed as Unicode on "down" only (`up` ignored); "\n" (and "\r", "\r\n") → Return key.
/// - otherwise the Android key code is mapped to a macOS virtual key and sent down/up as given
///   (missing action = down). Modifier keys (shift/ctrl/alt/meta→⌘, fn) are tracked so following
///   keys carry their flags; Caps Lock toggles.
/// Events are dropped while Accessibility permission is missing. Not thread-safe: one queue.
final class KeyInjector {
    private let source: CGEventSource?
    private var heldModifiers = Set<CGKeyCode>()
    private var capsLock = false
    private var trusted = false
    private var trustCheckedAt: TimeInterval = -.infinity

    init() {
        let src = CGEventSource(stateID: .hidSystemState)
        src?.localEventsSuppressionInterval = 0
        source = src
    }

    deinit { releaseAll() }

    func handle(_ msg: KeyMessage) {
        let isDown = (msg.action ?? "down").lowercased() != "up"
        if let text = msg.text, !text.isEmpty {
            if isDown { type(text) }
            return
        }
        guard let code = msg.keyCode, let vk = KeyMapping.macKey(forAndroid: code) else { return }
        key(vk, down: isDown)
    }

    /// Releases held modifier keys (session end).
    func releaseAll() {
        for vk in heldModifiers { key(vk, down: false) }
        heldModifiers.removeAll()
    }

    private func key(_ vk: CGKeyCode, down: Bool) {
        if vk == KeyMapping.VK.capsLock {
            if down { capsLock.toggle() }
            postFlagsChanged(vk)
            return
        }
        if KeyMapping.modifierFlag(for: vk) != nil {
            if down { heldModifiers.insert(vk) } else { heldModifiers.remove(vk) }
            postFlagsChanged(vk)
            return
        }
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: down) else { return }
        e.flags = KeyMapping.flags(forHeld: heldModifiers, capsLock: capsLock).union(KeyMapping.extraFlags(for: vk))
        send(e)
    }

    private func postFlagsChanged(_ vk: CGKeyCode) {
        guard let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: true) else { return }
        e.type = .flagsChanged
        e.flags = KeyMapping.flags(forHeld: heldModifiers, capsLock: capsLock)
        send(e)
    }

    private func type(_ text: String) {
        for piece in KeyMapping.textPieces(text) {
            switch piece {
            case .returnKey:
                key(KeyMapping.VK.returnKey, down: true)
                key(KeyMapping.VK.returnKey, down: false)
            case .unicode(let units):
                for down in [true, false] {
                    guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                    e.flags = []   // held modifiers must not alter the typed characters
                    units.withUnsafeBufferPointer { buf in
                        e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                    }
                    send(e)
                }
            }
        }
    }

    private func send(_ e: CGEvent) {
        let now = ProcessInfo.processInfo.systemUptime
        if now - trustCheckedAt > 2 {
            trusted = Permissions.accessibilityGranted
            trustCheckedAt = now
        }
        guard trusted else { return }
        e.post(tap: .cghidEventTap)
    }
}
