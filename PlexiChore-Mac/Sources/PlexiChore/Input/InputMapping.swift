import CoreGraphics
import Foundation

/// Pure, side-effect-free helpers behind `InputInjector` / `KeyInjector` (unit-testable; nothing here
/// posts events or touches the window server).
enum InputMapping {

    // MARK: - Coordinates

    /// Normalized rectangle (0..1 in both axes) that the display's picture occupies inside the
    /// encoded VIDEO frame. ScreenCaptureKit preserves the display's aspect ratio, so when the
    /// frame aspect differs (mirror mode on a display whose aspect != tablet's) the picture is
    /// letterboxed/pillarboxed *inside* the frame. Returns the full unit rect when sizes are
    /// unknown or the aspects match.
    static func contentRect(displaySize: CGSize, frameSize: CGSize?) -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        guard let f = frameSize, f.width > 0, f.height > 0,
              displaySize.width > 0, displaySize.height > 0 else { return unit }
        let scale = min(f.width / displaySize.width, f.height / displaySize.height)
        let w = displaySize.width * scale / f.width
        let h = displaySize.height * scale / f.height
        if abs(w - 1) < 0.002 && abs(h - 1) < 0.002 { return unit }
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    /// Maps a protocol coordinate (0..1 within the VIDEO frame, letterbox already removed by the
    /// tablet) to a global CoreGraphics point (top-left origin, points) on the display `bounds`
    /// (`CGDisplayBounds`: virtual display in extend/primary, captured display in mirror; already
    /// reflects display rotation, HiDPI scale and the display's position in the arrangement).
    /// Windows `InputInjector.Map` equivalent: clamps to 0..1 (NaN/inf → 0) and keeps the point
    /// strictly on the display so the cursor never hops to a neighbouring monitor.
    static func screenPoint(x: Float, y: Float, bounds: CGRect, content: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> CGPoint? {
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        var nx = clamp01(x), ny = clamp01(y)
        if content.width > 0, content.height > 0, content != CGRect(x: 0, y: 0, width: 1, height: 1) {
            nx = min(max((nx - content.minX) / content.width, 0), 1)
            ny = min(max((ny - content.minY) / content.height, 0), 1)
        }
        let px = min(bounds.minX + nx * bounds.width, bounds.maxX - 1)
        let py = min(bounds.minY + ny * bounds.height, bounds.maxY - 1)
        return CGPoint(x: max(px, bounds.minX), y: max(py, bounds.minY))
    }

    static func clamp01(_ v: Float) -> CGFloat {
        guard v.isFinite else { return 0 }
        return CGFloat(min(max(v, 0), 1))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat { hypot(a.x - b.x, a.y - b.y) }

    static func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let n = CGFloat(pts.count)
        return CGPoint(x: pts.reduce(0) { $0 + $1.x } / n, y: pts.reduce(0) { $0 + $1.y } / n)
    }

    /// Mean distance of the points from their centroid (pinch "spread").
    static func spread(_ pts: [CGPoint]) -> CGFloat {
        guard pts.count >= 2 else { return 0 }
        let c = centroid(pts)
        return pts.reduce(0) { $0 + distance($1, c) } / CGFloat(pts.count)
    }

    // MARK: - Touch gestures (Windows touch-injection semantics, synthesized for macOS)

    struct TouchTuning {
        /// Movement (points) before a one-finger touch becomes a drag instead of a tap / long press.
        var slop: CGFloat = 8
        /// Press-and-hold duration that turns a tap into a right click (Windows: press and hold).
        var longPress: TimeInterval = 0.6
        /// Max duration of a two-finger tap (→ right click).
        var twoFingerTapMax: TimeInterval = 0.35
        /// Relative spread change that classifies a two-finger gesture as a pinch.
        var pinchRatio: CGFloat = 0.08
    }

    enum SingleTouchRelease: Equatable { case click, rightClick, none }

    /// What a one-finger touch that never exceeded the slop becomes when it is lifted.
    static func singleTouchRelease(heldFor: TimeInterval, travel: CGFloat, cancelled: Bool,
                                   tuning: TouchTuning = TouchTuning()) -> SingleTouchRelease {
        if cancelled || travel > tuning.slop { return .none }
        return heldFor >= tuning.longPress ? .rightClick : .click
    }

    enum TwoFingerMode: Equatable { case undecided, scroll, pinch }

    /// Classifies a two-finger gesture once it moved enough. Pinch wins when the spread changed by
    /// more than `pinchRatio` (and more than the slop in points) and more than the centroid moved.
    static func classifyTwoFinger(centroidTravel: CGFloat, startSpread: CGFloat, spread: CGFloat,
                                  tuning: TouchTuning = TouchTuning()) -> TwoFingerMode {
        let spreadDelta = abs(spread - startSpread)
        if startSpread > 0, spreadDelta / startSpread > tuning.pinchRatio, spreadDelta > tuning.slop,
           spreadDelta > centroidTravel {
            return .pinch
        }
        if centroidTravel > tuning.slop { return .scroll }
        return .undecided
    }

    /// Two-finger direct manipulation (Windows touch pan): content follows the fingers regardless of
    /// the "natural scrolling" preference. Finger moving down (dy > 0) → positive wheel1 (content
    /// moves down / reveals what is above); finger moving right → positive wheel2.
    static func touchScrollPixels(fingerDelta d: CGPoint) -> CGPoint { CGPoint(x: d.x, y: d.y) }

    /// Magnification for one pinch step (NSEvent.magnification semantics: 0 = none, >0 zoom in).
    static func magnification(previousSpread: CGFloat, spread: CGFloat) -> Double {
        guard previousSpread > 0, spread > 0 else { return 0 }
        return Double(spread / previousSpread - 1)
    }

    // MARK: - Wheel (kind 3)

    /// Protocol scroll notches (+y = up / away from user, +x = right, Android AXIS_V/HSCROLL) →
    /// CG line-scroll wheel values. Windows sends WHEEL +120·y (up) and HWHEEL +120·x (right).
    /// macOS applies "natural scrolling" to physical wheels in the HID layer, which synthesized
    /// events bypass, so emulate it: natural ⇒ invert. CG: wheel1 > 0 = content down (scroll up),
    /// wheel2 > 0 = content right (scroll left).
    static func wheelLines(notches: CGPoint, natural: Bool) -> CGPoint {
        let s: CGFloat = natural ? -1 : 1
        return CGPoint(x: -notches.x * s, y: notches.y * s)
    }

    /// Accumulates fractional deltas and emits whole units (Windows `_wheelAccX/Y` equivalent).
    struct Accumulator: Equatable {
        var remainder = CGPoint.zero
        mutating func add(_ d: CGPoint) -> (x: Int32, y: Int32) {
            let tx = remainder.x + (d.x.isFinite ? d.x : 0)
            let ty = remainder.y + (d.y.isFinite ? d.y : 0)
            let ix = tx.rounded(.towardZero), iy = ty.rounded(.towardZero)
            remainder = CGPoint(x: tx - ix, y: ty - iy)
            return (Int32(clamping: Int(max(min(ix, 1e6), -1e6))), Int32(clamping: Int(max(min(iy, 1e6), -1e6))))
        }
        mutating func reset() { remainder = .zero }
    }

    /// Reads the user's "natural scrolling" preference (NSGlobalDomain com.apple.swipescrolldirection,
    /// default on).
    static func systemNaturalScrolling(_ defaults: UserDefaults = .standard) -> Bool {
        (defaults.object(forKey: "com.apple.swipescrolldirection") as? Bool) ?? true
    }

    // MARK: - Click counting (CGEvent mouseEventClickState)

    struct ClickCounter: Equatable {
        var interval: TimeInterval
        var maxDistance: CGFloat
        private(set) var count: Int64 = 0
        private var lastTime: TimeInterval = -.infinity
        private var lastPoint = CGPoint(x: CGFloat.infinity, y: .infinity)

        init(interval: TimeInterval = 0.5, maxDistance: CGFloat = 8) {
            self.interval = interval
            self.maxDistance = maxDistance
        }

        /// Registers a button-down and returns its click state (1 = single, 2 = double, 3 = triple…
        /// capped at 3 like a real mouse sequence that keeps counting is rarely useful).
        mutating func press(at p: CGPoint, time: TimeInterval) -> Int64 {
            if time - lastTime <= interval, distance(p, lastPoint) <= maxDistance {
                count = min(count + 1, 3)
            } else {
                count = 1
            }
            lastTime = time
            lastPoint = p
            return count
        }

        mutating func reset() { count = 0; lastTime = -.infinity }
    }

    // MARK: - Mouse buttons (kind 2)

    /// Effective button mask for a mouse sample (Windows HandleMouse): up/cancel → 0;
    /// down without buttons → primary. bit0 left, bit1 right, bit2 middle.
    static func mouseButtons(action: PointerAction, buttons: UInt8) -> UInt8 {
        switch action {
        case .up, .cancel: return 0
        case .down: return (buttons & 0x07) == 0 ? 0x01 : buttons & 0x07
        case .hoverMove, .hoverExit: return 0
        case .move: return buttons & 0x07
        }
    }

    // MARK: - Pen

    /// Protocol tilt (degrees, ±90, +X right / +Y toward the user) → CG tablet tilt (-1..1).
    static func tabletTilt(_ degrees: Float) -> Double {
        guard degrees.isFinite else { return 0 }
        return Double(min(max(degrees, -90), 90) / 90)
    }

    /// Pen pressure while in contact (Windows clamps to 1..1024 of 1024, so contact never reads 0).
    static func penPressure(_ p: Float, contact: Bool) -> Double {
        guard contact else { return 0 }
        guard p.isFinite else { return 1.0 / 1024 }
        return Double(min(max(p, 1.0 / 1024), 1))
    }

    /// Touch pressure for synthesized mouse events (Windows: 0 → 512/1024).
    static func touchPressure(_ p: Float) -> Double {
        guard p.isFinite, p > 0 else { return 0.5 }
        return Double(min(p, 1))
    }
}

// MARK: - Keyboard

enum KeyMapping {
    /// macOS virtual key codes (Carbon kVK_*).
    enum VK {
        static let returnKey: CGKeyCode = 0x24, tab: CGKeyCode = 0x30, space: CGKeyCode = 0x31
        static let delete: CGKeyCode = 0x33, escape: CGKeyCode = 0x35, forwardDelete: CGKeyCode = 0x75
        static let command: CGKeyCode = 0x37, shift: CGKeyCode = 0x38, capsLock: CGKeyCode = 0x39
        static let option: CGKeyCode = 0x3A, control: CGKeyCode = 0x3B, rightCommand: CGKeyCode = 0x36
        static let rightShift: CGKeyCode = 0x3C, rightOption: CGKeyCode = 0x3D, rightControl: CGKeyCode = 0x3E
        static let function: CGKeyCode = 0x3F
        static let help: CGKeyCode = 0x72, home: CGKeyCode = 0x73, end: CGKeyCode = 0x77
        static let pageUp: CGKeyCode = 0x74, pageDown: CGKeyCode = 0x79
        static let left: CGKeyCode = 0x7B, right: CGKeyCode = 0x7C, down: CGKeyCode = 0x7D, up: CGKeyCode = 0x7E
    }

