import XCTest
@testable import PlexiChore

/// Wire framing (PROTOCOL.md "Framing"): `u8 type | u32 length (big-endian) | payload`, VIDEO payload layout,
/// big-endian helpers and the 24-byte INPUT pointer records. Byte vectors are written out by hand so a
/// change in endianness or layout fails loudly.
final class FramingTests: XCTestCase {

    // MARK: Constants / type table

    func testConstantsMatchProtocol() {
        XCTAssertEqual(PlexiProtocol.version, 1)
        XCTAssertEqual(PlexiProtocol.tcpPort, 47800)
        XCTAssertEqual(PlexiProtocol.udpPort, 47801)
        XCTAssertEqual(PlexiProtocol.maxPayload, 16 * 1024 * 1024)
        XCTAssertEqual(PlexiProtocol.headerSize, 5)
        XCTAssertEqual(PlexiProtocol.discoveryQuery, "PLEXI?")
    }

    func testMessageTypeTableMatchesProtocolAndAndroid() {
        // PROTOCOL.md table == Android Protocol.kt constants
        let table: [(MessageType, UInt8)] = [
            (.hello, 0x01), (.config, 0x02), (.video, 0x03), (.input, 0x04), (.key, 0x05), (.ping, 0x06),
            (.pong, 0x07), (.requestKeyframe, 0x08), (.settings, 0x09), (.bye, 0x0A), (.stats, 0x0B), (.pairing, 0x0C),
        ]
        for (t, raw) in table {
            XCTAssertEqual(t.rawValue, raw, "\(t)")
            XCTAssertEqual(MessageType(rawValue: raw), t)
        }
        XCTAssertNil(MessageType(rawValue: 0x00))
        XCTAssertNil(MessageType(rawValue: 0x0D))
        XCTAssertNil(MessageType(rawValue: 0xFF))
    }

    func testVideoFlags() {
        XCTAssertEqual(VideoFlags.keyframe.rawValue, 0x01)
        XCTAssertEqual(VideoFlags.codecConfig.rawValue, 0x02)
        XCTAssertEqual(VideoFlags([.keyframe, .codecConfig]).rawValue, 0x03)
        XCTAssertTrue(VideoFlags(rawValue: 0x02).contains(.codecConfig))
        XCTAssertFalse(VideoFlags(rawValue: 0x02).contains(.keyframe))
    }

    // MARK: Encoding

    func testEmptyFrame() {
        XCTAssertEqual(Frame.make(.requestKeyframe), Data([0x08, 0, 0, 0, 0]))
        XCTAssertEqual(Frame.make(.bye, Data()), Data([0x0A, 0, 0, 0, 0]))
    }

    func testHeaderIsBigEndian() {
        let payload = Data(repeating: 0xAB, count: 0x0001_0203)   // 66051 bytes → 00 01 02 03
        let f = Frame.make(.video, payload)
        XCTAssertEqual(f.count, 5 + payload.count)
        XCTAssertEqual(Array(f.prefix(5)), [0x03, 0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(f.u32BE(at: 1), 0x0001_0203)
        XCTAssertEqual(f.suffix(from: 5), payload)
    }

    func testTextAndJSONFrames() throws {
        let bye = Frame.text(.bye, "Host stopped é")
        XCTAssertEqual(bye.u8(at: 0), 0x0A)
        let body = Data("Host stopped é".utf8)
        XCTAssertEqual(Int(bye.u32BE(at: 1)), body.count)   // byte length, not character count
        XCTAssertEqual(bye.dropFirst(5), body)

        let pairing = Frame.json(.pairing, PairingMessage(status: "waiting", code: "4821"))
        XCTAssertEqual(pairing.u8(at: 0), 0x0C)
        let len = Int(pairing.u32BE(at: 1))
        XCTAssertEqual(len, pairing.count - 5)
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: pairing.dropFirst(5)) as? [String: String])
        XCTAssertEqual(obj, ["status": "waiting", "code": "4821"])
    }

