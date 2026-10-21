import XCTest
@testable import PlexiChore

/// Every JSON message of PROTOCOL.md: the documented examples decode, our encodings round-trip, and the
/// key names are byte-for-byte those the Android app reads/writes (core/Protocol.kt, StreamSession.kt,
/// HostDiscovery.kt).
final class ProtocolMessagesTests: XCTestCase {

    private func keys(_ data: Data) throws -> Set<String> {
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return Set(obj.keys)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    // MARK: HELLO

    /// PROTOCOL.md HELLO example with the comments removed and one value picked per alternative.
    static let protocolHello = #"""
    {
      "protocol": 1, "deviceId": "0d6f8a2e-1111-2222-3333-444455556666", "deviceName": "Galaxy Tab S8", "model": "SM-X700",
      "widthPx": 2560, "heightPx": 1600, "densityDpi": 320, "refreshHz": 120,
      "codecs": ["h264", "mjpeg"], "maxDecodeWidth": 3840, "maxDecodeHeight": 2160, "touch": true, "pen": true,
      "requested": {"mode": "extend", "monitorIndex": 0, "resolutionScale": 1.0, "fps": 60, "bitrateKbps": 20000,
                    "quality": "balanced", "codec": "h264", "touchMode": "touch", "position": "right",
                    "scalePercent": 0, "orientation": "landscape"},
      "decodeModes": [{"width":2560,"height":1600,"maxFps":120}, {"width":3840,"height":2160,"maxFps":60}],
      "h264Profiles": ["high","main","baseline"], "h264MaxLevel": "5.1", "orientation": "landscape",
      "viewportWidthPx": 2560, "viewportHeightPx": 1600
    }
    """#

    func testProtocolHelloExampleDecodes() throws {
        let h = try JSONDecoder().decode(HelloMessage.self, from: Data(Self.protocolHello.utf8))
        XCTAssertEqual(h.protocol, PlexiProtocol.version)
        XCTAssertEqual(h.deviceName, "Galaxy Tab S8")
        XCTAssertEqual(h.codecs, ["h264", "mjpeg"])
        XCTAssertEqual(h.maxDecodeWidth, 3840); XCTAssertEqual(h.maxDecodeHeight, 2160)
        XCTAssertEqual(h.touch, true); XCTAssertEqual(h.pen, true)
        XCTAssertEqual(h.decodeModes, [.init(width: 2560, height: 1600, maxFps: 120), .init(width: 3840, height: 2160, maxFps: 60)])
        XCTAssertEqual(h.h264MaxLevel, "5.1")
        var expected = RequestedSettings.defaults
        expected.mode = "extend"
        XCTAssertEqual(h.requested, expected)
    }

    func testHelloKeysAreAndroidNames() throws {
        let h = try JSONDecoder().decode(HelloMessage.self, from: Data(Self.protocolHello.utf8))
        let data = try JSONEncoder().encode(h)
        // Protocol.hello() in the Android app
        let android: Set<String> = ["protocol", "deviceId", "deviceName", "model", "widthPx", "heightPx", "densityDpi",
                                    "refreshHz", "codecs", "maxDecodeWidth", "maxDecodeHeight", "decodeModes",
                                    "h264Profiles", "h264MaxLevel", "orientation", "viewportWidthPx", "viewportHeightPx",
                                    "touch", "pen", "requested"]
        XCTAssertEqual(try keys(data), android)
        let req = try XCTUnwrap(try object(data)["requested"] as? [String: Any])
        // Protocol.requested() in the Android app
        XCTAssertEqual(Set(req.keys), ["mode", "monitorIndex", "resolutionScale", "fps", "bitrateKbps", "quality",
                                       "codec", "touchMode", "position", "scalePercent", "orientation"])
        let modes = try XCTUnwrap(try object(data)["decodeModes"] as? [[String: Any]])
        XCTAssertEqual(Set(modes[0].keys), ["width", "height", "maxFps"])
    }

    func testHelloToleratesUnknownAndMissingFields() throws {
        let h = try JSONDecoder().decode(HelloMessage.self,
            from: Data(#"{"protocol":2,"futureField":{"x":[1,2]},"requested":{"mode":"primary","newThing":true}}"#.utf8))
        XCTAssertEqual(h.protocol, 2)
        XCTAssertEqual(h.requested?.mode, "primary")
        XCTAssertNil(h.widthPx)
        let empty = try JSONDecoder().decode(HelloMessage.self, from: Data("{}".utf8))
        XCTAssertNil(empty.requested)
    }

    func testHelloRefreshHzMayBeFractional() throws {
        // Android Display.refreshRate is a float (e.g. 59.94); org.json prints it as 59.94
        let h = try JSONDecoder().decode(HelloMessage.self, from: Data(#"{"refreshHz":59.94}"#.utf8))
        XCTAssertEqual(h.refreshHz ?? 0, 59.94, accuracy: 1e-9)
    }

    func testRequestedValuesForEveryAlternative() throws {
        for mode in ["extend", "primary", "mirror"] {
            for touch in ["touch", "mouse", "none"] {
                for pos in ["right", "left", "top", "bottom"] {
                    let json = #"{"mode":"\#(mode)","touchMode":"\#(touch)","position":"\#(pos)"}"#
                    let r = try JSONDecoder().decode(RequestedSettings.self, from: Data(json.utf8))
                    let s = SessionPolicy.sanitize(r)
                    XCTAssertEqual(s.mode, mode); XCTAssertEqual(s.touchMode, touch); XCTAssertEqual(s.position, pos)
                }
            }
        }
        for q in ["performance", "balanced", "quality"] {
            XCTAssertEqual(SessionPolicy.sanitize(RequestedSettings(quality: q)).quality, q)
        }
        for fps in [30, 60, 90, 120] {
            XCTAssertEqual(SessionPolicy.sanitize(RequestedSettings(fps: fps)).fps, fps)
        }
    }

    // MARK: SETTINGS (partial `requested`)

    func testSettingsPartialsMerge() throws {
        let base = RequestedSettings.defaults
        func merge(_ json: String) throws -> RequestedSettings {
            base.merged(with: try JSONDecoder().decode(RequestedSettings.self, from: Data(json.utf8)))
        }
        XCTAssertEqual(try merge("{}"), base)
        XCTAssertEqual(try merge(#"{"fps":120}"#).fps, 120)
        XCTAssertEqual(try merge(#"{"scalePercent":150}"#).scalePercent, 150)
        let all = try merge(#"{"mode":"mirror","monitorIndex":1,"resolutionScale":0.5,"fps":30,"bitrateKbps":8000,"quality":"performance","codec":"mjpeg","touchMode":"mouse","position":"left","scalePercent":125,"orientation":"portrait"}"#)
        XCTAssertEqual(all, RequestedSettings(mode: "mirror", monitorIndex: 1, resolutionScale: 0.5, fps: 30, bitrateKbps: 8000,
                                              quality: "performance", codec: "mjpeg", touchMode: "mouse", position: "left",
                                              scalePercent: 125, orientation: "portrait"))
        // merged() overlays every field, so a field-by-field round trip back to defaults is exact
        XCTAssertEqual(all.merged(with: base), base)
        // merging never clears: nil in `other` keeps the current value
        XCTAssertEqual(all.merged(with: RequestedSettings()), all)
    }

    func testSettingsWithWrongTypeIsLenient() throws {
        // Windows parity (Wire.Json): an odd field is dropped, the rest of SETTINGS still applies.
        let r = try JSONDecoder().decode(RequestedSettings.self, from: Data(#"{"fps":"sixty","orientation":"portrait"}"#.utf8))
        XCTAssertNil(r.fps)
        XCTAssertEqual(r.orientation, "portrait")
        XCTAssertThrowsError(try JSONDecoder().decode(RequestedSettings.self, from: Data("not json".utf8)))
    }

    // MARK: CONFIG

    static let protocolConfig = #"""
    {"codec":"h264","width":2560,"height":1600,"fps":60,"bitrateKbps":20000,
     "mode":"extend","hostName":"DESKTOP-ABC","hostOs":"windows",
     "monitors":[{"index":0,"name":"Primary","width":1920,"height":1080}],
     "virtualDisplayAvailable":true,
     "scalePercent":200}
    """#

    func testProtocolConfigExampleRoundTrips() throws {
        let c = try JSONDecoder().decode(ConfigMessage.self, from: Data(Self.protocolConfig.utf8))
        XCTAssertEqual(c.monitors, [MonitorInfo(index: 0, name: "Primary", width: 1920, height: 1080)])
        XCTAssertEqual(c.scalePercent, 200)
        XCTAssertNil(c.link); XCTAssertNil(c.encoder)
        let again = try JSONDecoder().decode(ConfigMessage.self, from: try JSONEncoder().encode(c))
        XCTAssertEqual(again, c)
    }

    func testConfigKeysAreWhatAndroidParses() throws {
        let c = ConfigMessage(codec: "h264", width: 1600, height: 2560, fps: 120, bitrateKbps: 30000, mode: "primary",
                              hostName: "MacBook", hostOs: "macos",
                              monitors: [.init(index: 0, name: "Built-in Retina Display", width: 1512, height: 982)],
                              virtualDisplayAvailable: true, encoder: "hw:VideoToolbox H.264", scalePercent: 200, link: "usb-cable")
        let data = try JSONEncoder().encode(c)
        // every key Protocol.parseConfig reads is present, plus monitors/encoder
        XCTAssertEqual(try keys(data), ["codec", "width", "height", "fps", "bitrateKbps", "mode", "hostName", "hostOs",
                                        "monitors", "virtualDisplayAvailable", "encoder", "scalePercent", "link"])
        let o = try object(data)
        XCTAssertEqual(o["hostOs"] as? String, "macos")
        XCTAssertEqual(o["width"] as? Int, 1600)
        XCTAssertEqual(o["virtualDisplayAvailable"] as? Bool, true)
        let mon = try XCTUnwrap((o["monitors"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(mon.keys), ["index", "name", "width", "height"])   // `id` (Identifiable) is not encoded
    }

    func testConfigModeAndLinkVocabulary() {
        for l in SessionPolicy.Link.allValues { XCTAssertTrue(["usb-cable", "usb-wireless-adb", "usb-tether", "wifi"].contains(l.rawValue)) }
        XCTAssertEqual(SessionPolicy.Link(rawValue: "usb-tether"), .usbTether)
        XCTAssertEqual(SessionPolicy.Link(rawValue: "wifi"), .wifi)
        XCTAssertNil(SessionPolicy.Link(rawValue: "ethernet"))
    }

    // MARK: PAIRING / STATS / KEY / BYE / beacon

    func testPairingMessages() throws {
        for status in ["waiting", "approved", "rejected"] {
            let data = try JSONEncoder().encode(PairingMessage(status: status, code: "4821"))
            XCTAssertEqual(try keys(data), ["status", "code"])   // StreamSession.kt optString("status"/"code")
            let back = try JSONDecoder().decode(PairingMessage.self, from: data)
            XCTAssertEqual(back.status, status); XCTAssertEqual(back.code, "4821")
        }
        // code is a STRING (leading zeros survive)
        let o = try object(try JSONEncoder().encode(PairingMessage(status: "waiting", code: "0042")))
        XCTAssertEqual(o["code"] as? String, "0042")
    }

    func testStatsExample() throws {
        let s = try JSONDecoder().decode(StatsMessage.self, from: Data(#"{"captureFps":60,"encodeMs":4.1,"bitrateKbps":12000}"#.utf8))
        XCTAssertEqual(s.captureFps, 60); XCTAssertEqual(s.encodeMs, 4.1); XCTAssertEqual(s.bitrateKbps, 12000)
        XCTAssertEqual(try keys(try JSONEncoder().encode(s)), ["captureFps", "encodeMs", "bitrateKbps"])
    }

    func testKeyMessages() throws {
        let down = try JSONDecoder().decode(KeyMessage.self, from: Data(#"{"action":"down","keyCode":66}"#.utf8))
        XCTAssertEqual(down.action, "down"); XCTAssertEqual(down.keyCode, 66); XCTAssertNil(down.text)
        let text = try JSONDecoder().decode(KeyMessage.self, from: Data(#"{"action":"up","keyCode":0,"text":"ü"}"#.utf8))
        XCTAssertEqual(text.text, "ü")
        let bare = try JSONDecoder().decode(KeyMessage.self, from: Data("{}".utf8))
        XCTAssertNil(bare.action); XCTAssertNil(bare.keyCode)
    }

    func testByeReasonIsPlainUTF8() {
        let f = Frame.text(.bye, "Host stopped")
        XCTAssertEqual(String(data: f.dropFirst(5), encoding: .utf8), "Host stopped")
    }

    func testBeaconMatchesProtocolAndHostDiscovery() throws {
        let b = BeaconMessage(id: "5f0c8a7e-0000-4000-8000-000000000001", name: "MacBook-Pro", virtualDisplay: true)
        let data = try JSONEncoder().encode(b)
        let o = try object(data)
        XCTAssertEqual(Set(o.keys), ["svc", "v", "id", "name", "os", "port", "virtualDisplay"])
        XCTAssertEqual(o["svc"] as? String, "plexichore")    // HostDiscovery.kt drops anything else
        XCTAssertEqual(o["v"] as? Int, 1)
        XCTAssertEqual(o["os"] as? String, "macos")
        XCTAssertEqual(o["port"] as? Int, 47800)
        XCTAssertEqual(o["virtualDisplay"] as? Bool, true)
        // PROTOCOL.md example decodes into the same model
        let ex = #"{"svc":"plexichore","v":1,"id":"<stable uuid>","name":"DESKTOP-ABC","os":"windows","port":47800,"virtualDisplay":true}"#
        let d = try JSONDecoder().decode(BeaconMessage.self, from: Data(ex.utf8))
        XCTAssertEqual(d.os, "windows"); XCTAssertEqual(d.name, "DESKTOP-ABC")
        // a beacon must fit comfortably in one UDP datagram
        XCTAssertLessThan(data.count, 512)
    }
}

private extension SessionPolicy.Link {
    static var allValues: [SessionPolicy.Link] { [.usbCable, .usbWirelessAdb, .usbTether, .wifi] }
}
