import AppKit
import CoreGraphics

/// Turns PlexiChore INPUT events into CGEvents on the target display.
///
/// - touch (1 finger)  → left mouse down / drag / up (with double-click detection)
/// - touch (2+ fingers) → pixel scroll from the centroid movement (two-finger scroll)
/// - pen               → left button, barrel button (bit1) → right button, pressure forwarded
/// - mouse             → button bitmask → left/right buttons
/// - scroll (kind 3)   → line scroll by "notches"
///
/// Requires Accessibility permission (AXIsProcessTrusted). Not thread-safe: call from one queue.
final class InputInjector {
    var displayID: CGDirectDisplayID
    var touchMode: String   // "touch" | "mouse" | "none"

    private let source = CGEventSource(stateID: .hidSystemState)

    // Primary-button state shared by touch / pen / mouse.
    private var leftDown = false
    private var rightDown = false
    private var lastPoint: CGPoint = .zero

    // Click counting for double / triple click.
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint: CGPoint = .zero
    private var clickCount: Int64 = 0

    // Touch tracking.
    private var primaryTouchId: UInt8?
    private var scrolling = false
    private var lastCentroid: CGPoint?
    private var suppressUntilAllUp = false
    private var scrollRemainder = CGPoint.zero
    private var gestureStart: TimeInterval = 0
    private var gestureTravel: CGFloat = 0
    private var gestureFingers = 0

    // Mouse kind state.
    private var mouseButtons: UInt8 = 0

