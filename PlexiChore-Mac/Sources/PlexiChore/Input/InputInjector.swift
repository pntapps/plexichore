import AppKit
import CoreGraphics

/// Turns PlexiChore INPUT events into CGEvents on the target display, mirroring the Windows host
/// (`PlexiChore.Engine/Input/InputInjector.cs`). Windows injects real touch/pen contacts and lets the
/// OS recognize gestures; macOS has no public touch injection, so the same user-visible behaviour is
/// synthesized here:
///
/// | tablet                      | Windows (OS gesture)            | macOS (this class)                         |
/// |-----------------------------|---------------------------------|--------------------------------------------|
/// | touch tap                   | tap = left click                | left down+up at the contact point          |
/// | touch press & hold, lift    | right click                     | right down+up                              |
/// | touch drag (1 finger)       | drag / select                   | left drag (after an 8 pt slop)             |
/// | 2-finger pan                | pan-scroll, content follows     | continuous pixel scroll with phases        |
/// | 2-finger pinch              | pinch zoom                      | magnify gesture (private gesture event)    |
/// | 2-finger tap                | right click (app dependent)     | right click                                |
/// | 3+ fingers                  | system gestures                 | ignored until all fingers lift             |
/// | touchMode "mouse"           | SendInput left drag             | left down / drag / up immediately          |
/// | pen hover / contact         | pen in range / contact+pressure | tablet proximity + tablet-point mouse events with pressure & tilt |
/// | pen barrel (bit1)           | barrel button                   | right button while in contact              |
/// | pen eraser (bit2)           | inverted pen                    | proximity pointer type = eraser            |
/// | mouse buttons bit0/1/2      | left / right / middle           | left / right / center (other) button       |
/// | scroll (kind 3) notches     | WHEEL/HWHEEL ±120·n             | line scroll, follows "natural scrolling"   |
///
/// Coordinates: `CGDisplayBounds(displayID)` is read for every event, so it follows the virtual
/// display (extend/primary) or the captured display (mirror), its arrangement position, HiDPI scale and
/// rotation (portrait virtual displays are already portrait).
///
/// Requires Accessibility permission; events are dropped (not queued) while it is missing.
/// Not thread-safe: call from one queue (SessionContext serializes calls under its lock).
final class InputInjector {
    var displayID: CGDirectDisplayID
    var touchMode: String   // "touch" | "mouse" | "none"
    /// Encoded VIDEO frame size (CONFIG width/height). Only needed when the frame aspect can differ
    /// from the display aspect (ScreenCaptureKit then letterboxes the picture inside the frame).
    var frameSize: CGSize?
    /// Mouse wheel (kind 3) follows the Mac's "natural scrolling" preference like a physical wheel.
    var naturalScrolling = InputMapping.systemNaturalScrolling()
    /// Two-finger pinch → magnify gesture events (private event fields; set false to disable).
    var pinchToZoom = true
    var tuning = InputMapping.TouchTuning()

    private let source: CGEventSource?

    // Buttons / cursor (shared by touch, pen and mouse like the single Windows cursor).
    private var held = Set<UInt32>()                 // CGMouseButton raw values
    private var clickState: [UInt32: Int64] = [:]
    private var clickCounters: [UInt32: InputMapping.ClickCounter] = [:]
    private var cursor: CGPoint?
    private let doubleClickInterval: TimeInterval

    // Touch.
    private var touches: [UInt8: CGPoint] = [:]
    private var gesture: TouchGesture = .idle
    private var mouseTouchId: UInt8?
    private var scrollAcc = InputMapping.Accumulator()

    // Pen.
    private var penInProximity = false
    private var penEraser = false
    private var penInContact = false
    private var penButton: CGMouseButton = .left
    private var penLast: CGPoint?
    private static let penDeviceID: Int64 = 0x50C1

    // Mouse / wheel.
    private var mouseButtons: UInt8 = 0
    private var wheelAcc = InputMapping.Accumulator()

    // Accessibility (re-checked at most every 2 s).
    private var trusted = false
    private var trustCheckedAt: TimeInterval = -.infinity

