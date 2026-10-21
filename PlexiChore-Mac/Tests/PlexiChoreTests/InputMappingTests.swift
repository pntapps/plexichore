import CoreGraphics
import XCTest
@testable import PlexiChore

/// Pure input mapping (Input/InputMapping.swift): normalized tablet coordinates → CG global points, touch
/// gesture classification, scroll/click helpers, pen values and the Android → macOS key mapping.
/// Vectors from the InputMapping author's scratch harness.
final class InputMappingTests: XCTestCase {
    typealias M = InputMapping
    let acc: CGFloat = 1e-9

    private func assertPoint(_ p: CGPoint?, _ x: CGFloat, _ y: CGFloat, _ msg: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard let p else { return XCTFail("nil point \(msg)", file: file, line: line) }
        XCTAssertEqual(p.x, x, accuracy: 1e-6, msg, file: file, line: line)
        XCTAssertEqual(p.y, y, accuracy: 1e-6, msg, file: file, line: line)
    }

    // MARK: Coordinates

    func testScreenPointOnSecondaryDisplay() {
        let b = CGRect(x: 1440, y: 0, width: 1280, height: 800)
        assertPoint(M.screenPoint(x: 0, y: 0, bounds: b), 1440, 0, "origin")
        assertPoint(M.screenPoint(x: 0.5, y: 0.5, bounds: b), 2080, 400, "center")
        assertPoint(M.screenPoint(x: 1, y: 1, bounds: b), 2719, 799, "max stays on the display")
        assertPoint(M.screenPoint(x: .nan, y: 2, bounds: b), 1440, 799, "NaN → 0, >1 clamped")
        XCTAssertNil(M.screenPoint(x: 0.5, y: 0.5, bounds: .zero))
    }

    func testScreenPointNegativeOriginPortrait() {
        let pb = CGRect(x: -800, y: -1280, width: 800, height: 1280)
        assertPoint(M.screenPoint(x: 0.25, y: 0.75, bounds: pb), -600, -320)
    }

    func testScreenPointNeverLeavesBounds() {
        let b = CGRect(x: -1920, y: 300, width: 1920, height: 1080)
        for x: Float in [-5, -0.01, 0, 0.3, 0.999, 1, 1.5, .infinity, -.infinity] {
            for y: Float in [-1, 0, 0.5, 1, 7] {
                guard let p = M.screenPoint(x: x, y: y, bounds: b) else { XCTFail("nil"); continue }
                XCTAssertTrue(b.contains(p), "\(x),\(y) → \(p)")
            }
        }
    }

    func testContentRectLetterbox() {
        let cr = M.contentRect(displaySize: CGSize(width: 1920, height: 1080), frameSize: CGSize(width: 2560, height: 1600))
        XCTAssertEqual(cr.minX, 0, accuracy: acc)
        XCTAssertEqual(cr.minY, 0.05, accuracy: acc)
        XCTAssertEqual(cr.width, 1, accuracy: acc)
        XCTAssertEqual(cr.height, 0.9, accuracy: acc)
        XCTAssertEqual(M.contentRect(displaySize: CGSize(width: 1280, height: 800), frameSize: CGSize(width: 2560, height: 1600)),
                       CGRect(x: 0, y: 0, width: 1, height: 1))
        // top edge of the letterboxed picture maps to the display's top row
        assertPoint(M.screenPoint(x: 0.5, y: 0.05, bounds: CGRect(x: 0, y: 0, width: 1920, height: 1080), content: cr), 960, 0)
    }

    func testContentRectWithoutFrameIsUnit() {
        XCTAssertEqual(M.contentRect(displaySize: CGSize(width: 1920, height: 1080), frameSize: nil), CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    func testClamp01() {
        XCTAssertEqual(M.clamp01(-1), 0)
        XCTAssertEqual(M.clamp01(2), 1)
        XCTAssertEqual(M.clamp01(.nan), 0)
        XCTAssertEqual(M.clamp01(0.25), 0.25, accuracy: acc)
    }

    func testGeometryHelpers() {
        XCTAssertEqual(M.distance(.zero, CGPoint(x: 3, y: 4)), 5, accuracy: acc)
        let pts = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0)]
        assertPoint(M.centroid(pts), 5, 0)
        XCTAssertGreaterThan(M.spread(pts), 0)
        XCTAssertEqual(M.spread([CGPoint(x: 1, y: 1)]), 0, accuracy: acc)
    }

    // MARK: Touch gestures

    func testSingleTouchRelease() {
        XCTAssertEqual(M.singleTouchRelease(heldFor: 0.1, travel: 2, cancelled: false), .click)
        XCTAssertEqual(M.singleTouchRelease(heldFor: 0.7, travel: 2, cancelled: false), .rightClick)
        XCTAssertEqual(M.singleTouchRelease(heldFor: 0.1, travel: 2, cancelled: true), .none)
        XCTAssertEqual(M.singleTouchRelease(heldFor: 0.7, travel: 2, cancelled: true), .none)
    }

    func testClassifyTwoFinger() {
        XCTAssertEqual(M.classifyTwoFinger(centroidTravel: 20, startSpread: 100, spread: 102), .scroll)
        XCTAssertEqual(M.classifyTwoFinger(centroidTravel: 3, startSpread: 100, spread: 130), .pinch)
        XCTAssertEqual(M.classifyTwoFinger(centroidTravel: 3, startSpread: 100, spread: 104), .undecided)
    }

    func testMagnification() {
        XCTAssertEqual(M.magnification(previousSpread: 100, spread: 110), 0.1, accuracy: 1e-9)
        XCTAssertLessThan(M.magnification(previousSpread: 110, spread: 100), 0)
    }

