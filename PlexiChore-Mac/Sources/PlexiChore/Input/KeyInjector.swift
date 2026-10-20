import CoreGraphics
import Foundation

/// Soft-keyboard support (KEY message, optional in the protocol).
/// `text` is typed as Unicode; otherwise the Android key code is mapped to a macOS virtual key.
final class KeyInjector {
    private let source = CGEventSource(stateID: .hidSystemState)

    func handle(_ msg: KeyMessage) {
        let isDown = (msg.action ?? "down") != "up"
        if let text = msg.text, !text.isEmpty {
            if isDown { type(text) }
            return
        }
        guard let code = msg.keyCode, let vk = Self.androidToMac[code] else { return }
        if let e = CGEvent(keyboardEventSource: source, virtualKey: vk, keyDown: isDown) {
            e.post(tap: .cghidEventTap)
        }
    }

    private func type(_ text: String) {
        // CGEventKeyboardSetUnicodeString accepts at most ~20 UTF-16 units per event.
        let units = Array(text.utf16)
        var index = 0
        while index < units.count {
            let chunk = Array(units[index..<min(index + 16, units.count)])
            index += 16
            for down in [true, false] {
                guard let e = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: down) else { continue }
                chunk.withUnsafeBufferPointer { buf in
                    e.keyboardSetUnicodeString(stringLength: buf.count, unicodeString: buf.baseAddress)
                }
                e.post(tap: .cghidEventTap)
            }
        }
    }

    /// Android KeyEvent.KEYCODE_* → macOS kVK_* (ANSI layout).
    static let androidToMac: [Int: CGKeyCode] = {
        var m: [Int: CGKeyCode] = [
            66: 0x24,   // ENTER → Return
            67: 0x33,   // DEL (backspace) → Delete
            112: 0x75,  // FORWARD_DEL → ForwardDelete
            61: 0x30,   // TAB
            62: 0x31,   // SPACE
            111: 0x35,  // ESCAPE
            19: 0x7E, 20: 0x7D, 21: 0x7B, 22: 0x7C,   // DPAD up/down/left/right
            122: 0x73,  // MOVE_HOME
            123: 0x77,  // MOVE_END
            92: 0x74,   // PAGE_UP
            93: 0x79,   // PAGE_DOWN
            55: 0x2B,   // COMMA
            56: 0x2F,   // PERIOD
            69: 0x1B,   // MINUS
            70: 0x18,   // EQUALS
            71: 0x21,   // LEFT_BRACKET
            72: 0x1E,   // RIGHT_BRACKET
            73: 0x2A,   // BACKSLASH
            74: 0x29,   // SEMICOLON
            75: 0x27,   // APOSTROPHE
            76: 0x2C,   // SLASH
            68: 0x32,   // GRAVE
        ]
        // Letters: KEYCODE_A (29) ... KEYCODE_Z (54)
        let letters: [CGKeyCode] = [
            0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, // a..m
            0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06  // n..z
        ]
        for (i, vk) in letters.enumerated() { m[29 + i] = vk }
        // Digits: KEYCODE_0 (7) ... KEYCODE_9 (16)
        let digits: [CGKeyCode] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19]
        for (i, vk) in digits.enumerated() { m[7 + i] = vk }
        return m
    }()
}