    private struct TwoFinger {
        var startTime: TimeInterval
        var startCentroid: CGPoint
        var lastCentroid: CGPoint
        var startSpread: CGFloat
        var lastSpread: CGFloat
        var mode: InputMapping.TwoFingerMode = .undecided
        var travel: CGFloat = 0
        var ended = false
        var maxFingers = 2
    }

    private enum TouchGesture {
        case idle
        case pending(id: UInt8, start: CGPoint, time: TimeInterval, travel: CGFloat, pressure: Double)
        case dragging(id: UInt8)
        case two(TwoFinger)
        case suppressed
    }

    init(displayID: CGDirectDisplayID, touchMode: String) {
        self.displayID = displayID
        self.touchMode = touchMode
        let src = CGEventSource(stateID: .hidSystemState)
        // Default 0.25 s would block the user's real mouse after every injected event.
        src?.localEventsSuppressionInterval = 0
        self.source = src
        self.doubleClickInterval = NSEvent.doubleClickInterval
    }

    deinit { reset() }

    static var isTrusted: Bool { Permissions.accessibilityGranted }

    // MARK: Entry point

    func handle(_ pointers: [PointerState]) {
        guard !pointers.isEmpty else { return }
        let bounds = CGDisplayBounds(displayID)
        guard bounds.width > 0, bounds.height > 0 else { return }   // display gone
        let content = InputMapping.contentRect(displaySize: bounds.size, frameSize: frameSize)
        let map: (PointerState) -> CGPoint = { p in
            InputMapping.screenPoint(x: p.x, y: p.y, bounds: bounds, content: content) ?? CGPoint(x: bounds.midX, y: bounds.midY)
        }
        let now = ProcessInfo.processInfo.systemUptime

        var touchSamples: [PointerState] = []
        for p in pointers {
            switch p.kind {
            case .touch: touchSamples.append(p)
            case .pen: handlePen(p, at: map(p))
            case .mouse: handleMouse(p, at: map(p))
            case .scroll: handleWheel(p)
            }
        }
        guard !touchSamples.isEmpty else { return }
        switch touchMode {
        case "none": return
        case "mouse": handleTouchAsMouse(touchSamples, map: map)
        default: handleTouch(touchSamples, map: map, now: now)
        }
    }

    /// Releases everything held (session end / display change).
    func reset() {
        if case .two(let s) = gesture, !s.ended { endTwo(s) }
        for raw in held {
            if let b = CGMouseButton(rawValue: raw) { postButton(b, down: false, at: cursor ?? .zero, tablet: nil) }
        }
        held.removeAll()
        clickState.removeAll()
        if penInProximity { postProximity(enter: false, eraser: penEraser, at: penLast ?? cursor ?? .zero) }
        penInProximity = false
        penInContact = false
        touches.removeAll()
        gesture = .idle
        mouseTouchId = nil
        mouseButtons = 0
        scrollAcc.reset()
        wheelAcc.reset()
    }

    // MARK: Touch (touchMode "touch")

