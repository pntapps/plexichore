import XCTest
@testable import PlexiChore

typealias P = SessionPolicy

// MARK: - Display scale (ported from PlexiChore-Desktop/tests/PlexiChore.App.Tests/DisplayScaleTests.cs)

final class DisplayScaleTests: XCTestCase {
    func testAutoMatchesAndroidUISize() {
        let vectors: [(Int, Int)] = [
            (240, 150),   // 10-11" 1920x1200 tablets (hdpi bucket)
            (320, 200),   // Galaxy Tab S8 11" / S8+ 12.4" (xhdpi)
            (340, 200),   // Samsung default for Tab S8/S8+ (tie 212.5 → lower step)
            (280, 175), (360, 225), (400, 250),
            (480, 250),   // clamped to AutoMax
            (160, 125),   // clamped to AutoMin
        ]
        for (dpi, expected) in vectors {
            XCTAssertEqual(P.autoScalePercent(densityDpi: dpi), expected, "densityDpi \(dpi)")
        }
    }

    func testAutoAccountsForDownscaledStream() {
        XCTAssertEqual(P.autoScalePercent(densityDpi: 320, pixelRatio: 2.0), 100)
        XCTAssertEqual(P.autoScalePercent(densityDpi: 320, pixelRatio: 2560.0 / 1920), 150)
        XCTAssertEqual(P.autoScalePercent(densityDpi: 320, pixelRatio: 0.5), 200) // < 1 ignored
        XCTAssertEqual(P.autoScalePercent(densityDpi: 320, pixelRatio: .nan), 200)
    }

    func testAutoWithoutDensityGuessesFromPanel() {
        XCTAssertEqual(P.autoScalePercent(densityDpi: 0, pixelRatio: 1.0, shortEdgePx: 1600), 200)
        XCTAssertEqual(P.autoScalePercent(densityDpi: 0, pixelRatio: 1.0, shortEdgePx: 1200), 150)
    }

    func testSanitizeRequestSnapsToSteps() {
        let vectors: [(Int, Int)] = [(0, 0), (-5, 0), (100, 100), (200, 200), (210, 200), (240, 250), (999, 300), (112, 100), (113, 125)]
        for (input, expected) in vectors {
            XCTAssertEqual(P.sanitizeScaleRequest(input), expected, "input \(input)")
        }
    }

    func testResolvePrefersExplicitRequest() {
        XCTAssertEqual(P.resolveScalePercent(requested: 175, densityDpi: 320), 175)
        XCTAssertEqual(P.resolveScalePercent(requested: 0, densityDpi: 320), 200)
    }

    func testPixelRatio() {
        XCTAssertEqual(P.pixelRatio(tabletWidthPx: 2560, tabletHeightPx: 1600, virtualWidth: 1280, virtualHeight: 800), 2.0)
        XCTAssertEqual(P.pixelRatio(tabletWidthPx: 2560, tabletHeightPx: 1600, virtualWidth: 1600, virtualHeight: 2560), 1.0) // rotation-agnostic
        XCTAssertEqual(P.pixelRatio(tabletWidthPx: 0, tabletHeightPx: 1600, virtualWidth: 1280, virtualHeight: 800), 1.0)
        XCTAssertEqual(P.pixelRatio(tabletWidthPx: 1920, tabletHeightPx: 1200, virtualWidth: 2560, virtualHeight: 1600), 1.0) // never < 1
    }

    func testTargetScaleUsesStreamSize() {
        var hello = HelloMessage()
        hello.widthPx = 2560; hello.heightPx = 1600; hello.densityDpi = 320
        XCTAssertEqual(P.targetScalePercent(hello: hello, requested: 0, streamSize: .init(2560, 1600)), 200)
        XCTAssertEqual(P.targetScalePercent(hello: hello, requested: 0, streamSize: .init(1280, 800)), 100)
        XCTAssertEqual(P.targetScalePercent(hello: hello, requested: 225, streamSize: .init(1280, 800)), 225)
        hello.densityDpi = nil
        XCTAssertEqual(P.targetScalePercent(hello: hello, requested: 0, streamSize: .init(2560, 1600)), 200)
    }

