import XCTest
@testable import PlexiChore

/// Behaviours where the Mac host must match the Windows Engine byte-for-byte / default-for-default
/// (PlexiChore-Desktop/src/PlexiChore.Engine/Protocol/Protocol.cs, Discovery/DiscoveryBeacon.cs).
final class ProtocolParityTests: XCTestCase {

    private func hello(_ json: String) throws -> HelloMessage {
        try JSONDecoder().decode(HelloMessage.self, from: Data(json.utf8))
    }

    // MARK: HELLO defaults (Windows RequestedSettings initializers)

    func testHelloWithoutModeMeansMirror() throws {
        let h = try hello(#"{"protocol":1,"deviceId":"x","requested":{"fps":30}}"#)
        let r = RequestedSettings.initial(from: h)
        XCTAssertEqual(r.mode, "mirror")
        XCTAssertEqual(r.fps, 30)
        XCTAssertEqual(SessionPolicy.sanitize(r).mode, "mirror")
    }

    func testHelloWithoutRequestedMeansWindowsDefaults() throws {
        let r = SessionPolicy.sanitize(RequestedSettings.initial(from: try hello(#"{"protocol":1}"#)))
        XCTAssertEqual(r, SessionPolicy.Request(mode: "mirror", monitorIndex: 0, resolutionScale: 1.0, fps: 60,
                                                bitrateKbps: 20_000, quality: "balanced", codec: "h264",
                                                touchMode: "touch", position: "right", scalePercent: 0,
                                                orientation: "landscape"))
        // Identical to sanitizing an empty object (Windows: `new RequestedSettings()` then Sanitize()).
        XCTAssertEqual(r, SessionPolicy.sanitize(RequestedSettings()))
    }

    func testHelloModeIsKeptWhenSent() throws {
        for m in ["extend", "primary", "mirror"] {
            let r = RequestedSettings.initial(from: try hello(#"{"requested":{"mode":"\#(m)"}}"#))
            XCTAssertEqual(SessionPolicy.sanitize(r).mode, m)
        }
        // Unknown / empty mode → mirror (Windows Sanitize switch default)
        XCTAssertEqual(SessionPolicy.sanitize(RequestedSettings.initial(from: try hello(#"{"requested":{"mode":"tv"}}"#))).mode, "mirror")
        XCTAssertEqual(SessionPolicy.sanitize(RequestedSettings.initial(from: try hello(#"{"requested":{"mode":""}}"#))).mode, "mirror")
        XCTAssertEqual(SessionPolicy.sanitize(RequestedSettings.initial(from: try hello(#"{"requested":{"mode":" Extend "}}"#))).mode, "extend")
    }

    func testDefaultsMirrorWindowsInitializers() {
        XCTAssertEqual(RequestedSettings.defaults, RequestedSettings(
            mode: "mirror", monitorIndex: 0, resolutionScale: 1.0, fps: 60, bitrateKbps: 20_000,
            quality: "balanced", codec: "h264", touchMode: "touch", position: "right",
            scalePercent: 0, orientation: "landscape"))
    }

    // MARK: Discovery probe (Windows DiscoveryBeacon receive loop)

    func testDiscoveryQueryMatching() {
        func q(_ bytes: [UInt8]) -> Bool { DiscoveryBeacon.isDiscoveryQuery(bytes) }
        let plexi = Array("PLEXI?".utf8)
        XCTAssertTrue(q(plexi))
        XCTAssertTrue(q(plexi + [0]))                       // NUL-terminated
        XCTAssertTrue(q(plexi + Array("\r\n  ".utf8)))
        XCTAssertTrue(q(plexi + [UInt8](repeating: 0, count: 40)))   // only the first 16 bytes are looked at
        XCTAssertTrue(q(Array("PLEXI".utf8) + [0xFF]))      // ASCII decoding turns 0xFF into '?'
        XCTAssertFalse(q(Array(" PLEXI?".utf8)))            // leading whitespace is not trimmed
        XCTAssertFalse(q(plexi + [0x09]))                   // tab is not trimmed
        XCTAssertFalse(q(Array("PLEXI".utf8)))              // < 6 bytes
        XCTAssertFalse(q(Array("plexi?".utf8)))             // case-sensitive
        XCTAssertFalse(q(Array("PLEXI?X".utf8)))
        XCTAssertFalse(q(Array(#"{"svc":"plexichore"}"#.utf8)))   // other hosts' beacons
        XCTAssertTrue(DiscoveryBeacon.isDiscoveryQuery(Data(plexi)[0..<6]))   // slices
    }
}