    private func handleTouch(_ samples: [PointerState], map: (PointerState) -> CGPoint, now: TimeInterval) {
        var cancelled = false
        var seen = Set<UInt8>()
        var lastPos: [UInt8: CGPoint] = [:]
        for t in samples where seen.insert(t.pointerId).inserted {
            switch t.action {
            case .down, .move:
                touches[t.pointerId] = map(t)
            case .up:
                lastPos[t.pointerId] = touches.removeValue(forKey: t.pointerId)
            case .cancel:
                lastPos[t.pointerId] = touches.removeValue(forKey: t.pointerId)
                cancelled = true
            case .hoverMove, .hoverExit:
                break   // touch hover not applicable (Windows ignores it too)
            }
        }
        let count = touches.count
        let pressure = samples.first.map { InputMapping.touchPressure($0.pressure) } ?? 0.5

        switch gesture {
        case .idle:
            beginGesture(count: count, now: now, pressure: pressure)

        case .pending(let id, let start, let time, let travel, let pr):
            if count == 0 {
                gesture = .idle
                switch InputMapping.singleTouchRelease(heldFor: now - time, travel: travel,
                                                       cancelled: cancelled, tuning: tuning) {
                case .click:
                    press(.left, at: start, pressure: pr, maxDistance: 8)
                    release(.left, at: start)
                case .rightClick:
                    press(.right, at: start, pressure: 1, maxDistance: 8)
                    release(.right, at: start)
                case .none:
                    break
                }
            } else if count == 1, let p = touches[id] {
                let tr = max(travel, InputMapping.distance(p, start))
                if tr > tuning.slop {
                    press(.left, at: start, pressure: pr, maxDistance: 8)
                    move(to: p, pressure: pressure)
                    gesture = .dragging(id: id)
                } else {
                    gesture = .pending(id: id, start: start, time: time, travel: tr, pressure: pr)
                }
            } else if count == 2 {
                beginTwo(startTime: time)
            } else {
                gesture = .suppressed
            }

        case .dragging(let id):
            if count == 1, let p = touches[id] {
                move(to: p, pressure: pressure)
            } else {
                release(.left, at: lastPos[id] ?? cursor ?? .zero)
                gesture = count == 0 ? .idle : .suppressed
            }

        case .two(var s):
            if count == 0 {
                if !s.ended { endTwo(s) }
                gesture = .idle
                if !cancelled, s.maxFingers == 2, s.mode == .undecided, s.travel <= tuning.slop,
                   now - s.startTime <= tuning.twoFingerTapMax {
                    press(.right, at: s.lastCentroid, pressure: 1, maxDistance: 8)
                    release(.right, at: s.lastCentroid)
                }
            } else if count == 2, !s.ended {
                updateTwo(&s)
                gesture = .two(s)
            } else {
                if !s.ended { endTwo(s); s.ended = true }
                if count >= 3 { s.maxFingers = max(s.maxFingers, count) }
                gesture = .two(s)
            }

        case .suppressed:
            if count == 0 { gesture = .idle }
        }
    }

    private func beginGesture(count: Int, now: TimeInterval, pressure: Double) {
        switch count {
        case 0: gesture = .idle
        case 1:
            let (id, p) = touches.first!
            move(to: p)   // hover feedback; the click itself happens on lift or after the slop
            gesture = .pending(id: id, start: p, time: now, travel: 0, pressure: pressure)
        case 2: beginTwo(startTime: now)
        default: gesture = .suppressed
        }
    }

    private func twoPoints() -> [CGPoint] {
        touches.sorted { $0.key < $1.key }.map(\.value)
    }

    private func beginTwo(startTime: TimeInterval) {
        let pts = twoPoints()
        let c = InputMapping.centroid(pts), sp = InputMapping.spread(pts)
        if held.contains(CGMouseButton.left.rawValue) { release(.left, at: cursor ?? c) }
        move(to: c)   // scroll / magnify target the view under the fingers
        scrollAcc.reset()
        gesture = .two(TwoFinger(startTime: startTime, startCentroid: c, lastCentroid: c,
                                 startSpread: sp, lastSpread: sp))
    }

    private func updateTwo(_ s: inout TwoFinger) {
        let pts = twoPoints()
        let c = InputMapping.centroid(pts), sp = InputMapping.spread(pts)
        let travelNow = InputMapping.distance(c, s.startCentroid)
        s.travel = max(s.travel, travelNow)
        if s.mode == .undecided {
            var mode = InputMapping.classifyTwoFinger(centroidTravel: travelNow, startSpread: s.startSpread,
                                                      spread: sp, tuning: tuning)
            if mode == .pinch && !pinchToZoom { mode = travelNow > tuning.slop ? .scroll : .undecided }
            switch mode {
            case .scroll:
                postScroll(dx: 0, dy: 0, phase: Self.phaseBegan, at: c)
                s.lastCentroid = s.startCentroid   // deliver the movement made during the slop
            case .pinch:
                postGesture(hidType: Self.hidGestureStarted, at: c)
                postMagnify(0, phase: Self.phaseBegan, at: c)
                s.lastSpread = s.startSpread
            case .undecided:
                break
            }
            s.mode = mode
        }
        switch s.mode {
        case .scroll:
            let d = CGPoint(x: c.x - s.lastCentroid.x, y: c.y - s.lastCentroid.y)
            let w = scrollAcc.add(InputMapping.touchScrollPixels(fingerDelta: d))
            if w.x != 0 || w.y != 0 { postScroll(dx: w.x, dy: w.y, phase: Self.phaseChanged, at: c) }
        case .pinch:
            let m = InputMapping.magnification(previousSpread: s.lastSpread, spread: sp)
            if abs(m) > 0.0005 { postMagnify(m, phase: Self.phaseChanged, at: c); s.lastSpread = sp }
        case .undecided:
            break
        }
        s.lastCentroid = c
    }

