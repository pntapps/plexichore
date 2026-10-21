import CoreGraphics
import XCTest
@testable import PlexiChore

/// Lenient JSON (Windows Wire.Json parity), pipeline-failure escalation, size/scale helpers, stream parameter
/// change classification and encoder selection.
final class LenientDecodingTests: XCTestCase {
    func hello(_ json: String) throws -> HelloMessage { try JSONDecoder().decode(HelloMessage.self, from: Data(json.utf8)) }

    func testCaseInsensitiveKeysAndNumbersFromStrings() throws {
        let h = try hello(#"{"WIDTHPX":"2560","heightpx":" 1600 ","DensityDpi":320.0}"#)
        XCTAssertEqual(h.widthPx, 2560)
        XCTAssertEqual(h.heightPx, 1600)
        XCTAssertEqual(h.densityDpi, 320)
    }

    func testIntegralDoublesAndFractionalRefresh() throws {
        let h = try hello(#"{"requested":{"fps":60.0,"resolutionScale":"0.75"},"refreshHz":59.94}"#)
        XCTAssertEqual(h.requested?.fps, 60)
        XCTAssertEqual(h.requested?.resolutionScale, 0.75)
        XCTAssertEqual(h.refreshHz ?? 0, 59.94, accuracy: 1e-12)
    }

    func testNullIsAbsent() throws {
        let r = try JSONDecoder().decode(RequestedSettings.self, from: Data(#"{"mode":null,"fps":30}"#.utf8))
        XCTAssertNil(r.mode)
        XCTAssertEqual(RequestedSettings(mode: "extend").merged(with: r).mode, "extend")   // null does not clear
        XCTAssertEqual(r.fps, 30)
    }

    func testBoolsFromNumbersAndStrings() throws {
        XCTAssertEqual(try hello(#"{"pen":1}"#).pen, true)
        XCTAssertEqual(try hello(#"{"pen":"true"}"#).pen, true)
        XCTAssertEqual(try hello(#"{"pen":0,"touch":"FALSE"}"#).pen, false)
        XCTAssertEqual(try hello(#"{"touch":"FALSE"}"#).touch, false)
        XCTAssertNil(try hello(#"{"pen":"maybe"}"#).pen)
    }

    func testOneBadFieldDoesNotFailDecode() throws {
        let h = try hello(#"{"widthPx":{"oops":1},"heightPx":[1,2],"model":"SM-X700","codecs":["h264",7,null],"requested":{"fps":"sixty","mode":"mirror"}}"#)
        XCTAssertNil(h.widthPx); XCTAssertNil(h.heightPx)
        XCTAssertEqual(h.model, "SM-X700")
        XCTAssertEqual(h.codecs?.first, "h264")
        XCTAssertNil(h.requested?.fps)
        XCTAssertEqual(h.requested?.mode, "mirror")
        // RequestedSettings alone (SETTINGS payload) is lenient too
        let s = try JSONDecoder().decode(RequestedSettings.self, from: Data(#"{"fps":"sixty","bitrateKbps":"8000"}"#.utf8))
        XCTAssertNil(s.fps); XCTAssertEqual(s.bitrateKbps, 8000)
    }

    func testNonObjectPayloadThrows() {
        XCTAssertThrowsError(try hello("[1,2,3]"))
        XCTAssertThrowsError(try hello("42"))
        XCTAssertThrowsError(try hello("not json"))
        XCTAssertThrowsError(try JSONDecoder().decode(RequestedSettings.self, from: Data("[]".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(KeyMessage.self, from: Data(#""down""#.utf8)))
    }

    func testDecodeModesAndKeyLenient() throws {
        let h = try hello(#"{"decodeModes":[{"Width":"1920","HEIGHT":1080,"maxfps":60.0},{"width":1280},"junk"]}"#)
        XCTAssertEqual(h.decodeModes, [.init(width: 1920, height: 1080, maxFps: 60), .init(width: 1280, height: 0, maxFps: 0)])
        // the incomplete mode is then ignored by the clamp
        XCTAssertEqual(SessionPolicy.clampToDecoder(.init(1920, 1080), fps: 120, decodeModes: h.decodeModes).fps, 60)
        let k = try JSONDecoder().decode(KeyMessage.self, from: Data(#"{"ACTION":"down","keycode":"66","text":null}"#.utf8))
        XCTAssertEqual(k.action, "down"); XCTAssertEqual(k.keyCode, 66); XCTAssertNil(k.text)
    }

    func testJSONValueAccessors() {
        XCTAssertEqual(JSONValue.number(2.5).intValue, 2)          // half to even like C#
        XCTAssertEqual(JSONValue.number(3.5).intValue, 4)
        XCTAssertNil(JSONValue.number(1e20).intValue)
        XCTAssertEqual(JSONValue.string("7.0").intValue, 7)
        XCTAssertEqual(JSONValue.number(5).stringValue, "5")
        XCTAssertEqual(JSONValue.number(5.5).stringValue, "5.5")
        XCTAssertEqual(JSONValue.bool(true).stringValue, "true")
        XCTAssertNil(JSONValue.null.boolValue)
        XCTAssertEqual(JSONValue.string(" 1 ").boolValue, true)
        let o = LenientObject(["A": .number(1), "b": .null])
        XCTAssertEqual(o.int("a"), 1)
        XCTAssertNil(o["b"])
    }

    func testStatsBitrateIsInteger() throws {
        let data = try JSONEncoder().encode(StatsMessage(captureFps: 59.9, encodeMs: 3.25, bitrateKbps: 12000))
        let s = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(s.contains(#""bitrateKbps":12000"#), s)
        XCTAssertFalse(s.contains("12000.0"), s)
    }
}

final class PipelineDecisionTests: XCTestCase {
    typealias P = SessionPolicy

    func testStoppedDisconnects() {
        var st = P.FailureState()
        XCTAssertEqual(P.onPipelineEnded(reason: "stopped:Screen sharing was stopped on the Mac", state: &st), .disconnect)
        XCTAssertEqual(st, P.FailureState())
    }

    func testCaptureFailuresCountWithoutEncoderEscalation() {
        var st = P.FailureState()
        for i in 1...6 {
            XCTAssertEqual(P.onPipelineEnded(reason: "capture:display gone", state: &st), .restart(after: 1.0))
            XCTAssertEqual(st.captureFailures, i)
            XCTAssertEqual(st.failures, 0)   // capture losses never count as encoder failures
        }
        XCTAssertFalse(st.disallowHardware); XCTAssertFalse(st.forceMjpeg)
        XCTAssertEqual(P.onPipelineEnded(reason: "capture:display gone", state: &st), .disconnect)
    }

    func testEncoderEscalation() {
        var st = P.FailureState()
        _ = P.onPipelineEnded(reason: "encoder:VT -12902", state: &st)
        XCTAssertTrue(st.disallowHardware); XCTAssertFalse(st.forceMjpeg)
        _ = P.onPipelineEnded(reason: "error:boom", state: &st)
        XCTAssertTrue(st.forceMjpeg)
        // a capture failure after that keeps the escalation flags
        _ = P.onPipelineEnded(reason: "capture:x", state: &st)
        XCTAssertEqual(st.failures, 2)
        XCTAssertEqual(st.captureFailures, 1)
        XCTAssertTrue(st.disallowHardware && st.forceMjpeg)
    }

    func testStreamedHealthilyResetsCountersButKeepsEscalation() {
        var st = P.FailureState(failures: 2, disallowHardware: true, forceMjpeg: true, extendBroken: true, captureFailures: 4)
        P.streamedHealthily(state: &st)
        XCTAssertEqual(st.failures, 0); XCTAssertEqual(st.captureFailures, 0)
        XCTAssertTrue(st.disallowHardware && st.forceMjpeg && st.extendBroken)
    }

    func testFitSize() {
        let box = P.Size(2560, 1600)
        XCTAssertEqual(P.fitSize(src: .init(2880, 1800), box: box), .init(2560, 1600))
        XCTAssertEqual(P.fitSize(src: .init(1920, 1080), box: box), .init(1920, 1080))   // no upscale
        XCTAssertEqual(P.fitSize(src: .init(3840, 2160), box: box), .init(2560, 1440))
        XCTAssertEqual(P.fitSize(src: .init(3024, 1964), box: box), .init(2462, 1600))   // floor even
        XCTAssertEqual(P.fitSize(src: .init(1, 1), box: box), .init(2, 2))               // min 2
        XCTAssertEqual(P.fitSize(src: .init(10000, 1), box: box), .init(2560, 2))
        XCTAssertEqual(P.fitSize(src: .init(0, 1080), box: box), box)
        for src in [P.Size(3456, 2234), .init(1512, 982), .init(5120, 2880), .init(1080, 1920)] {
            let f = P.fitSize(src: src, box: box)
            XCTAssertLessThanOrEqual(f.width, box.width); XCTAssertLessThanOrEqual(f.height, box.height)
            XCTAssertEqual(f.width % 2, 0); XCTAssertEqual(f.height % 2, 0)
            let ar = Double(src.width) / Double(src.height), far = Double(f.width) / Double(f.height)
            XCTAssertEqual(far, ar, accuracy: ar * 0.01, "\(src) → \(f)")
        }
    }

    func testHostScalePercent() {
        XCTAssertEqual(P.hostScalePercent(displayScaleMode: "standard", requested: 150, resolved: 150), 100)
        XCTAssertEqual(P.hostScalePercent(displayScaleMode: "hidpi", requested: 0, resolved: 150), 200)
        XCTAssertEqual(P.hostScalePercent(displayScaleMode: "hidpi", requested: 150, resolved: 150), 150)
        XCTAssertEqual(P.hostScalePercent(displayScaleMode: "auto", requested: 0, resolved: 175), 175)
        XCTAssertEqual(P.hostScalePercent(displayScaleMode: "", requested: 0, resolved: 225), 225)
    }
}

final class StreamParametersTests: XCTestCase {
    let base = StreamParameters(codec: "h264", width: 1280, height: 800, fps: 60, bitrateKbps: 8000, quality: "balanced",
                                mode: "extend", displayID: 1, periodicKeyframes: false)

    func testCadenceOnlyChange() {
        var b = base; b.bitrateKbps = 20000
        XCTAssertTrue(base.isCadenceOnlyChange(to: b))
        b.fps = 120
        XCTAssertTrue(base.isCadenceOnlyChange(to: b))
        XCTAssertTrue(base.isCadenceOnlyChange(to: base))
        let edits: [(String, (inout StreamParameters) -> Void)] = [
            ("width", { $0.width = 1920 }), ("height", { $0.height = 1200 }), ("codec", { $0.codec = "mjpeg" }),
            ("quality", { $0.quality = "quality" }), ("profile", { $0.profile = .main }), ("display", { $0.displayID = 2 }),
            ("mode", { $0.mode = "mirror" }), ("preferHardware", { $0.preferHardware = false }),
            ("allowHardware", { $0.allowHardware = false }), ("periodicKeyframes", { $0.periodicKeyframes = true }),
        ]
        for (name, edit) in edits {
            var c = base; c.fps = 30; edit(&c)
            XCTAssertFalse(base.isCadenceOnlyChange(to: c), name)
        }
    }

    func testMakeEncoderMJPEG() {
        var p = base; p.codec = "mjpeg"
        let e = StreamPipeline.makeEncoder(p)
        defer { e.invalidate() }
        XCTAssertTrue(e is MJPEGEncoder)
        XCTAssertEqual(e.codec, "mjpeg")
        XCTAssertFalse(e.isHardware)
    }

    func testMakeEncoderH264Name() {
        let e = StreamPipeline.makeEncoder(base)
        defer { e.invalidate() }
        if e.codec == "h264" {
            XCTAssertTrue(e.name.hasPrefix("hw:") || e.name.hasPrefix("sw:"), e.name)
            XCTAssertEqual(e.name.hasPrefix("hw:"), e.isHardware)
        } else {
            XCTAssertTrue(e is MJPEGEncoder)   // no VideoToolbox H.264 at all on this machine
        }
    }

    func testMakeEncoderWithoutHardware() {
        var p = base; p.allowHardware = false
        let e = StreamPipeline.makeEncoder(p)
        defer { e.invalidate() }
        XCTAssertFalse(e.isHardware, e.name)
        if e.codec == "h264" { XCTAssertTrue(e.name.hasPrefix("sw:"), e.name) }
    }
}