    // MARK: Scroll

    func testWheelLinesDirection() {
        XCTAssertEqual(M.wheelLines(notches: CGPoint(x: 1, y: 1), natural: false), CGPoint(x: -1, y: 1))
        XCTAssertEqual(M.wheelLines(notches: CGPoint(x: 1, y: 1), natural: true), CGPoint(x: 1, y: -1))
    }

    func testAccumulatorCarriesFractions() {
        var a = M.Accumulator()
        let a1 = a.add(CGPoint(x: 0.6, y: -0.6))
        let a2 = a.add(CGPoint(x: 0.6, y: -0.6))
        XCTAssertEqual([a1.x, a1.y], [0, 0])
        XCTAssertEqual([a2.x, a2.y], [1, -1])
        a.reset()
        let a3 = a.add(CGPoint(x: 0.6, y: 0))
        XCTAssertEqual(a3.x, 0)
    }

    // MARK: Clicks / buttons

    func testClickCounter() {
        var cc = M.ClickCounter(interval: 0.5, maxDistance: 8)
        let counts = [cc.press(at: .zero, time: 10), cc.press(at: CGPoint(x: 3, y: 3), time: 10.3),
                      cc.press(at: .zero, time: 10.5), cc.press(at: .zero, time: 10.7), cc.press(at: .zero, time: 12)]
        XCTAssertEqual(counts, [1, 2, 3, 3, 1])
        var far = M.ClickCounter()
        _ = far.press(at: .zero, time: 0)
        XCTAssertEqual(far.press(at: CGPoint(x: 20, y: 0), time: 0.1), 1)
        far.reset()
        XCTAssertEqual(far.press(at: .zero, time: 0.15), 1)
    }

    func testMouseButtons() {
        XCTAssertEqual(M.mouseButtons(action: .down, buttons: 0), 1)   // touch-as-mouse: down implies primary
        XCTAssertEqual(M.mouseButtons(action: .up, buttons: 3), 0)
        XCTAssertEqual(M.mouseButtons(action: .cancel, buttons: 1), 0)
        XCTAssertEqual(M.mouseButtons(action: .move, buttons: 2), 2)
        XCTAssertEqual(M.mouseButtons(action: .hoverMove, buttons: 1), 0)
        XCTAssertEqual(M.mouseButtons(action: .down, buttons: 0xFA), 0x02)   // only the 3 defined bits
    }

    // MARK: Pen

    func testTabletTiltAndPressure() {
        XCTAssertEqual(M.tabletTilt(45), 0.5, accuracy: 1e-9)
        XCTAssertEqual(M.tabletTilt(-200), -1, accuracy: 1e-9)
        XCTAssertEqual(M.tabletTilt(0), 0, accuracy: 1e-9)
        XCTAssertEqual(M.penPressure(0, contact: true), 1.0 / 1024, accuracy: 1e-12)   // contact never reads as 0
        XCTAssertEqual(M.penPressure(0.7, contact: false), 0)
        XCTAssertEqual(M.penPressure(0.7, contact: true), 0.7, accuracy: 1e-6)
        XCTAssertLessThanOrEqual(M.penPressure(5, contact: true), 1)
        let tp = M.touchPressure(0.5)
        XCTAssertTrue((0...1).contains(tp))
    }

    // MARK: Keys

    func testAndroidKeyCodes() {
        let vectors: [(Int, CGKeyCode?)] = [(29, 0x00), (54, 0x06), (7, 0x1D), (131, 0x7A), (142, 0x6F),
                                            (66, 0x24), (117, 0x37), (999, nil), (-1, nil)]
        for (android, mac) in vectors { XCTAssertEqual(KeyMapping.macKey(forAndroid: android), mac, "android \(android)") }
    }

    func testModifierFlags() {
        XCTAssertEqual(KeyMapping.flags(forHeld: [0x38, 0x37], capsLock: false), [.maskShift, .maskCommand])
        XCTAssertEqual(KeyMapping.flags(forHeld: [], capsLock: false), [])
        XCTAssertTrue(KeyMapping.flags(forHeld: [], capsLock: true).contains(.maskAlphaShift))
        XCTAssertEqual(KeyMapping.modifierFlag(for: 0x37), .maskCommand)
        XCTAssertNil(KeyMapping.modifierFlag(for: 0x00))   // 'a' is not a modifier
    }

    func testTextPieces() {
        XCTAssertEqual(KeyMapping.textPieces("ab\r\ncd\n"), [.unicode([97, 98]), .returnKey, .unicode([99, 100]), .returnKey])
        XCTAssertEqual(KeyMapping.textPieces(""), [])
        XCTAssertEqual(KeyMapping.textPieces("\r"), [.returnKey])
    }

    func testTextPiecesNeverSplitSurrogates() {
        let pcs = KeyMapping.textPieces(String(repeating: "😀", count: 9))   // 18 UTF-16 units
        let sizes = pcs.map { p -> Int in if case .unicode(let u) = p { return u.count } else { return -1 } }
        XCTAssertEqual(sizes, [16, 2])
        let units = pcs.flatMap { p -> [UInt16] in if case .unicode(let u) = p { return u } else { return [] } }
        XCTAssertEqual(String(decoding: units, as: UTF16.self), String(repeating: "😀", count: 9))
        // odd budget: a pair that does not fit moves to the next piece
        for case .unicode(let u) in KeyMapping.textPieces("a😀😀😀", maxUnits: 4) {
            XCTAssertLessThanOrEqual(u.count, 4)
            if let last = u.last { XCTAssertFalse(UTF16.isLeadSurrogate(last)) }
        }
    }
}