    private func endTwo(_ s: TwoFinger) {
        switch s.mode {
        case .scroll: postScroll(dx: 0, dy: 0, phase: Self.phaseEnded, at: s.lastCentroid)
        case .pinch:
            postMagnify(0, phase: Self.phaseEnded, at: s.lastCentroid)
            postGesture(hidType: Self.hidGestureEnded, at: s.lastCentroid)
        case .undecided: break
        }
    }

    // MARK: Touch as mouse (touchMode "mouse", Windows HandleTouchAsMouse)

    private func handleTouchAsMouse(_ samples: [PointerState], map: (PointerState) -> CGPoint) {
        let pick = samples.first { t in
            if let id = mouseTouchId { return t.pointerId == id }
            return t.action == .down || t.action == .move
        }
        guard let t = pick else { return }
        let p = map(t)
        switch t.action {
        case .down, .move:
            move(to: p, pressure: InputMapping.touchPressure(t.pressure))
            if mouseTouchId == nil {
                mouseTouchId = t.pointerId
                press(.left, at: p, pressure: InputMapping.touchPressure(t.pressure), maxDistance: 8)
            }
        case .up, .cancel:
            if mouseTouchId != nil {
                move(to: p)
                release(.left, at: p)
                mouseTouchId = nil
            }
        case .hoverMove, .hoverExit:
            break
        }
    }

    // MARK: Pen (Windows HandlePen state machine)

    private struct Tablet {
        var pressure: Double
        var tiltX: Double
        var tiltY: Double
    }

    private func tablet(_ p: PointerState, contact: Bool) -> Tablet {
        Tablet(pressure: InputMapping.penPressure(p.pressure, contact: contact),
               tiltX: InputMapping.tabletTilt(p.tiltX), tiltY: InputMapping.tabletTilt(p.tiltY))
    }

    private func ensurePenProximity(_ p: PointerState, at pt: CGPoint) {
        if penInProximity, penEraser == p.eraser { return }
        if penInProximity { postProximity(enter: false, eraser: penEraser, at: pt) }
        penEraser = p.eraser
        postProximity(enter: true, eraser: penEraser, at: pt)
        penInProximity = true
    }

    private func penDown(_ p: PointerState, at pt: CGPoint) {
        penButton = p.secondaryButton ? .right : .left
        press(penButton, at: pt, pressure: InputMapping.penPressure(p.pressure, contact: true),
              maxDistance: 8, tablet: tablet(p, contact: true))
        penInContact = true
    }

    private func penUp(_ p: PointerState, at pt: CGPoint) {
        release(penButton, at: pt, tablet: tablet(p, contact: false))
        penInContact = false
    }

    private func handlePen(_ p: PointerState, at pt: CGPoint) {
        switch p.action {
        case .down:
            ensurePenProximity(p, at: pt)
            if penInContact { move(to: pt, tablet: tablet(p, contact: true)) }
            else { move(to: pt, tablet: tablet(p, contact: false)); penDown(p, at: pt) }
        case .move:
            if penInContact {
                move(to: pt, tablet: tablet(p, contact: true))
            } else if p.primaryButton || p.pressure > 0 {
                ensurePenProximity(p, at: pt)
                move(to: pt, tablet: tablet(p, contact: false))
                penDown(p, at: pt)
            } else {
                ensurePenProximity(p, at: pt)
                move(to: pt, tablet: tablet(p, contact: false))
            }
        case .up:   // lifted → still hovering
            if penInContact { penUp(p, at: pt) }
        case .cancel:
            if penInContact { penUp(p, at: penLast ?? pt) }
            if penInProximity { postProximity(enter: false, eraser: penEraser, at: penLast ?? pt); penInProximity = false }
        case .hoverMove:
            if penInContact { penUp(p, at: pt) }
            ensurePenProximity(p, at: pt)
            move(to: pt, tablet: tablet(p, contact: false))
        case .hoverExit:
            if penInContact { penUp(p, at: pt) }
            if penInProximity { postProximity(enter: false, eraser: penEraser, at: pt); penInProximity = false }
        }
        penLast = pt
    }