    /// Android KeyEvent.KEYCODE_* → macOS kVK_* (ANSI positions). Superset of Windows `MapAndroidKey`
    /// (adds numpad, caps lock, Fn, F13-F20 where macOS has them).
    static let androidToMac: [Int: CGKeyCode] = {
        var m: [Int: CGKeyCode] = [
            19: VK.up, 20: VK.down, 21: VK.left, 22: VK.right,        // DPAD arrows
            61: VK.tab, 62: VK.space, 66: VK.returnKey, 67: VK.delete, // TAB SPACE ENTER DEL(backspace)
            111: VK.escape, 112: VK.forwardDelete,                     // ESCAPE FORWARD_DEL
            122: VK.home, 123: VK.end, 92: VK.pageUp, 93: VK.pageDown, // MOVE_HOME MOVE_END PAGE_UP/DOWN
            124: VK.help,                                              // INSERT → Help (Mac "Insert" position)
            59: VK.shift, 60: VK.rightShift,                           // SHIFT_LEFT/RIGHT
            113: VK.control, 114: VK.rightControl,                     // CTRL_LEFT/RIGHT
            57: VK.option, 58: VK.rightOption,                         // ALT_LEFT/RIGHT
            117: VK.command, 118: VK.rightCommand,                     // META_LEFT/RIGHT (Windows: Win key)
            115: VK.capsLock, 119: VK.function,                        // CAPS_LOCK, FUNCTION
            55: 0x2B, 56: 0x2F, 69: 0x1B, 70: 0x18,                    // , . - =
            71: 0x21, 72: 0x1E, 73: 0x2A, 74: 0x29,                    // [ ] \ ;
            75: 0x27, 76: 0x2C, 68: 0x32,                              // ' / `
            // Numpad
            144: 0x52, 145: 0x53, 146: 0x54, 147: 0x55, 148: 0x56,     // NUMPAD_0..4
            149: 0x57, 150: 0x58, 151: 0x59, 152: 0x5B, 153: 0x5C,     // NUMPAD_5..9
            154: 0x4B, 155: 0x43, 156: 0x4E, 157: 0x45,                // NUMPAD / * - +
            158: 0x41, 160: 0x4C, 161: 0x51, 143: 0x47,                // NUMPAD . ENTER = , NUM_LOCK → Clear
        ]
        let letters: [CGKeyCode] = [                                   // KEYCODE_A (29) … KEYCODE_Z (54)
            0x00, 0x0B, 0x08, 0x02, 0x0E, 0x03, 0x05, 0x04, 0x22, 0x26, 0x28, 0x25, 0x2E, // a..m
            0x2D, 0x1F, 0x23, 0x0C, 0x0F, 0x01, 0x11, 0x20, 0x09, 0x0D, 0x07, 0x10, 0x06  // n..z
        ]
        for (i, vk) in letters.enumerated() { m[29 + i] = vk }
        let digits: [CGKeyCode] = [0x1D, 0x12, 0x13, 0x14, 0x15, 0x17, 0x16, 0x1A, 0x1C, 0x19] // KEYCODE_0 (7) … 9 (16)
        for (i, vk) in digits.enumerated() { m[7 + i] = vk }
        let fkeys: [CGKeyCode] = [0x7A, 0x78, 0x63, 0x76, 0x60, 0x61, 0x62, 0x64, 0x65, 0x6D, 0x67, 0x6F] // F1 (131) … F12 (142)
        for (i, vk) in fkeys.enumerated() { m[131 + i] = vk }
        return m
    }()

