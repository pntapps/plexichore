import CoreGraphics
import XCTest
@testable import PlexiChore

/// Pure layout math of DisplayArrangement (no CoreGraphics configuration is applied by these tests).
/// Coordinates: global display space in points, y grows downward, main display at (0,0).
final class DisplayArrangementTests: XCTestCase {
    typealias A = DisplayArrangement

    let main = CGRect(x: 0, y: 0, width: 1512, height: 982)     // MacBook Pro 14" default
    let tablet = CGSize(width: 1280, height: 800)                // Tab S8 @200%

    // MARK: besideOrigin

    func testFourSidesCentered() {
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: [], position: .right), CGPoint(x: 1512, y: 91))
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: [], position: .left), CGPoint(x: -1280, y: 91))
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: [], position: .top), CGPoint(x: 116, y: -800))
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: [], position: .bottom), CGPoint(x: 116, y: 982))
    }

    func testResultTouchesMainAndDoesNotOverlap() {
        for pos in [DisplayPlacement.right, .left, .top, .bottom] {
            for size in [tablet, CGSize(width: 800, height: 1280), CGSize(width: 2560, height: 1600), CGSize(width: 1707, height: 1067)] {
                let o = A.besideOrigin(main: main, size: size, others: [], position: pos)
                let r = CGRect(origin: o, size: size)
                XCTAssertFalse(r.intersects(main), "\(pos) \(size)")
                // shares an edge segment of positive length
                let touch = r.insetBy(dx: -0.5, dy: -0.5).intersection(main)
                XCTAssertFalse(touch.isNull, "\(pos) \(size)")
                XCTAssertGreaterThan(max(touch.width, touch.height), 1, "\(pos) \(size)")
                XCTAssertEqual(o.x, o.x.rounded()); XCTAssertEqual(o.y, o.y.rounded())
            }
        }
    }

    func testLargerTabletAlignsToEdge() {
        let big = CGSize(width: 2560, height: 1600)
        XCTAssertEqual(A.besideOrigin(main: main, size: big, others: [], position: .right), CGPoint(x: 1512, y: 0))
        XCTAssertEqual(A.besideOrigin(main: main, size: big, others: [], position: .left), CGPoint(x: -2560, y: 0))
        XCTAssertEqual(A.besideOrigin(main: main, size: big, others: [], position: .top), CGPoint(x: 0, y: -1600))
        XCTAssertEqual(A.besideOrigin(main: main, size: big, others: [], position: .bottom), CGPoint(x: 0, y: 982))
        // equal height also aligns (h >= main.height)
        let same = CGSize(width: 800, height: 982)
        XCTAssertEqual(A.besideOrigin(main: main, size: same, others: [], position: .right).y, 0)
    }

    func testOddDifferencesRoundDown() {
        let m = CGRect(x: 0, y: 0, width: 1001, height: 1001)
        XCTAssertEqual(A.besideOrigin(main: m, size: CGSize(width: 100, height: 100), others: [], position: .right), CGPoint(x: 1001, y: 450))
        // fractional sizes are rounded first
        XCTAssertEqual(A.besideOrigin(main: m, size: CGSize(width: 99.6, height: 99.6), others: [], position: .bottom), CGPoint(x: 450, y: 1001))
    }

    func testMainNotAtOrigin() {
        let m = CGRect(x: -1920, y: -200, width: 1920, height: 1080)
        XCTAssertEqual(A.besideOrigin(main: m, size: tablet, others: [], position: .right), CGPoint(x: 0, y: -60))
        XCTAssertEqual(A.besideOrigin(main: m, size: tablet, others: [], position: .top), CGPoint(x: -1600, y: -1000))
    }

    func testPushedPastThirdDisplay() {
        let external = CGRect(x: 1512, y: 0, width: 1920, height: 1080)     // already right of main
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: [external], position: .right), CGPoint(x: 3432, y: 91))
        let chain = [external, CGRect(x: 3432, y: 50, width: 1000, height: 1000)]
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: chain, position: .right), CGPoint(x: 4432, y: 91))
        let above = CGRect(x: 0, y: -1080, width: 1920, height: 1080)
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: [above], position: .top), CGPoint(x: 116, y: -1880))
        let left = CGRect(x: -1000, y: 500, width: 1000, height: 1000)
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: [left], position: .left), CGPoint(x: -2280, y: 91))
        let below = CGRect(x: 500, y: 982, width: 300, height: 300)
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: [below], position: .bottom), CGPoint(x: 116, y: 1282))
    }

    func testNonOverlappingThirdDisplayIsIgnored() {
        let far = CGRect(x: 1512, y: 2000, width: 1000, height: 1000)
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: [far], position: .right), CGPoint(x: 1512, y: 91))
        // touching edge only (no area) is not an overlap
        let touching = CGRect(x: 1512, y: 891, width: 500, height: 500)
        XCTAssertEqual(A.besideOrigin(main: main, size: tablet, others: [touching], position: .right), CGPoint(x: 1512, y: 91))
    }

    // MARK: Restore planning

    func place(_ uuid: String, _ id: UInt32, main: Bool = false, virtual: Bool = false,
               _ x: Int, _ y: Int, _ w: Int = 1512, _ h: Int = 982) -> A.Placement {
        .init(uuid: uuid, displayID: id, isMain: main, isVirtual: virtual, x: x, y: y, width: w, height: h)
    }

    func record(_ original: [A.Placement], virtualUUID: String = "V") -> A.RestoreRecord {
        .init(version: A.RestoreRecord.currentVersion, createdUtc: Date(timeIntervalSince1970: 1_700_000_000),
              virtualUUID: virtualUUID, original: original)
    }

    func testOriginalMainSkipsVirtual() {
        let r = record([place("V", 9, main: true, virtual: true, 0, 0), place("B", 1, main: true, 1280, 0)])
        XCTAssertEqual(r.originalMain?.uuid, "B")
        XCTAssertNil(record([place("V", 9, main: true, virtual: true, 0, 0)]).originalMain)
        XCTAssertNil(record([]).originalMain)
    }

    func testPlanRestoreUndoesPrimaryShift() {
        // original: built-in B main at (0,0), tablet V right of it
        let original = [place("B", 1, main: true, 0, 0), place("V", 9, virtual: true, 1512, 91, 1280, 800)]
        // now: V is main at (0,0), everything shifted by (-1512, -91)
        let current = [place("B", 1, -1512, -91), place("V", 9, main: true, virtual: true, 0, 0, 1280, 800)]
        let plan = try! XCTUnwrap(A.planRestore(record(original), current: current))
        XCTAssertEqual(plan.count, 2)
        let b = plan.first { $0.uuid == "B" }!, v = plan.first { $0.uuid == "V" }!
        XCTAssertEqual([b.x, b.y], [0, 0]); XCTAssertTrue(b.isMain)
        XCTAssertEqual([v.x, v.y], [1512, 91]); XCTAssertFalse(v.isMain)
        XCTAssertEqual(v.displayID, 9)   // current ids are kept (ids change across reboots, UUIDs don't)
    }

    func testPlanRestoreNormalisesOriginalMainToOrigin() {
        // a record whose main was not at (0,0) (shouldn't happen, but be safe)
        let original = [place("B", 1, main: true, 100, 50), place("E", 2, 1612, 50, 1920, 1080)]
        let plan = try! XCTUnwrap(A.planRestore(record(original), current: [place("E", 2, 0, 0, 1920, 1080), place("B", 1, 5, 5)]))
        XCTAssertEqual(plan.first { $0.uuid == "B" }.map { [$0.x, $0.y] }, [0, 0])
        XCTAssertEqual(plan.first { $0.uuid == "E" }.map { [$0.x, $0.y] }, [1512, 0])
    }

    func testPlanRestoreParksUnknownDisplaysRight() {
        let original = [place("B", 1, main: true, 0, 0), place("E", 2, -1920, 0, 1920, 1080)]
        let current = [place("B", 1, 0, 0), place("E", 2, 1512, 0, 1920, 1080),
                       place("N1", 3, 4000, 0, 1000, 700), place("N2", 4, 0, 2000, 800, 600)]
        let plan = try! XCTUnwrap(A.planRestore(record(original), current: current))
        XCTAssertEqual(plan.count, 4)
        let n1 = plan.first { $0.uuid == "N1" }!, n2 = plan.first { $0.uuid == "N2" }!
        // union of restored = x -1920...1512, y 0...1080 → parked from x 1512 at y 0, side by side
        XCTAssertEqual([n1.x, n1.y], [1512, 0])
        XCTAssertEqual([n2.x, n2.y], [2512, 0])
        XCTAssertFalse(n1.isMain || n2.isMain)
        XCTAssertEqual(plan.filter(\.isMain).map(\.uuid), ["B"])
    }

    func testPlanRestoreSkipsGoneDisplaysAndFailsWithoutMain() {
        let original = [place("B", 1, main: true, 0, 0), place("V", 9, virtual: true, 1512, 0, 1280, 800)]
        // virtual display already gone: only B planned
        let plan = try! XCTUnwrap(A.planRestore(record(original), current: [place("B", 1, -1512, 0)]))
        XCTAssertEqual(plan.map(\.uuid), ["B"])
        XCTAssertEqual([plan[0].x, plan[0].y], [0, 0])
        // original main unplugged → nil (macOS keeps its own choice)
        XCTAssertNil(A.planRestore(record(original), current: [place("V", 9, main: true, virtual: true, 0, 0)]))
        XCTAssertNil(A.planRestore(record([]), current: [place("B", 1, 0, 0)]))
    }

    func testRestoreRecordCodableIsStable() throws {
        let r = record([place("B", 1, main: true, 0, 0), place("V", 9, virtual: true, 1512, 91, 1280, 800)])
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(r)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains(#""createdUtc":"2023-11-14T22:13:20Z""#), json)
        XCTAssertTrue(json.contains(#""virtualUUID":"V""#))
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(A.RestoreRecord.self, from: data)
        XCTAssertEqual(back.original, r.original)
        XCTAssertEqual(back.version, 1)
        XCTAssertEqual(back.originalMain?.uuid, "B")
        let p = try XCTUnwrap((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["original"] as? [[String: Any]]).first!
        XCTAssertEqual(Set(p.keys), ["uuid", "displayID", "isMain", "isVirtual", "x", "y", "width", "height"])
    }

    func testRestoreFileLocation() {
        let url = A.restoreFileURL
        XCTAssertEqual(url.lastPathComponent, "primary-restore.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "PlexiChore")
        XCTAssertTrue(url.path.contains("Application Support"))
    }

    func testDisplayPlacementRawValuesMatchProtocolPosition() {
        for s in ["right", "left", "top", "bottom"] { XCTAssertEqual(DisplayPlacement(rawValue: s)?.rawValue, s) }
        XCTAssertNil(DisplayPlacement(rawValue: "Right"))
    }
}