    // MARK: Mouse (Windows HandleMouse)

    private func handleMouse(_ p: PointerState, at pt: CGPoint) {
        move(to: pt)
        let b = InputMapping.mouseButtons(action: p.action, buttons: p.buttons)
        let changed = b ^ mouseButtons
        let map: [(UInt8, CGMouseButton)] = [(0x01, .left), (0x02, .right), (0x04, .center)]
        for (bit, button) in map where changed & bit != 0 {
            if b & bit != 0 { press(button, at: pt, pressure: 1, maxDistance: 4) }
            else { release(button, at: pt) }
        }
        mouseButtons = b
    }

    // MARK: Wheel (kind 3, Windows HandleScroll)

    private func handleWheel(_ p: PointerState) {
        let lines = InputMapping.wheelLines(notches: CGPoint(x: CGFloat(p.x.isFinite ? p.x : 0),
                                                             y: CGFloat(p.y.isFinite ? p.y : 0)),
                                            natural: naturalScrolling)
        let w = wheelAcc.add(lines)
        guard w.x != 0 || w.y != 0 else { return }
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .line, wheelCount: 2,
                              wheel1: w.y, wheel2: w.x, wheel3: 0) else { return }
        send(e)
    }

    // MARK: Primitives

    private func move(to p: CGPoint, pressure: Double? = nil, tablet: Tablet? = nil) {
        if p == cursor && tablet == nil { return }
        let (type, button): (CGEventType, CGMouseButton) = {
            if held.contains(CGMouseButton.left.rawValue) { return (.leftMouseDragged, .left) }
            if held.contains(CGMouseButton.right.rawValue) { return (.rightMouseDragged, .right) }
            if held.contains(CGMouseButton.center.rawValue) { return (.otherMouseDragged, .center) }
            return (.mouseMoved, .left)
        }()
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button) else { return }
        if let c = cursor {
            e.setIntegerValueField(.mouseEventDeltaX, value: Int64((p.x - c.x).rounded()))
            e.setIntegerValueField(.mouseEventDeltaY, value: Int64((p.y - c.y).rounded()))
        }
        if type != .mouseMoved {
            e.setIntegerValueField(.mouseEventClickState, value: clickState[button.rawValue] ?? 1)
            if button == .center { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
        }
        apply(tablet: tablet, pressure: pressure ?? (type == .mouseMoved ? 0 : 1), to: e)
        cursor = p
        send(e)
    }

    private func press(_ b: CGMouseButton, at p: CGPoint, pressure: Double, maxDistance: CGFloat,
                       tablet: Tablet? = nil) {
        guard !held.contains(b.rawValue) else { return }
        var counter = clickCounters[b.rawValue] ?? InputMapping.ClickCounter(interval: doubleClickInterval)
        counter.maxDistance = maxDistance
        clickState[b.rawValue] = counter.press(at: p, time: ProcessInfo.processInfo.systemUptime)
        clickCounters[b.rawValue] = counter
        if p != cursor { move(to: p, tablet: tablet) }
        held.insert(b.rawValue)
        postButton(b, down: true, at: p, tablet: tablet, pressure: pressure)
    }

    private func release(_ b: CGMouseButton, at p: CGPoint, tablet: Tablet? = nil) {
        guard held.contains(b.rawValue) else { return }
        postButton(b, down: false, at: p, tablet: tablet)
        held.remove(b.rawValue)
    }

    private func postButton(_ b: CGMouseButton, down: Bool, at p: CGPoint, tablet: Tablet?, pressure: Double = 0) {
        let type: CGEventType
        switch b {
        case .left: type = down ? .leftMouseDown : .leftMouseUp
        case .right: type = down ? .rightMouseDown : .rightMouseUp
        default: type = down ? .otherMouseDown : .otherMouseUp
        }
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: b) else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clickState[b.rawValue] ?? 1)
        if b == .center { e.setIntegerValueField(.mouseEventButtonNumber, value: 2) }
        apply(tablet: tablet, pressure: down ? pressure : 0, to: e)
        cursor = p
        send(e)
    }

    private func apply(tablet: Tablet?, pressure: Double, to e: CGEvent) {
        if let t = tablet {
            e.setIntegerValueField(.mouseEventSubtype, value: 1)   // kCGEventMouseSubtypeTabletPoint
            e.setIntegerValueField(.tabletEventDeviceID, value: Self.penDeviceID)
            e.setDoubleValueField(.tabletEventPointPressure, value: t.pressure)
            e.setDoubleValueField(.tabletEventTiltX, value: t.tiltX)
            e.setDoubleValueField(.tabletEventTiltY, value: t.tiltY)
            e.setDoubleValueField(.mouseEventPressure, value: t.pressure)
        } else {
            e.setDoubleValueField(.mouseEventPressure, value: pressure)
        }
    }

    private func postProximity(enter: Bool, eraser: Bool, at p: CGPoint) {
        guard let e = CGEvent(source: source) else { return }
        e.type = .tabletProximity
        e.location = p
        e.setIntegerValueField(.mouseEventSubtype, value: 2)  // kCGEventMouseSubtypeTabletProximity
        e.setIntegerValueField(.tabletProximityEventDeviceID, value: Self.penDeviceID)
        e.setIntegerValueField(.tabletProximityEventPointerID, value: 1)
        e.setIntegerValueField(.tabletProximityEventSystemTabletID, value: 1)
        e.setIntegerValueField(.tabletProximityEventTabletID, value: 1)
        e.setIntegerValueField(.tabletProximityEventPointerType, value: eraser ? 3 : 1)   // NX_TABLET_POINTER_ERASER / PEN
        // abs X/Y, buttons, tilt X/Y, pressure (NX_TABLET_CAPABILITY_*).
        e.setIntegerValueField(.tabletProximityEventCapabilityMask, value: 0x0002 | 0x0004 | 0x0040 | 0x0080 | 0x0100 | 0x0400)
        e.setIntegerValueField(.tabletProximityEventEnterProximity, value: enter ? 1 : 0)
        send(e)
    }

    // Scroll / gesture phases (kCGScrollPhase*, CGSGesturePhase).
    private static let phaseBegan: Int64 = 1, phaseChanged: Int64 = 2, phaseEnded: Int64 = 4

    private func postScroll(dx: Int32, dy: Int32, phase: Int64, at p: CGPoint) {
        guard let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                              wheel1: dy, wheel2: dx, wheel3: 0) else { return }
        e.location = p
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
        send(e)
    }

    // Private gesture-event fields (same as Hammerspoon / Calf Trail TouchEvents). Undocumented: verify on device.
    private static let gestureEventType = CGEventType(rawValue: 29)     // NSEventTypeGesture
    private static let fieldGestureHIDType = CGEventField(rawValue: 110)
    private static let fieldGestureZoomValue = CGEventField(rawValue: 113)
    private static let fieldGesturePhase = CGEventField(rawValue: 132)
    private static let hidZoom: Int64 = 8, hidGestureStarted: Int64 = 61, hidGestureEnded: Int64 = 62

    private func gestureEvent(hidType: Int64, at p: CGPoint) -> CGEvent? {
        guard let type = Self.gestureEventType, let hid = Self.fieldGestureHIDType,
              let e = CGEvent(source: nil) else { return nil }
        e.type = type
        e.location = p
        e.setIntegerValueField(hid, value: hidType)
        return e
    }

    private func postGesture(hidType: Int64, at p: CGPoint) {
        if let e = gestureEvent(hidType: hidType, at: p) { send(e) }
    }

    private func postMagnify(_ m: Double, phase: Int64, at p: CGPoint) {
        guard let e = gestureEvent(hidType: Self.hidZoom, at: p),
              let zoom = Self.fieldGestureZoomValue, let ph = Self.fieldGesturePhase else { return }
        e.setIntegerValueField(ph, value: phase)
        e.setDoubleValueField(zoom, value: m)
        send(e)
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