    func testHelloRequestedScalePercentParsesAndDefaultsToAuto() throws {
        let withScale = try JSONDecoder().decode(HelloMessage.self,
            from: Data(#"{"densityDpi":320,"requested":{"mode":"extend","scalePercent":175}}"#.utf8))
        XCTAssertEqual(P.sanitize(withScale.requested!).scalePercent, 175)
        XCTAssertEqual(withScale.densityDpi, 320)
        let old = try JSONDecoder().decode(HelloMessage.self, from: Data(#"{"requested":{"mode":"extend"}}"#.utf8))
        XCTAssertEqual(P.sanitize(old.requested!).scalePercent, 0)
    }

    func testSettingsMergeScaleOnlyIsDetected() throws {
        let cur = RequestedSettings(mode: "extend", scalePercent: 0)
        let curR = P.sanitize(cur)
        func merge(_ json: String) throws -> P.Request {
            P.sanitize(cur.merged(with: try JSONDecoder().decode(RequestedSettings.self, from: Data(json.utf8))))
        }
        let next = try merge(#"{"scalePercent":225}"#)
        XCTAssertEqual(next.scalePercent, 225)
        XCTAssertTrue(P.isScaleOnlyChange(curR, next))
        XCTAssertFalse(P.isScaleOnlyChange(curR, try merge(#"{"scalePercent":225,"fps":30}"#)))
        XCTAssertFalse(P.isScaleOnlyChange(curR, curR))
        XCTAssertFalse(P.isScaleOnlyChange(curR, try merge(#"{"orientation":"portrait"}"#)))
    }

    func testConfigSerializesScalePercent() throws {
        let cfg = ConfigMessage(codec: "h264", width: 2560, height: 1600, fps: 60, bitrateKbps: 20000, mode: "extend",
                                hostName: "Mac", hostOs: "macos", monitors: [], virtualDisplayAvailable: true,
                                scalePercent: 200)
        let json = String(decoding: try JSONEncoder().encode(cfg), as: UTF8.self)
        XCTAssertTrue(json.contains(#""scalePercent":200"#), json)
    }
}

// MARK: - Mac virtual display mode for a scale

final class VirtualDisplayModeTests: XCTestCase {
    let s8 = P.Size(2560, 1600)

    func testNativeModes() {
        let m100 = P.virtualDisplayMode(stream: s8, scalePercent: 100)
        XCTAssertEqual(m100, .init(backing: s8, points: s8, hiDPI: false, stream: s8, scalePercent: 100))
        XCTAssertFalse(m100.needsResample)
        let m200 = P.virtualDisplayMode(stream: s8, scalePercent: 200)
        XCTAssertEqual(m200, .init(backing: s8, points: .init(1280, 800), hiDPI: true, stream: s8, scalePercent: 200))
        XCTAssertFalse(m200.needsResample)
        XCTAssertEqual(P.virtualDisplayMode(stream: s8, scalePercent: 0).scalePercent, 100)
    }

    func testScaledModes() {
        let m150 = P.virtualDisplayMode(stream: s8, scalePercent: 150)
        XCTAssertEqual(m150.points, .init(1707, 1067))
        XCTAssertEqual(m150.backing, .init(3414, 2134))
        XCTAssertTrue(m150.hiDPI && m150.needsResample)
        XCTAssertEqual(m150.scalePercent, 150)

        let m125 = P.virtualDisplayMode(stream: .init(2800, 1752), scalePercent: 125)
        XCTAssertEqual(m125.points, .init(2240, 1402))
        XCTAssertEqual(m125.backing, .init(4480, 2804))

        let m300 = P.virtualDisplayMode(stream: s8, scalePercent: 300)
        XCTAssertEqual(m300.points, .init(853, 533))
        XCTAssertEqual(m300.backing, .init(1706, 1066))  // smaller than the stream: capture upsamples

        // portrait keeps orientation
        XCTAssertEqual(P.virtualDisplayMode(stream: .init(1600, 2560), scalePercent: 150).points, .init(1067, 1707))
    }

    func testBackingCapFallsBackToNative() {
        XCTAssertEqual(P.virtualDisplayMode(stream: .init(3840, 2400), scalePercent: 125).backing, .init(6144, 3840))
        let capped = P.virtualDisplayMode(stream: .init(3840, 2400), scalePercent: 125, strategy: .scaled(maxBackingLongEdge: 5000))
        XCTAssertEqual(capped.scalePercent, 100)
        XCTAssertFalse(capped.hiDPI)
    }

    func testNativeOnlySnapsTiesLower() {
        XCTAssertEqual(P.virtualDisplayMode(stream: s8, scalePercent: 125, strategy: .nativeOnly).scalePercent, 100)
        XCTAssertEqual(P.virtualDisplayMode(stream: s8, scalePercent: 150, strategy: .nativeOnly).scalePercent, 100)
        XCTAssertEqual(P.virtualDisplayMode(stream: s8, scalePercent: 175, strategy: .nativeOnly).scalePercent, 200)
        XCTAssertEqual(P.virtualDisplayMode(stream: s8, scalePercent: 300, strategy: .nativeOnly).scalePercent, 200)
    }

    func testConfigScalePercent() {
        let m150 = P.virtualDisplayMode(stream: s8, scalePercent: 150)
        XCTAssertEqual(P.configScalePercent(mode: "mirror", applied: m150), 0)
        XCTAssertEqual(P.configScalePercent(mode: "extend", applied: nil), 0)
        XCTAssertEqual(P.configScalePercent(mode: "extend", applied: m150), 150)
        XCTAssertEqual(P.configScalePercent(mode: "primary", applied: m150, actualHiDPI: true), 150)
        let m200 = P.virtualDisplayMode(stream: s8, scalePercent: 200)
        XCTAssertEqual(P.configScalePercent(mode: "extend", applied: m200, actualHiDPI: false), 100) // shim fell back to 1x
    }
}

// MARK: - Stream size / decoder clamp / profile / codec

final class StreamSizeTests: XCTestCase {
    func testEvenMatchesCSharp() {
        XCTAssertEqual(P.even(1314.0), 1314)
        XCTAssertEqual(P.even(1315.0), 1314)
        XCTAssertEqual(P.even(1313.6), 1314)
        XCTAssertEqual(P.even(2.5), 2)    // banker's rounding: 2
        XCTAssertEqual(P.even(3.5), 4)    // banker's rounding: 4
        XCTAssertEqual(P.even(0.4), 2)    // floor of 2
    }

    func testTabletBox() {
        XCTAssertEqual(P.tabletBox(widthPx: 2560, heightPx: 1600, maxDecodeWidth: 3840, maxDecodeHeight: 2160, scale: 1), .init(2560, 1600))
        XCTAssertEqual(P.tabletBox(widthPx: 1600, heightPx: 2560, maxDecodeWidth: 3840, maxDecodeHeight: 2160, scale: 1), .init(2560, 1600))
        XCTAssertEqual(P.tabletBox(widthPx: 2560, heightPx: 1600, maxDecodeWidth: 3840, maxDecodeHeight: 2160, scale: 1, portrait: true), .init(1600, 2560))
        XCTAssertEqual(P.tabletBox(widthPx: 2560, heightPx: 1600, maxDecodeWidth: nil, maxDecodeHeight: nil, scale: 0.5), .init(1280, 800))
        XCTAssertEqual(P.tabletBox(widthPx: 2800, heightPx: 1752, maxDecodeWidth: 3840, maxDecodeHeight: 2160, scale: 0.75), .init(2100, 1314))
        // decoder limit on long/short edges: f = min(1920/2560, 1080/1600) = 0.675
        XCTAssertEqual(P.tabletBox(widthPx: 2560, heightPx: 1600, maxDecodeWidth: 1920, maxDecodeHeight: 1080, scale: 1), .init(1728, 1080))
        XCTAssertEqual(P.tabletBox(widthPx: 2560, heightPx: 1600, maxDecodeWidth: 1080, maxDecodeHeight: 1920, scale: 1, portrait: true), .init(1080, 1728))
        // missing size → 1920x1080
        XCTAssertEqual(P.tabletBox(widthPx: nil, heightPx: 0, maxDecodeWidth: nil, maxDecodeHeight: nil, scale: 1), .init(1920, 1080))
    }

    let tabS8: [DecodeMode] = [.init(width: 3840, height: 2160, maxFps: 60), .init(width: 2560, height: 1600, maxFps: 120),
                               .init(width: 1920, height: 1080, maxFps: 120)]

    func testClampWithoutModesIsUnchanged() {
        XCTAssertEqual(P.clampToDecoder(.init(2560, 1600), fps: 120, decodeModes: nil), .init(size: .init(2560, 1600), fps: 120, limitedByDecoder: false))
        XCTAssertEqual(P.clampToDecoder(.init(2560, 1600), fps: 120, decodeModes: [.init(width: 0, height: 0, maxFps: 0)]).fps, 120)
    }

    func testClampKeepsSizeAndLowersFps() {
        XCTAssertEqual(P.clampToDecoder(.init(2560, 1600), fps: 120, decodeModes: tabS8), .init(size: .init(2560, 1600), fps: 120, limitedByDecoder: false))
        XCTAssertEqual(P.clampToDecoder(.init(2560, 1600), fps: 60, decodeModes: tabS8).fps, 60)
        // only a 60 fps mode covers 2800x1752
        XCTAssertEqual(P.clampToDecoder(.init(2800, 1752), fps: 120, decodeModes: tabS8), .init(size: .init(2800, 1752), fps: 60, limitedByDecoder: false))
        // rotated (portrait) boxes are covered by landscape modes
        XCTAssertEqual(P.clampToDecoder(.init(1600, 2560), fps: 120, decodeModes: tabS8).fps, 120)
        // never below 30
        XCTAssertEqual(P.clampToDecoder(.init(1920, 1080), fps: 60, decodeModes: [.init(width: 1920, height: 1080, maxFps: 24)]).fps, 30)
        XCTAssertEqual(P.clampToDecoder(.init(1920, 1080), fps: 20, decodeModes: [.init(width: 1920, height: 1080, maxFps: 24)]).fps, 20)
    }

    func testClampShrinksToLargestMode() {
        // 3840x2400 not covered (2400 > 2160) → 3840x2160@60: f = 0.9
        XCTAssertEqual(P.clampToDecoder(.init(3840, 2400), fps: 120, decodeModes: tabS8), .init(size: .init(3456, 2160), fps: 60, limitedByDecoder: true))
        // largest mode is < 30 fps → largest one with >= 30 fps
        let modes: [DecodeMode] = [.init(width: 3840, height: 2160, maxFps: 24), .init(width: 1920, height: 1080, maxFps: 60)]
        XCTAssertEqual(P.clampToDecoder(.init(3840, 2400), fps: 60, decodeModes: modes), .init(size: .init(1728, 1080), fps: 60, limitedByDecoder: true))
        // ...but a covering mode below 30 fps keeps the size at 30 fps (Windows: Math.Max(maxFps, 30))
        XCTAssertEqual(P.clampToDecoder(.init(2560, 1600), fps: 60, decodeModes: modes), .init(size: .init(2560, 1600), fps: 30, limitedByDecoder: false))
        // all < 30 fps → the largest, fps floor 30
        XCTAssertEqual(P.clampToDecoder(.init(2560, 1600), fps: 60, decodeModes: [.init(width: 1280, height: 720, maxFps: 15)]),
                       .init(size: .init(1152, 720), fps: 30, limitedByDecoder: true))
        // portrait box keeps orientation
        XCTAssertEqual(P.clampToDecoder(.init(2400, 3840), fps: 60, decodeModes: tabS8).size, .init(2160, 3456))
    }

    func testStreamTargetFromHello() {
        var hello = HelloMessage()
        hello.widthPx = 2560; hello.heightPx = 1600; hello.maxDecodeWidth = 3840; hello.maxDecodeHeight = 2160
        hello.decodeModes = [.init(width: 2560, height: 1600, maxFps: 60)]
        XCTAssertEqual(P.streamTarget(hello: hello, resolutionScale: 1, fps: 120, portrait: true),
                       .init(size: .init(1600, 2560), fps: 60, limitedByDecoder: false))
        XCTAssertEqual(P.streamTarget(hello: hello, resolutionScale: 0.5, fps: 30, portrait: false),
                       .init(size: .init(1280, 800), fps: 30, limitedByDecoder: false))
    }

    func testH264Profile() {
        XCTAssertEqual(P.h264Profile(for: nil), .high)
        XCTAssertEqual(P.h264Profile(for: []), .high)
        XCTAssertEqual(P.h264Profile(for: ["high", "main", "baseline"]), .high)
        XCTAssertEqual(P.h264Profile(for: ["HIGH"]), .high)
        XCTAssertEqual(P.h264Profile(for: ["main", "baseline"]), .main)
        XCTAssertEqual(P.h264Profile(for: ["baseline"]), .baseline)
        XCTAssertEqual(P.h264Profile(for: ["constrained-baseline"]), .baseline)
        XCTAssertEqual(P.H264Profile.main.rawValue, 77)
    }

    func testCodecChoice() {
        XCTAssertEqual(P.codec(requested: "h264", tabletCodecs: ["h264", "mjpeg"], forceMjpeg: false), "h264")
        XCTAssertEqual(P.codec(requested: "h264", tabletCodecs: nil, forceMjpeg: false), "h264")
        XCTAssertEqual(P.codec(requested: "h264", tabletCodecs: ["mjpeg"], forceMjpeg: false), "mjpeg")
        XCTAssertEqual(P.codec(requested: "h264", tabletCodecs: ["H264"], forceMjpeg: true), "mjpeg")
        XCTAssertEqual(P.codec(requested: "mjpeg", tabletCodecs: ["h264"], forceMjpeg: false), "mjpeg")
    }
}

// MARK: - Sanitize / failures

final class RequestPolicyTests: XCTestCase {
    func testSanitizeDefaultsMatchWindows() {
        let r = P.sanitize(RequestedSettings())
        XCTAssertEqual(r, .init(mode: "mirror", monitorIndex: 0, resolutionScale: 1.0, fps: 60, bitrateKbps: 20000,
                                quality: "balanced", codec: "h264", touchMode: "touch", position: "right",
                                scalePercent: 0, orientation: "landscape"))
    }

    func testSanitizeClamps() {
        var s = RequestedSettings(mode: " Primary ", monitorIndex: -3, resolutionScale: 0.1, fps: 500, bitrateKbps: 100,
                                  quality: "quality", codec: "MJPEG", touchMode: "MOUSE", position: "Left",
                                  scalePercent: 240, orientation: " Portrait ")
        var r = P.sanitize(s)
        XCTAssertEqual(r, .init(mode: "primary", monitorIndex: 0, resolutionScale: 0.25, fps: 120, bitrateKbps: 500,
                                quality: "quality", codec: "mjpeg", touchMode: "mouse", position: "left",
                                scalePercent: 250, orientation: "portrait"))
        XCTAssertTrue(r.isPortrait && r.isVirtualMode)
        s.resolutionScale = .infinity; s.fps = 0; s.bitrateKbps = 999_999; s.mode = "bogus"; s.touchMode = "pen"; s.position = nil
        r = P.sanitize(s)
        XCTAssertEqual(r.resolutionScale, 1.0)
        XCTAssertEqual(r.fps, 60)
        XCTAssertEqual(r.bitrateKbps, 200_000)
        XCTAssertEqual(r.mode, "mirror")
        XCTAssertEqual(r.touchMode, "touch")
        XCTAssertEqual(r.position, "right")
        s.fps = 2
        XCTAssertEqual(P.sanitize(s).fps, 5)
    }

    func testEffectiveMode() {
        XCTAssertEqual(P.effectiveMode(requested: "extend", extendBroken: false), "extend")
        XCTAssertEqual(P.effectiveMode(requested: "primary", extendBroken: false), "primary")
        XCTAssertEqual(P.effectiveMode(requested: "primary", extendBroken: true), "mirror")
        XCTAssertEqual(P.effectiveMode(requested: "mirror", extendBroken: false), "mirror")
    }

    func testPipelineFailureEscalation() {
        var st = P.FailureState()
        XCTAssertEqual(P.onPipelineEnded(reason: "resize", state: &st), .restart(after: 0.3))
        XCTAssertEqual(st.failures, 0)
        XCTAssertEqual(P.onPipelineEnded(reason: "encoder: boom", state: &st), .restart(after: 1.0))
        XCTAssertTrue(st.disallowHardware); XCTAssertFalse(st.forceMjpeg)
        _ = P.onPipelineEnded(reason: "error: x", state: &st)
        XCTAssertTrue(st.forceMjpeg)
        for _ in 3...6 { XCTAssertEqual(P.onPipelineEnded(reason: "error: x", state: &st), .restart(after: 1.0)) }
        XCTAssertEqual(P.onPipelineEnded(reason: "error: x", state: &st), .disconnect)

        var st2 = P.FailureState()
        XCTAssertEqual(P.onStreamStartFailed(mode: "extend", state: &st2), .restart(after: 1.0))
        XCTAssertTrue(st2.extendBroken)
    }
}

// MARK: - Link classification (vectors from AdbParserTests in AppLogicTests.cs)

final class LinkTests: XCTestCase {
    func testReverseLinkTellsCableFromWirelessDebugging() {
        XCTAssertEqual(P.reverseLink(reverseListOutput: "UsbFfs tcp:47800 tcp:47800\n", port: 47800), .usbCable)
        XCTAssertEqual(P.reverseLink(reverseListOutput: "host-22 tcp:8081 tcp:8081\r\nhost-22 tcp:47800 tcp:47800\r\n", port: 47800), .usbWirelessAdb)
        XCTAssertNil(P.reverseLink(reverseListOutput: "host-22 tcp:8081 tcp:8081\n", port: 47800))
        XCTAssertNil(P.reverseLink(reverseListOutput: "", port: 47800))
        XCTAssertNil(P.reverseLink(reverseListOutput: "weird tcp:47800 tcp:47800\n"))
        XCTAssertEqual(P.reverseLink(reverseListOutput: "UsbFfs tcp:47800 tcp:47800"), .usbCable) // default port
    }

    func testWirelessSerials() {
        XCTAssertFalse(P.isWirelessAdbSerial("R52T70ABCDE"))
        XCTAssertTrue(P.isWirelessAdbSerial("adb-R52T70ABCDE-Xy1Z2a._adb-tls-connect._tcp"))
        XCTAssertTrue(P.isWirelessAdbSerial("192.168.1.44:5555"))
        XCTAssertTrue(P.isWirelessAdbSerial("adb-X._adb._tcp"))
        XCTAssertFalse(P.isWirelessAdbSerial("0123456789ABCDEF"))
        XCTAssertEqual(P.physicalAdbSerial("adb-R52T70ABCDE-Xy1Z2a._adb-tls-connect._tcp"), "R52T70ABCDE")
        XCTAssertEqual(P.physicalAdbSerial("R52T70ABCDE"), "R52T70ABCDE")
        XCTAssertNil(P.physicalAdbSerial("192.168.1.44:5555"))
    }

    func testAdbLinkCandidates() {
        let devs: [P.AdbDeviceInfo] = [
            .init(serial: "adb-R52T70ABCDE-Xy1Z2a._adb-tls-connect._tcp", state: "device", model: "SM X700"),
            .init(serial: "R52T70ABCDE", state: "device", model: "SM_X700"),
            .init(serial: "OTHER1", state: "device", model: "Pixel 7"),
            .init(serial: "192.168.1.44:5555", state: "offline", model: "SM X700"),
        ]
        XCTAssertEqual(P.adbLinkCandidates(devs, helloModel: "SM-X700"), ["R52T70ABCDE", "adb-R52T70ABCDE-Xy1Z2a._adb-tls-connect._tcp"])
        XCTAssertEqual(P.adbLinkCandidates(devs, helloModel: "Unknown"), [])
        XCTAssertEqual(P.adbLinkCandidates([devs[2]], helloModel: "Unknown"), ["OTHER1"]) // only ready device
        XCTAssertEqual(P.adbLinkCandidates([devs[3]], helloModel: "SM-X700"), [])
    }

    func testLoopback() {
        for s in ["127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1", "[::1]:52344", "127.0.0.1:5000", "::1%lo0"] {
            XCTAssertTrue(P.isLoopback(s), s)
        }
        for s in ["192.168.1.20", "::ffff:192.168.1.20", "fe80::1%en0", "128.0.0.1", "127.0.0", ""] {
            XCTAssertFalse(P.isLoopback(s), s)
        }
    }

    func testNetworkLink() {
        XCTAssertEqual(P.networkLink(localAddress: "192.168.1.10", interfaceName: "en0", interfaceDisplayName: "Wi-Fi"), .wifi)
        XCTAssertEqual(P.networkLink(localAddress: "10.0.0.5", interfaceName: "en7", interfaceDisplayName: "SAMSUNG Android"), .usbTether)
        XCTAssertEqual(P.networkLink(localAddress: "10.0.0.5", interfaceName: "en7", interfaceDisplayName: "Remote NDIS based Internet Sharing Device"), .usbTether)
        XCTAssertEqual(P.networkLink(localAddress: "192.168.42.100", interfaceName: "en8", interfaceDisplayName: nil), .usbTether)
        XCTAssertEqual(P.networkLink(localAddress: nil, interfaceName: nil, interfaceDisplayName: nil), .wifi)
    }

    func testClassifyLink() {
        XCTAssertEqual(P.classifyLink(remoteAddress: "127.0.0.1", localAddress: "127.0.0.1", interfaceName: "lo0", interfaceDisplayName: nil,
                                      reverseListOutputs: ["", "UsbFfs tcp:47800 tcp:47800\n"]), .usbCable)
        XCTAssertNil(P.classifyLink(remoteAddress: "::1", localAddress: nil, interfaceName: nil, interfaceDisplayName: nil, reverseListOutputs: []))
        XCTAssertEqual(P.classifyLink(remoteAddress: "192.168.1.50", localAddress: "192.168.1.10", interfaceName: "en0",
                                      interfaceDisplayName: "Wi-Fi", reverseListOutputs: ["UsbFfs tcp:47800 tcp:47800"]), .wifi)
        XCTAssertEqual(P.Link.usbWirelessAdb.rawValue, "usb-wireless-adb")
    }
}