    static func macKey(forAndroid code: Int) -> CGKeyCode? { androidToMac[code] }

    /// Modifier flag contributed by a modifier virtual key (nil for ordinary keys). Caps Lock is a
    /// toggle and handled separately.
    static func modifierFlag(for vk: CGKeyCode) -> CGEventFlags? {
        switch vk {
        case VK.shift, VK.rightShift: return .maskShift
        case VK.control, VK.rightControl: return .maskControl
        case VK.option, VK.rightOption: return .maskAlternate
        case VK.command, VK.rightCommand: return .maskCommand
        case VK.function: return .maskSecondaryFn
        default: return nil
        }
    }

    /// Union of the flags of the held modifier keys.
    static func flags(forHeld held: Set<CGKeyCode>, capsLock: Bool) -> CGEventFlags {
        var f: CGEventFlags = []
        for vk in held { if let m = modifierFlag(for: vk) { f.insert(m) } }
        if capsLock { f.insert(.maskAlphaShift) }
        return f
    }

    /// Arrow / navigation keys carry the numeric-pad + Fn flags on real Mac keyboards.
    static func extraFlags(for vk: CGKeyCode) -> CGEventFlags {
        switch vk {
        case VK.left, VK.right, VK.up, VK.down: return [.maskNumericPad, .maskSecondaryFn]
        case VK.home, VK.end, VK.pageUp, VK.pageDown, VK.forwardDelete, VK.help: return .maskSecondaryFn
        default: return []
        }
    }

    enum TextPiece: Equatable {
        case unicode([UInt16])   // ≤ maxUnits UTF-16 units, never splits a surrogate pair
        case returnKey           // "\n", "\r" or "\r\n" (Windows sends VK_RETURN for '\n')
    }

    /// Splits text for CGEventKeyboardSetUnicodeString (≈20 UTF-16 units max per event).
    static func textPieces(_ text: String, maxUnits: Int = 16) -> [TextPiece] {
        var out: [TextPiece] = []
        var cur: [UInt16] = []
        func flush() { if !cur.isEmpty { out.append(.unicode(cur)); cur.removeAll() } }
        var prevCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\r" {
                if scalar == "\n", prevCR { prevCR = false; continue }   // \r\n → one Return
                prevCR = scalar == "\r"
                flush()
                out.append(.returnKey)
                continue
            }
            prevCR = false
            let units = Array(String(scalar).utf16)
            if cur.count + units.count > max(2, maxUnits) { flush() }
            cur.append(contentsOf: units)
        }
        flush()
        return out
    }
}