    func testPingPayloadRoundTrip() {
        var p = Data()
        p.appendBE(UInt64(0x0102_0304_0506_0708))
        XCTAssertEqual(Array(p), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(p.u64BE(at: 0), 0x0102_0304_0506_0708)
        let f = Frame.make(.ping, p)
        XCTAssertEqual(Array(f), [0x06, 0, 0, 0, 8, 1, 2, 3, 4, 5, 6, 7, 8])
    }

    func testVideoPayloadLayout() {
        let nal = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 0, 1, 0x68, 0xCE])
        let f = Frame.video(ptsMicros: 0x1122_3344_5566_7788, flags: .codecConfig, data: nal)
        XCTAssertEqual(f.u8(at: 0), MessageType.video.rawValue)
        XCTAssertEqual(Int(f.u32BE(at: 1)), 8 + 1 + nal.count)
        XCTAssertEqual(f.u64BE(at: 5), 0x1122_3344_5566_7788)
        XCTAssertEqual(f.u8(at: 13), 0x02)
        XCTAssertEqual(f.suffix(from: 14), nal)

        let key = Frame.video(ptsMicros: UInt64.max, flags: .keyframe, data: Data())
        XCTAssertEqual(Array(key), [0x03, 0, 0, 0, 9, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x01])
    }

    // MARK: Big-endian readers (slices must read relative to startIndex)

    func testReadersOnSlices() {
        var d = Data([0xEE, 0xEE, 0xEE])
        d.appendBE(UInt32(0xDEAD_BEEF))
        d.appendBE(UInt64(42))
        d.append(contentsOf: [0x3F, 0x80, 0x00, 0x00])   // 1.0f
        let slice = d.dropFirst(3)
        XCTAssertEqual(slice.startIndex, 3)
        XCTAssertEqual(slice.u32BE(at: 0), 0xDEAD_BEEF)
        XCTAssertEqual(slice.u8(at: 0), 0xDE)
        XCTAssertEqual(slice.u64BE(at: 4), 42)
        XCTAssertEqual(slice.f32BE(at: 12), 1.0)
        // a frame header parsed from a slice of a bigger receive buffer
        let two = Frame.make(.ping, Data(count: 8)) + Frame.make(.settings, Data("{}".utf8))
        let second = two.dropFirst(13)
        XCTAssertEqual(second.u8(at: 0), 0x09)
        XCTAssertEqual(second.u32BE(at: 1), 2)
    }

    func testF32SpecialValues() {
        func f(_ bits: UInt32) -> Float { var d = Data(); d.appendBE(bits); return d.f32BE(at: 0) }
        XCTAssertEqual(f(0x0000_0000), 0)
        XCTAssertEqual(f(0xBF80_0000), -1)
        XCTAssertEqual(f(0x3F00_0000), 0.5)
        XCTAssertTrue(f(0x7FC0_0000).isNaN)
        XCTAssertEqual(f(0x7F80_0000), .infinity)
    }

    // MARK: INPUT

    /// Encodes one pointer exactly like Android InputEncoder / faketablet `POINTER = ">BBBBfffff"`.
    static func pointer(kind: UInt8, action: UInt8, id: UInt8 = 0, buttons: UInt8 = 0,
                        x: Float, y: Float, pressure: Float = 0, tiltX: Float = 0, tiltY: Float = 0) -> Data {
        var d = Data([kind, action, id, buttons])
        for v in [x, y, pressure, tiltX, tiltY] { d.appendBE(v.bitPattern) }
        return d
    }

    static func input(_ pointers: [Data]) -> Data {
        var d = Data([UInt8(pointers.count)])
        pointers.forEach { d.append($0) }
        return d
    }

    func testPointerSize() {
        XCTAssertEqual(InputParser.pointerSize, 24)
        XCTAssertEqual(Self.pointer(kind: 0, action: 0, x: 0, y: 0).count, 24)
    }

    func testParsesPenPointer() throws {
        let raw = Self.input([Self.pointer(kind: 1, action: 1, id: 7, buttons: 0b110, x: 0.25, y: 0.75,
                                           pressure: 0.5, tiltX: -12.5, tiltY: 30)])
        XCTAssertEqual(raw.count, 25)
        let p = try XCTUnwrap(InputParser.parse(raw).first)
        XCTAssertEqual(p.kind, .pen)
        XCTAssertEqual(p.action, .move)
        XCTAssertEqual(p.pointerId, 7)
        XCTAssertEqual(p.x, 0.25); XCTAssertEqual(p.y, 0.75)
        XCTAssertEqual(p.pressure, 0.5)
        XCTAssertEqual(p.tiltX, -12.5); XCTAssertEqual(p.tiltY, 30)
        XCTAssertFalse(p.primaryButton); XCTAssertTrue(p.secondaryButton); XCTAssertTrue(p.eraser)
    }

    func testHandWrittenBytes() throws {
        // count=1, mouse(2) down(0) id 0 buttons 1, x=0.5 (3F000000) y=1.0 (3F800000), rest 0
        var raw = Data([1, 2, 0, 0, 1, 0x3F, 0, 0, 0, 0x3F, 0x80, 0, 0])
        raw.append(Data(count: 12))
        let p = try XCTUnwrap(InputParser.parse(raw).first)
        XCTAssertEqual(p.kind, .mouse); XCTAssertEqual(p.action, .down)
        XCTAssertTrue(p.primaryButton)
        XCTAssertEqual(p.x, 0.5); XCTAssertEqual(p.y, 1.0)
    }

    func testScrollDeltaSign() throws {
        let p = try XCTUnwrap(InputParser.parse(Self.input([Self.pointer(kind: 3, action: 1, x: 0, y: -1)])).first)
        XCTAssertEqual(p.kind, .scroll)
        XCTAssertEqual(p.y, -1)   // +y = up per PROTOCOL.md; Android sends -1 for one notch down
    }

    func testAllKindsAndActions() throws {
        for k in UInt8(0)...3 {
            for a in UInt8(0)...5 {
                let p = try XCTUnwrap(InputParser.parse(Self.input([Self.pointer(kind: k, action: a, x: 0.1, y: 0.2)])).first)
                XCTAssertEqual(p.kind.rawValue, k); XCTAssertEqual(p.action.rawValue, a)
            }
        }
        XCTAssertEqual(PointerAction.hoverMove.rawValue, 4)
        XCTAssertEqual(PointerAction.hoverExit.rawValue, 5)
    }

    func testTenPointersMultitouch() throws {
        let ptrs = (0..<10).map { Self.pointer(kind: 0, action: 1, id: UInt8($0), buttons: 1, x: Float($0) / 10, y: 0.5) }
        let parsed = InputParser.parse(Self.input(ptrs))
        XCTAssertEqual(parsed.count, 10)
        XCTAssertEqual(parsed.map(\.pointerId), Array(0..<10))
        XCTAssertEqual(parsed[9].x, 0.9, accuracy: 1e-6)
    }

    /// Windows `PointerSample.Parse`: `count = min(p[0], (len - 1) / 24)`, empty payload → no pointers.
    func testEmptyAndZeroCountYieldNoPointers() {
        XCTAssertTrue(InputParser.parse(Data()).isEmpty)
        XCTAssertTrue(InputParser.parse(Data([0])).isEmpty)                            // count 0
        XCTAssertTrue(InputParser.parse(Data([5])).isEmpty)                            // count 5, no records
        let one = Self.pointer(kind: 0, action: 0, x: 0, y: 0)
        XCTAssertTrue(InputParser.parse(Self.input([one]).dropLast()).isEmpty)         // 23 of 24 bytes
        var zero = Self.input([one]); zero[zero.startIndex] = 0
        XCTAssertTrue(InputParser.parse(zero).isEmpty)                                 // count 0 wins over data
    }

    func testTruncatedEventKeepsItsCompletePointers() {
        let ptrs = (0..<3).map { Self.pointer(kind: 0, action: 1, id: UInt8($0), x: 0.1 * Float($0), y: 0.5) }
        var raw = Self.input(ptrs)
        raw.removeLast(10)                                    // third record cut short
        XCTAssertEqual(InputParser.parse(raw).map(\.pointerId), [0, 1])
        var two = Self.input([ptrs[0], ptrs[1]]); two.removeLast(24)
        XCTAssertEqual(InputParser.parse(two).map(\.pointerId), [0])     // count says 2, has 1
        var claimsMore = Self.input([ptrs[0]]); claimsMore[claimsMore.startIndex] = 10
        XCTAssertEqual(InputParser.parse(claimsMore).count, 1)           // count 10, one record present
    }

    func testCountAboveTenIsNotRejected() {
        // Windows has no 1...10 range check: every complete record up to `count` is parsed.
        let ptrs = (0..<12).map { Self.pointer(kind: 0, action: 1, id: UInt8($0), x: 0.5, y: 0.5) }
        XCTAssertEqual(InputParser.parse(Self.input(ptrs)).count, 12)
        var capped = Self.input(ptrs); capped[capped.startIndex] = 11
        XCTAssertEqual(InputParser.parse(capped).map(\.pointerId), Array(0..<11))   // count < records: count wins
    }

    func testTrailingBytesAndSlicesAreTolerated() throws {
        var raw = Self.input([Self.pointer(kind: 2, action: 4, x: 0.3, y: 0.4)])
        raw.append(contentsOf: [9, 9, 9])
        XCTAssertEqual(InputParser.parse(raw).count, 1)
        // payload handed over as a slice of a frame buffer
        let frame = Frame.make(.input, raw)
        let p = try XCTUnwrap(InputParser.parse(frame.dropFirst(5)).first)
        XCTAssertEqual(p.action, .hoverMove)
        XCTAssertEqual(p.x, 0.3, accuracy: 1e-6)
    }

    func testUnknownKindOrActionSkipsOnlyThatPointer() throws {
        let good = Self.pointer(kind: 0, action: 0, id: 1, x: 0.5, y: 0.5)
        let badKind = Self.pointer(kind: 9, action: 0, id: 2, x: 0.5, y: 0.5)
        let badAction = Self.pointer(kind: 0, action: 6, id: 3, x: 0.5, y: 0.5)
        let parsed = InputParser.parse(Self.input([badKind, good, badAction]))
        XCTAssertEqual(parsed.map(\.pointerId), [1])
    }

    /// Windows InputInjector: HandleMouse treats any action other than down/up/cancel like a move (presses `buttons`),
    /// HandleScroll ignores the action; touch/pen switches have no default, so those pointers do nothing.
    func testUnknownActionIsAMoveForMouseAndScroll() {
        let mouse = Self.pointer(kind: 2, action: 9, id: 1, buttons: 2, x: 0.25, y: 0.75)
        let scroll = Self.pointer(kind: 3, action: 200, id: 2, x: 0, y: -1)
        let touch = Self.pointer(kind: 0, action: 6, id: 3, x: 0.5, y: 0.5)
        let pen = Self.pointer(kind: 1, action: 7, id: 4, x: 0.5, y: 0.5)
        let parsed = InputParser.parse(Self.input([mouse, scroll, touch, pen]))
        XCTAssertEqual(parsed.map(\.pointerId), [1, 2])
        XCTAssertEqual(parsed.map(\.action), [.move, .move])
        XCTAssertEqual(parsed[0].buttons, 2); XCTAssertEqual(parsed[0].x, 0.25)
        XCTAssertEqual(parsed[1].kind, .scroll); XCTAssertEqual(parsed[1].y, -1)
    }
}
