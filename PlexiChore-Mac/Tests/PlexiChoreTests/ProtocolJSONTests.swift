import XCTest
@testable import PlexiChore

/// JSON compatibility of the HELLO / SETTINGS / CONFIG models with what the Android app sends
/// (PlexiChore/app/.../core/Protocol.kt `hello()` / `requested()`, org.json formatting: no spaces,
/// integral doubles printed without ".0") and what older tablets send.
final class ProtocolJSONTests: XCTestCase {
    /// Shape produced by Protocol.hello() on a Galaxy Tab S8 (keys in Android's insertion order).
    static let androidHello = #"""
    {"protocol":1,"deviceId":"5f0c8a7e-2b1d-4c6e-9a3f-1d2e3f4a5b6c","deviceName":"Galaxy Tab S8","model":"SM-X700","widthPx":2560,"heightPx":1600,"densityDpi":340,"refreshHz":120,"codecs":["h264","mjpeg"],"maxDecodeWidth":3840,"maxDecodeHeight":2160,"decodeModes":[{"width":2560,"height":1600,"maxFps":120},{"width":3840,"height":2400,"maxFps":30},{"width":3840,"height":2160,"maxFps":60},{"width":1920,"height":1200,"maxFps":120}],"h264Profiles":["high","main","baseline"],"h264MaxLevel":"5.2","orientation":"portrait","viewportWidthPx":1600,"viewportHeightPx":2560,"touch":true,"pen":true,"requested":{"mode":"extend","monitorIndex":0,"resolutionScale":1,"fps":120,"bitrateKbps":30000,"quality":"balanced","codec":"h264","touchMode":"touch","position":"right","scalePercent":0,"orientation":"portrait"}}
    """#

    func testDecodesAndroidHello() throws {
        let h = try JSONDecoder().decode(HelloMessage.self, from: Data(Self.androidHello.utf8))
        XCTAssertEqual(h.protocol, 1)
        XCTAssertEqual(h.model, "SM-X700")
        XCTAssertEqual(h.widthPx, 2560); XCTAssertEqual(h.heightPx, 1600)
        XCTAssertEqual(h.densityDpi, 340)
        XCTAssertEqual(h.refreshHz, 120)
        XCTAssertEqual(h.decodeModes?.count, 4)
        XCTAssertEqual(h.decodeModes?.first, DecodeMode(width: 2560, height: 1600, maxFps: 120))
        XCTAssertEqual(h.h264Profiles, ["high", "main", "baseline"])
        XCTAssertEqual(h.h264MaxLevel, "5.2")
        XCTAssertEqual(h.orientation, "portrait")
        XCTAssertEqual(h.viewportWidthPx, 1600); XCTAssertEqual(h.viewportHeightPx, 2560)
        XCTAssertEqual(h.pen, true)
        let r = try XCTUnwrap(h.requested)
        XCTAssertEqual(r.resolutionScale, 1.0)
        XCTAssertEqual(r.scalePercent, 0)
        XCTAssertEqual(r.orientation, "portrait")

        // end-to-end policy on this HELLO
        let req = SessionPolicy.sanitize(RequestedSettings.defaults.merged(with: r))
        XCTAssertEqual(req.mode, "extend")
        let t = SessionPolicy.streamTarget(hello: h, resolutionScale: req.resolutionScale, fps: req.fps, portrait: req.isPortrait)
        XCTAssertEqual(t, .init(size: .init(1600, 2560), fps: 120, limitedByDecoder: false))
        XCTAssertEqual(SessionPolicy.targetScalePercent(hello: h, requested: req.scalePercent, streamSize: t.size), 200)
        XCTAssertEqual(SessionPolicy.h264Profile(for: h.h264Profiles), .high)
        let mode = SessionPolicy.virtualDisplayMode(stream: t.size, scalePercent: 200)
        XCTAssertEqual(mode.points, .init(800, 1280))
        XCTAssertTrue(mode.hiDPI)
    }

    func testHelloRoundTrip() throws {
        let h = try JSONDecoder().decode(HelloMessage.self, from: Data(Self.androidHello.utf8))
        let again = try JSONDecoder().decode(HelloMessage.self, from: try JSONEncoder().encode(h))
        XCTAssertEqual(again.decodeModes, h.decodeModes)
        XCTAssertEqual(again.h264Profiles, h.h264Profiles)
        XCTAssertEqual(again.h264MaxLevel, h.h264MaxLevel)
        XCTAssertEqual(again.orientation, h.orientation)
        XCTAssertEqual(again.viewportWidthPx, h.viewportWidthPx)
        XCTAssertEqual(again.viewportHeightPx, h.viewportHeightPx)
        XCTAssertEqual(again.requested, h.requested)

        // keys are byte-for-byte the Android names
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(h)) as? [String: Any])
        for key in ["decodeModes", "h264Profiles", "h264MaxLevel", "orientation", "viewportWidthPx", "viewportHeightPx"] {
            XCTAssertNotNil(obj[key], key)
        }
        let req = try XCTUnwrap(obj["requested"] as? [String: Any])
        XCTAssertNotNil(req["scalePercent"]); XCTAssertNotNil(req["orientation"])
    }

    func testOldHelloWithoutAdditiveFieldsStillDecodes() throws {
        let old = #"{"protocol":1,"deviceId":"x","deviceName":"Tab","model":"M","widthPx":1920,"heightPx":1200,"densityDpi":240,"refreshHz":60,"codecs":["h264","mjpeg"],"maxDecodeWidth":1920,"maxDecodeHeight":1200,"touch":true,"pen":false,"requested":{"mode":"extend","monitorIndex":0,"resolutionScale":1.0,"fps":60,"bitrateKbps":20000,"quality":"balanced","codec":"h264","touchMode":"touch","position":"right"}}"#
        let h = try JSONDecoder().decode(HelloMessage.self, from: Data(old.utf8))
        XCTAssertNil(h.decodeModes); XCTAssertNil(h.h264Profiles); XCTAssertNil(h.h264MaxLevel)
        XCTAssertNil(h.orientation); XCTAssertNil(h.viewportWidthPx)
        XCTAssertNil(h.requested?.scalePercent); XCTAssertNil(h.requested?.orientation)
        let req = SessionPolicy.sanitize(h.requested!)
        XCTAssertEqual(req.scalePercent, 0)
        XCTAssertEqual(req.orientation, "landscape")
        // Android sends h264MaxLevel "" when unknown
        let empty = try JSONDecoder().decode(HelloMessage.self, from: Data(#"{"h264MaxLevel":"","h264Profiles":[],"decodeModes":[]}"#.utf8))
        XCTAssertEqual(empty.h264MaxLevel, "")
        XCTAssertEqual(SessionPolicy.h264Profile(for: empty.h264Profiles), .high)
    }

    func testOrientationOnlySettingsMerges() throws {
        let partial = try JSONDecoder().decode(RequestedSettings.self, from: Data(#"{"orientation":"portrait"}"#.utf8))
        let session = RequestedSettings.defaults.merged(with: RequestedSettings(mode: "extend"))
        let merged = session.merged(with: partial)
        XCTAssertEqual(merged.orientation, "portrait")
        XCTAssertEqual(merged.mode, "extend")   // SETTINGS keeps the session's mode
        XCTAssertEqual(RequestedSettings.defaults.orientation, "landscape")
        XCTAssertEqual(RequestedSettings.defaults.scalePercent, 0)
    }

    func testConfigOmitsUnsetAdditiveFields() throws {
        var cfg = ConfigMessage(codec: "h264", width: 1920, height: 1200, fps: 60, bitrateKbps: 20000, mode: "mirror",
                                hostName: "Mac", hostOs: "macos", monitors: [], virtualDisplayAvailable: false)
        var obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(cfg)) as? [String: Any])
        XCTAssertNil(obj["link"]); XCTAssertNil(obj["encoder"]); XCTAssertNil(obj["scalePercent"])
        cfg.link = SessionPolicy.Link.usbWirelessAdb.rawValue
        cfg.encoder = "hw:VideoToolbox"
        cfg.scalePercent = 0
        obj = try XCTUnwrap(JSONSerialization.jsonObject(with: try JSONEncoder().encode(cfg)) as? [String: Any])
        XCTAssertEqual(obj["link"] as? String, "usb-wireless-adb")
        XCTAssertEqual(obj["encoder"] as? String, "hw:VideoToolbox")
        XCTAssertEqual(obj["scalePercent"] as? Int, 0)
        // a Windows-style CONFIG decodes too
        let win = #"{"codec":"h264","width":2560,"height":1600,"fps":60,"bitrateKbps":20000,"mode":"extend","hostName":"PC","hostOs":"windows","monitors":[{"index":0,"name":"Primary","width":1920,"height":1080}],"virtualDisplayAvailable":true,"encoder":"hw:NVIDIA","scalePercent":200,"link":"usb-cable"}"#
        let d = try JSONDecoder().decode(ConfigMessage.self, from: Data(win.utf8))
        XCTAssertEqual(d.scalePercent, 200); XCTAssertEqual(d.link, "usb-cable")
    }
}