    init(displayID: CGDirectDisplayID, touchMode: String) {
        self.displayID = displayID
        self.touchMode = touchMode
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    // MARK: Entry point

    func handle(_ pointers: [PointerState]) {
        guard !pointers.isEmpty else { return }
        let touches = pointers.filter { $0.kind == .touch }
        if !touches.isEmpty, touchMode != "none" {
            handleTouches(touches)
        }
        for p in pointers {
            switch p.kind {
            case .pen: handlePen(p)
            case .mouse: handleMouse(p)
            case .scroll: handleScrollNotches(p)
            case .touch: break
            }
        }
    }

    /// Releases any held buttons (session end / display change).
    func reset() {
        if leftDown { post(.leftMouseUp, at: lastPoint, button: .left) }
        if rightDown { post(.rightMouseUp, at: lastPoint, button: .right) }
        leftDown = false
        rightDown = false
        primaryTouchId = nil
        scrolling = false
        lastCentroid = nil
        suppressUntilAllUp = false
        mouseButtons = 0
    }

    // MARK: Coordinate mapping

    private func toScreen(_ x: Float, _ y: Float) -> CGPoint {
        let b = CGDisplayBounds(displayID)
        guard b.width > 0, b.height > 0 else { return lastPoint }
        let nx = CGFloat(min(max(x.isFinite ? x : 0, 0), 1))
        let ny = CGFloat(min(max(y.isFinite ? y : 0, 0), 1))
        // Keep strictly inside the display so the cursor never hops to a neighbour.
        let px = min(b.minX + nx * b.width, b.maxX - 1)
        let py = min(b.minY + ny * b.height, b.maxY - 1)
        return CGPoint(x: px, y: py)
    }

    // MARK: Touch

    private func handleTouches(_ touches: [PointerState]) {
        let active = touches.filter { $0.action == .down || $0.action == .move }
        let allEnded = active.isEmpty

        if active.count >= 2 {
            // Two-finger scroll. Cancel any single-finger drag first.
            if leftDown { post(.leftMouseUp, at: lastPoint, button: .left); leftDown = false }
            primaryTouchId = nil
            suppressUntilAllUp = true
            let pts = active.map { toScreen($0.x, $0.y) }
            let c = CGPoint(x: pts.map(\.x).reduce(0, +) / CGFloat(pts.count),
                            y: pts.map(\.y).reduce(0, +) / CGFloat(pts.count))
            if scrolling, let last = lastCentroid {
                scrollPixels(dx: c.x - last.x, dy: c.y - last.y)
                gestureTravel += hypot(c.x - last.x, c.y - last.y)
            } else if !scrolling {
                gestureStart = ProcessInfo.processInfo.systemUptime
                gestureTravel = 0
            }
            gestureFingers = max(gestureFingers, active.count)
            scrolling = true
            lastCentroid = c
            return
        }

        if allEnded {
            // Quick two-finger tap without movement → right click.
            if suppressUntilAllUp, gestureFingers == 2, gestureTravel < 10,
               ProcessInfo.processInfo.systemUptime - gestureStart < 0.35 {
                let c = lastCentroid ?? lastPoint
                post(.rightMouseDown, at: c, button: .right)
                post(.rightMouseUp, at: c, button: .right)
            }
            gestureFingers = 0
            if leftDown, let pid = primaryTouchId, let t = touches.first(where: { $0.pointerId == pid }) {
                let p = toScreen(t.x, t.y)
                post(.leftMouseUp, at: p, button: .left)
                lastPoint = p
            } else if leftDown {
                post(.leftMouseUp, at: lastPoint, button: .left)
            }
            leftDown = false
            primaryTouchId = nil
            scrolling = false
            lastCentroid = nil
            suppressUntilAllUp = false
            return
        }

        // Exactly one active finger.
        if scrolling {
            // Second finger lifted: wait for all fingers up before clicking again.
            scrolling = false
            lastCentroid = nil
        }
        if suppressUntilAllUp { return }

        guard let t = active.first else { return }
        let p = toScreen(t.x, t.y)
        if primaryTouchId == nil || !leftDown {
            if t.action == .down || primaryTouchId == nil {
                primaryTouchId = t.pointerId
                post(.mouseMoved, at: p, button: .left)
                mouseDownLeft(at: p, pressure: Double(t.pressure))
                return
            }
        }
        if t.pointerId == primaryTouchId, leftDown {
            if p != lastPoint {
                post(.leftMouseDragged, at: p, button: .left, pressure: Double(t.pressure))
                lastPoint = p
            }
        }
    }

    // MARK: Pen

    private func handlePen(_ p: PointerState) {
        let pt = toScreen(p.x, p.y)
        let pressure = Double(max(0, min(1, p.pressure)))
        switch p.action {
        case .hoverMove:
            if !leftDown && !rightDown {
                post(.mouseMoved, at: pt, button: .left)
                lastPoint = pt
            }
        case .hoverExit:
            break
        case .down:
            post(.mouseMoved, at: pt, button: .left)
            if p.secondaryButton {
                post(.rightMouseDown, at: pt, button: .right)
                rightDown = true
                lastPoint = pt
            } else {
                mouseDownLeft(at: pt, pressure: pressure)
            }
        case .move:
            if rightDown {
                post(.rightMouseDragged, at: pt, button: .right)
            } else if leftDown {
                post(.leftMouseDragged, at: pt, button: .left, pressure: pressure)
            } else {
                post(.mouseMoved, at: pt, button: .left)
            }
            lastPoint = pt
        case .up, .cancel:
            if rightDown { post(.rightMouseUp, at: pt, button: .right); rightDown = false }
            if leftDown { post(.leftMouseUp, at: pt, button: .left); leftDown = false }
            lastPoint = pt
        }
    }

    // MARK: Mouse

    private func handleMouse(_ p: PointerState) {
        let pt = toScreen(p.x, p.y)
        let newButtons: UInt8 = (p.action == .up || p.action == .cancel) ? 0 : p.buttons
        let wasLeft = mouseButtons & 0x01 != 0, isLeft = newButtons & 0x01 != 0
        let wasRight = mouseButtons & 0x02 != 0, isRight = newButtons & 0x02 != 0

        if pt != lastPoint {
            if leftDown { post(.leftMouseDragged, at: pt, button: .left) }
            else if rightDown { post(.rightMouseDragged, at: pt, button: .right) }
            else { post(.mouseMoved, at: pt, button: .left) }
            lastPoint = pt
        }
        if !wasLeft && isLeft { mouseDownLeft(at: pt, pressure: 1) }
        if wasLeft && !isLeft, leftDown { post(.leftMouseUp, at: pt, button: .left); leftDown = false }
        if !wasRight && isRight { post(.rightMouseDown, at: pt, button: .right); rightDown = true }
        if wasRight && !isRight, rightDown { post(.rightMouseUp, at: pt, button: .right); rightDown = false }
        mouseButtons = newButtons
    }

    // MARK: Scroll

    private func handleScrollNotches(_ p: PointerState) {
        // x, y = notches; +y = up. CG line scroll: positive wheel1 = up, positive wheel2 = left.
        let total = CGPoint(x: scrollRemainder.x + CGFloat(p.x), y: scrollRemainder.y + CGFloat(p.y))
        let lines = CGPoint(x: total.x.rounded(.towardZero), y: total.y.rounded(.towardZero))
        scrollRemainder = CGPoint(x: total.x - lines.x, y: total.y - lines.y)
        guard lines.x != 0 || lines.y != 0 else { return }
        if let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                           wheel1: Int32(lines.y), wheel2: Int32(-lines.x), wheel3: 0) {
            e.post(tap: .cghidEventTap)
        }
    }

    private func scrollPixels(dx: CGFloat, dy: CGFloat) {
        // Finger moving down (dy > 0) reveals content above → positive wheel1 ("natural" scrolling).
        let wy = Int32(dy.rounded()), wx = Int32(dx.rounded())
        guard wx != 0 || wy != 0 else { return }
        if let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                           wheel1: wy, wheel2: wx, wheel3: 0) {
            e.post(tap: .cghidEventTap)
        }
    }

    // MARK: Primitives

    private func mouseDownLeft(at p: CGPoint, pressure: Double) {
        let now = ProcessInfo.processInfo.systemUptime
        let dist = hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y)
        if now - lastClickTime <= NSEvent.doubleClickInterval && dist < 8 {
            clickCount = min(clickCount + 1, 3)
        } else {
            clickCount = 1
        }
        lastClickTime = now
        lastClickPoint = p
        post(.leftMouseDown, at: p, button: .left, pressure: pressure)
        leftDown = true
        lastPoint = p
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, pressure: Double? = nil) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        switch type {
        case .leftMouseDown, .leftMouseUp, .leftMouseDragged:
            e.setIntegerValueField(.mouseEventClickState, value: max(1, clickCount))
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            e.setIntegerValueField(.mouseEventClickState, value: 1)
        default:
            break
        }
        if let pressure {
            e.setDoubleValueField(.mouseEventPressure, value: pressure)
        }
        e.post(tap: .cghidEventTap)
    }
}
