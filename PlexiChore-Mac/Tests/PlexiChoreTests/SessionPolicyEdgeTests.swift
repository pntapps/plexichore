import XCTest
@testable import PlexiChore

/// Edge cases of SessionPolicy beyond the Windows-ported vectors in SessionPolicyTests.swift.
final class SessionPolicyEdgeTests: XCTestCase {
    typealias P = SessionPolicy

    // MARK: Portrait

    func testPortraitStreamTargetsForCommonTablets() {
        let tablets: [(Int, Int, P.Size)] = [
            (2560, 1600, .init(1600, 2560)),   // Tab S8
            (1600, 2560, .init(1600, 2560)),   // reported already rotated
            (2800, 1752, .init(1752, 2800)),   // Tab S8+
            (1920, 1200, .init(1200, 1920)),
        ]
        for (w, h, expected) in tablets {
            var hello = HelloMessage()
            hello.widthPx = w; hello.heightPx = h
            let t = P.streamTarget(hello: hello, resolutionScale: 1, fps: 60, portrait: true)
            XCTAssertEqual(t.size, expected, "\(w)x\(h)")
            XCTAssertGreaterThan(t.size.height, t.size.width)
            let l = P.streamTarget(hello: hello, resolutionScale: 1, fps: 60, portrait: false)
            XCTAssertEqual(l.size, .init(expected.height, expected.width))
        }
    }

    func testPortraitOnlyFromExactValue() {
        for o in ["portrait", "PORTRAIT", "  Portrait\n"] {
            XCTAssertTrue(P.sanitize(RequestedSettings(orientation: o)).isPortrait, o)
        }
        for o in ["landscape", "", "reverse-portrait", "portrait-ish"] {
            XCTAssertFalse(P.sanitize(RequestedSettings(orientation: o)).isPortrait, o)
        }
        XCTAssertFalse(P.sanitize(RequestedSettings()).isPortrait)
    }

    func testOrientationChangeIsNotScaleOnly() {
        let a = P.sanitize(RequestedSettings.defaults)
        var b = a; b.orientation = "portrait"
        XCTAssertFalse(P.isScaleOnlyChange(a, b))
        var c = b; c.scalePercent = 150
        XCTAssertFalse(P.isScaleOnlyChange(a, c))   // scale + orientation → full re-attach
        var d = a; d.scalePercent = 150
        XCTAssertTrue(P.isScaleOnlyChange(a, d))
    }

    func testPortraitDecodeClampUsesRotatedModes() {
        // decoder lists only landscape 1920x1080 → portrait 1600x2560 box is shrunk keeping portrait
        let t = P.clampToDecoder(.init(1600, 2560), fps: 60, decodeModes: [.init(width: 1920, height: 1080, maxFps: 60)])
        XCTAssertTrue(t.limitedByDecoder)
        XCTAssertEqual(t.size, .init(1080, 1728))
        XCTAssertGreaterThan(t.size.height, t.size.width)
    }

    // MARK: Decoder clamp

    func testClampPicksBestCoveringModeFps() {
        // two modes both cover: the higher fps wins even when it is not the first listed
        let modes: [DecodeMode] = [.init(width: 3840, height: 2160, maxFps: 60), .init(width: 2560, height: 1600, maxFps: 120)]
        XCTAssertEqual(P.clampToDecoder(.init(1920, 1200), fps: 120, decodeModes: modes).fps, 120)
        XCTAssertEqual(P.clampToDecoder(.init(1920, 1200), fps: 90, decodeModes: modes).fps, 90)   // never raises fps
    }

    func testClampExactEdgeIsCovered() {
        let m: [DecodeMode] = [.init(width: 2560, height: 1600, maxFps: 60)]
        XCTAssertEqual(P.clampToDecoder(.init(2560, 1600), fps: 60, decodeModes: m), .init(size: .init(2560, 1600), fps: 60, limitedByDecoder: false))
        let over = P.clampToDecoder(.init(2562, 1600), fps: 60, decodeModes: m)
        XCTAssertTrue(over.limitedByDecoder)
        XCTAssertLessThanOrEqual(over.size.longEdge, 2560); XCTAssertLessThanOrEqual(over.size.shortEdge, 1600)
    }

    func testClampIgnoresInvalidModes() {
        let modes: [DecodeMode] = [.init(width: 0, height: 2160, maxFps: 60), .init(width: 3840, height: 2160, maxFps: 0),
                                   .init(width: -1, height: -1, maxFps: 60), .init(width: 1280, height: 720, maxFps: 60)]
        let t = P.clampToDecoder(.init(2560, 1600), fps: 60, decodeModes: modes)
        XCTAssertEqual(t.size, .init(1152, 720))
        XCTAssertTrue(t.limitedByDecoder)
    }

    func testClampResultsAreAlwaysEvenAndFitTheChosenMode() {
        let modes: [DecodeMode] = [.init(width: 1366, height: 768, maxFps: 60), .init(width: 1001, height: 601, maxFps: 30)]
        for (w, h) in [(2560, 1600), (2800, 1752), (1600, 2560), (3000, 2000), (2222, 1111)] {
            let t = P.clampToDecoder(.init(w, h), fps: 120, decodeModes: modes)
            XCTAssertEqual(t.size.width % 2, 0); XCTAssertEqual(t.size.height % 2, 0)
            XCTAssertLessThanOrEqual(t.size.longEdge, 1366, "\(w)x\(h) → \(t.size)")
            XCTAssertLessThanOrEqual(t.size.shortEdge, 768, "\(w)x\(h) → \(t.size)")
            XCTAssertEqual(t.fps, 60)
            // the result must itself be decodable: clamping again is a no-op
            XCTAssertEqual(P.clampToDecoder(t.size, fps: t.fps, decodeModes: modes).size, t.size)
        }
    }

    func testClampEqualAreaTieKeepsFirstListed() {
        let modes: [DecodeMode] = [.init(width: 1600, height: 900, maxFps: 60), .init(width: 1800, height: 800, maxFps: 60)]
        // equal area 1_440_000: first listed (1600x900) wins → f = min(1600/2560, 900/1600) = 0.5625
        XCTAssertEqual(P.clampToDecoder(.init(2560, 1600), fps: 60, decodeModes: modes).size, .init(1440, 900))
    }

    func testStreamTargetFallbacksWithoutHelloSizes() {
        let t = P.streamTarget(hello: HelloMessage(), resolutionScale: 1, fps: 60, portrait: false)
        XCTAssertEqual(t, .init(size: .init(1920, 1080), fps: 60, limitedByDecoder: false))
        var h = HelloMessage(); h.widthPx = 7680; h.heightPx = 4320   // 8K panel, no max → clamped to 3840x2160
        XCTAssertEqual(P.streamTarget(hello: h, resolutionScale: 1, fps: 60, portrait: false).size, .init(3840, 2160))
    }

    func testResolutionScaleClampFeedsBox() {
        let r = P.sanitize(RequestedSettings(resolutionScale: 0.1))
        XCTAssertEqual(r.resolutionScale, 0.25)
        XCTAssertEqual(P.tabletBox(widthPx: 2560, heightPx: 1600, maxDecodeWidth: nil, maxDecodeHeight: nil, scale: r.resolutionScale), .init(640, 400))
        XCTAssertEqual(P.sanitize(RequestedSettings(resolutionScale: 1.7)).resolutionScale, 1.0)
        XCTAssertEqual(P.sanitize(RequestedSettings(resolutionScale: -.infinity)).resolutionScale, 1.0)
        XCTAssertEqual(P.sanitize(RequestedSettings(resolutionScale: .nan)).resolutionScale, 1.0)
    }

    // MARK: Profiles

    func testProfileSelectionOrderAndCase() {
        XCTAssertEqual(P.h264Profile(for: ["baseline", "main"]), .main)         // order doesn't matter
        XCTAssertEqual(P.h264Profile(for: ["baseline", "high"]), .high)
        XCTAssertEqual(P.h264Profile(for: ["Main"]), .main)
        XCTAssertEqual(P.h264Profile(for: ["high10", "high422"]), .baseline)    // only exact "high" counts
        XCTAssertEqual(P.h264Profile(for: [""]), .baseline)
        XCTAssertEqual(P.H264Profile.baseline.rawValue, 66)
        XCTAssertEqual(P.H264Profile.high.rawValue, 100)
    }

    func testCodecChoiceEdgeCases() {
        XCTAssertEqual(P.codec(requested: "h264", tabletCodecs: [], forceMjpeg: false), "h264")       // empty = unknown
        XCTAssertEqual(P.codec(requested: "h264", tabletCodecs: ["hevc", "mjpeg"], forceMjpeg: false), "mjpeg")
        XCTAssertEqual(P.codec(requested: "anything", tabletCodecs: ["h264"], forceMjpeg: false), "h264")
        XCTAssertEqual(P.sanitize(RequestedSettings(codec: "hevc")).codec, "h264")
    }

    // MARK: scalePercent

    func testSanitizeScaleTiesGoLower() {
        // midpoints between steps go to the smaller step (DisplayScale.Nearest)
        XCTAssertEqual(P.sanitizeScaleRequest(112), 100)
        XCTAssertEqual(P.sanitizeScaleRequest(137), 125)
        XCTAssertEqual(P.sanitizeScaleRequest(138), 150)
        XCTAssertEqual(P.sanitizeScaleRequest(162), 150)
        XCTAssertEqual(P.sanitizeScaleRequest(163), 175)
        XCTAssertEqual(P.sanitizeScaleRequest(275), 250)     // 250..300 midpoint
        XCTAssertEqual(P.sanitizeScaleRequest(276), 300)
        XCTAssertEqual(P.sanitizeScaleRequest(1), 100)
        XCTAssertEqual(P.sanitizeScaleRequest(999_999_999_999_999), 300)   // largest value lenient JSON yields (< 1e15); Int.max loses precision in nearestStep → 100 (unreachable over the wire)
        XCTAssertEqual(P.sanitizeScaleRequest(Int.min), 0)
        for s in P.requestableScales { XCTAssertEqual(P.sanitizeScaleRequest(s), s) }
    }

    func testAutoScaleIsMonotonicInDensity() {
        var last = 0
        for dpi in stride(from: 120, through: 640, by: 10) {
            let s = P.autoScalePercent(densityDpi: dpi)
            XCTAssertGreaterThanOrEqual(s, last, "dpi \(dpi)")
            XCTAssertTrue((P.autoScaleMin...P.autoScaleMax).contains(s))
            last = s
        }
    }

    func testAutoScale100OnlyWhenDownscaled() {
        XCTAssertEqual(P.autoScalePercent(densityDpi: 160, pixelRatio: 1.0), 125)
        XCTAssertEqual(P.autoScalePercent(densityDpi: 160, pixelRatio: 1.15), 125)   // threshold is strictly > 1.15
        XCTAssertEqual(P.autoScalePercent(densityDpi: 160, pixelRatio: 1.16), 100)
        XCTAssertEqual(P.autoScalePercent(densityDpi: 320, pixelRatio: .infinity), 200)
        XCTAssertEqual(P.autoScalePercent(densityDpi: -1, shortEdgePx: 1500), 200)    // unknown density guess
        XCTAssertEqual(P.autoScalePercent(densityDpi: 0, shortEdgePx: 1499), 150)
    }

    func testScaleEndToEndForDownscaledStream() {
        var h = HelloMessage(); h.widthPx = 2560; h.heightPx = 1600; h.densityDpi = 320
        let t = P.streamTarget(hello: h, resolutionScale: 0.75, fps: 60, portrait: false)
        XCTAssertEqual(t.size, .init(1920, 1200))
        let pct = P.targetScalePercent(hello: h, requested: 0, streamSize: t.size)
        XCTAssertEqual(pct, 150)    // 200 / (2560/1920)
        let mode = P.virtualDisplayMode(stream: t.size, scalePercent: pct)
        XCTAssertEqual(mode.points, .init(1280, 800))
        XCTAssertEqual(mode.backing, .init(2560, 1600))
        XCTAssertTrue(mode.needsResample)
        XCTAssertEqual(P.configScalePercent(mode: "extend", applied: mode, actualHiDPI: true), 150)
    }

    func testVirtualDisplayModeTinyStreamFallsBackToNative() {
        // points short edge < 32 → native snap
        let m = P.virtualDisplayMode(stream: .init(80, 60), scalePercent: 250)
        XCTAssertEqual(m.scalePercent, 200)
        XCTAssertEqual(m.backing, .init(80, 60))
    }

    func testVirtualDisplayModeIsOrientationSymmetric() {
        for pct in P.requestableScales {
            let l = P.virtualDisplayMode(stream: .init(2560, 1600), scalePercent: pct)
            let p = P.virtualDisplayMode(stream: .init(1600, 2560), scalePercent: pct)
            XCTAssertEqual(l.scalePercent, p.scalePercent, "\(pct)")
            XCTAssertEqual(l.points, .init(p.points.height, p.points.width), "\(pct)")
            XCTAssertEqual(l.hiDPI, p.hiDPI)
        }
    }

    func testConfigScalePercentFallbackFor1xRetry() {
        // a scaled 150% HiDPI mode the shim had to create at 1x: report stream/backing (2560/3414 → 75 → 100)
        let m150 = P.virtualDisplayMode(stream: .init(2560, 1600), scalePercent: 150)
        XCTAssertEqual(P.configScalePercent(mode: "extend", applied: m150, actualHiDPI: false), 100)
        // 300% has backing smaller than the stream: 2560/1706 = 150
        let m300 = P.virtualDisplayMode(stream: .init(2560, 1600), scalePercent: 300)
        XCTAssertEqual(P.configScalePercent(mode: "primary", applied: m300, actualHiDPI: false), 150)
        XCTAssertEqual(P.configScalePercent(mode: "mirror", applied: nil), 0)
    }

    // MARK: Link classification

    func testReverseLinkParsingVariants() {
        XCTAssertEqual(P.reverseLink(reverseListOutput: "  UsbFfs\ttcp:47800 tcp:47800  \n"), .usbCable)
        XCTAssertEqual(P.reverseLink(reverseListOutput: "usb:1-1 tcp:47800 tcp:47800"), .usbCable)
        XCTAssertEqual(P.reverseLink(reverseListOutput: "HOST-3 TCP:47800 TCP:47800"), .usbWirelessAdb)
        // another port's rule must not match
        XCTAssertNil(P.reverseLink(reverseListOutput: "UsbFfs tcp:47801 tcp:47801\nUsbFfs tcp:147800 tcp:47800"))
        // custom port
        XCTAssertEqual(P.reverseLink(reverseListOutput: "host-1 tcp:5000 tcp:5000", port: 5000), .usbWirelessAdb)
        // first matching line decides
        XCTAssertEqual(P.reverseLink(reverseListOutput: "host-1 tcp:47800 tcp:47800\nUsbFfs tcp:47800 tcp:47800"), .usbWirelessAdb)
    }

    func testReverseLinkDoesNotMatchDifferentLocalPort() {
        // a rule for device port 147800 must not be mistaken for ours
        XCTAssertNil(P.reverseLink(reverseListOutput: "UsbFfs tcp:47800 tcp:147800"))
    }

    func testLoopbackEdgeCases() {
        XCTAssertTrue(P.isLoopback(" 127.0.0.1 "))
        XCTAssertTrue(P.isLoopback("0:0:0:0:0:0:0:1"))
        XCTAssertTrue(P.isLoopback("::FFFF:127.0.0.1"))
        XCTAssertTrue(P.isLoopback("127.255.255.255"))
        XCTAssertFalse(P.isLoopback("127.0.0.256"))
        XCTAssertFalse(P.isLoopback("localhost"))      // host names are not resolved
        XCTAssertFalse(P.isLoopback("::2"))
        XCTAssertFalse(P.isLoopback("10.0.0.1:47800"))
    }

    func testNetworkLinkMatchesCaseInsensitive() {
        XCTAssertEqual(P.networkLink(localAddress: nil, interfaceName: "en9", interfaceDisplayName: "usb 10/100 lan"), .usbTether)
        XCTAssertEqual(P.networkLink(localAddress: nil, interfaceName: "en9", interfaceDisplayName: "CDC NCM"), .usbTether)
        XCTAssertEqual(P.networkLink(localAddress: "::ffff:192.168.42.7", interfaceName: "en0", interfaceDisplayName: "Wi-Fi"), .usbTether)
        XCTAssertEqual(P.networkLink(localAddress: "192.168.4.2", interfaceName: "en0", interfaceDisplayName: "Wi-Fi"), .wifi)
        XCTAssertEqual(P.networkLink(localAddress: "192.168.420.1", interfaceName: "en0", interfaceDisplayName: nil), .wifi)
    }

    func testClassifyLoopbackPicksFirstKnownAnswer() {
        XCTAssertEqual(P.classifyLink(remoteAddress: "127.0.0.1", localAddress: nil, interfaceName: nil, interfaceDisplayName: nil,
                                      reverseListOutputs: ["", "host-5 tcp:47800 tcp:47800", "UsbFfs tcp:47800 tcp:47800"]), .usbWirelessAdb)
        // loopback never classifies as wifi/tether even on a USB interface name
        XCTAssertNil(P.classifyLink(remoteAddress: "127.0.0.1", localAddress: "127.0.0.1", interfaceName: "USB",
                                    interfaceDisplayName: "USB", reverseListOutputs: []))
    }

    func testAdbCandidatesModelNormalisation() {
        let devs: [P.AdbDeviceInfo] = [
            .init(serial: "R1", state: "device", model: "sm_x700"),
            .init(serial: "R2", state: "unauthorized", model: "SM-X700"),
            .init(serial: "R3", state: "device", model: nil),
        ]
        XCTAssertEqual(P.adbLinkCandidates(devs, helloModel: "SM-X700"), ["R1"])
        XCTAssertEqual(P.adbLinkCandidates(devs, helloModel: nil), ["R3"])   // nil model == nil model
        XCTAssertEqual(P.adbLinkCandidates([], helloModel: "SM-X700"), [])
    }

    func testPhysicalSerialOfMdnsName() {
        XCTAssertEqual(P.physicalAdbSerial("adb-R5CT-123-AbC12._adb-tls-connect._tcp"), "R5CT-123")   // serial with '-'
        XCTAssertTrue(P.isWirelessAdbSerial("[fe80::1]:5555"))
        XCTAssertFalse(P.isWirelessAdbSerial("emulator-5554"))   // emulator serials are local
    }

    // MARK: Encoder fallback / failures

    func testEncoderFallbackLadder() {
        var st = P.FailureState()
        XCTAssertEqual(P.onPipelineEnded(reason: "capture stopped", state: &st), .restart(after: 1.0))
        XCTAssertEqual(st, P.FailureState())                           // neutral reason doesn't escalate
        _ = P.onPipelineEnded(reason: "encoder: VT -12902", state: &st)
        XCTAssertEqual(st, .init(failures: 1, disallowHardware: true, forceMjpeg: false, extendBroken: false))
        // with hardware disallowed the codec choice is still h264 until the 2nd failure
        XCTAssertEqual(P.codec(requested: "h264", tabletCodecs: ["h264", "mjpeg"], forceMjpeg: st.forceMjpeg), "h264")
        _ = P.onPipelineEnded(reason: "encoder: software failed", state: &st)
        XCTAssertTrue(st.forceMjpeg)
        XCTAssertEqual(P.codec(requested: "h264", tabletCodecs: ["h264", "mjpeg"], forceMjpeg: st.forceMjpeg), "mjpeg")
        XCTAssertEqual(P.onPipelineEnded(reason: "resize", state: &st), .restart(after: 0.3))
        XCTAssertEqual(st.failures, 2)
    }

    func testReasonPrefixIsCaseSensitive() {
        var st = P.FailureState()
        _ = P.onPipelineEnded(reason: "Encoder: x", state: &st)
        _ = P.onPipelineEnded(reason: " error: x", state: &st)
        XCTAssertEqual(st.failures, 0)
    }

    func testStreamStartFailuresMirrorThenDisconnect() {
        var st = P.FailureState()
        XCTAssertEqual(P.onStreamStartFailed(mode: "primary", state: &st), .restart(after: 1.0))
        XCTAssertTrue(st.extendBroken)
        XCTAssertEqual(P.effectiveMode(requested: "primary", extendBroken: st.extendBroken), "mirror")
        for _ in 2...6 { XCTAssertEqual(P.onStreamStartFailed(mode: "mirror", state: &st), .restart(after: 1.0)) }
        XCTAssertEqual(P.onStreamStartFailed(mode: "mirror", state: &st), .disconnect)
    }

    func testTimingConstants() {
        XCTAssertEqual(P.deadAfter, 5)          // PROTOCOL.md: 5 s without any message = dead
        XCTAssertEqual(P.pairingTimeout, 120)   // auto-reject after 2 min
        XCTAssertLessThan(P.selfStallThreshold, P.deadAfter)
    }

    func testEvenNeverBelowTwo() {
        XCTAssertEqual(P.even(0), 2)
        XCTAssertEqual(P.even(-100), 2)
        XCTAssertEqual(P.even(1.0), 2)
        XCTAssertEqual(P.even(3840.0), 3840)
        XCTAssertEqual(P.even(1919.5), 1920)
    }
}

// MARK: - Pre-HELLO connections (USB loopback probe) are log-only, like Windows

final class PreHelloConnectionTests: XCTestCase {
    func testProbeClosingBeforeHelloProducesNoMessage() {
        // Android HostDiscovery.probeUsb: connect 127.0.0.1:47800, send nothing, close.
        XCTAssertFalse(SessionPolicy.isVisibleSession(helloReceived: false))
        XCTAssertNil(SessionPolicy.disconnectMessage(deviceName: nil, remote: "127.0.0.1:52992",
                                                     reason: "Tablet disconnected", helloReceived: false))
        XCTAssertNil(SessionPolicy.disconnectMessage(deviceName: nil, remote: "192.168.1.20:40000",
                                                     reason: "expected HELLO", helloReceived: false))
    }

    func testRealSessionStillReportsItsDisconnect() {
        XCTAssertTrue(SessionPolicy.isVisibleSession(helloReceived: true))
        XCTAssertEqual(SessionPolicy.disconnectMessage(deviceName: "Galaxy Tab S8", remote: "127.0.0.1:52992",
                                                       reason: "Tablet disconnected", helloReceived: true),
                       "Galaxy Tab S8 disconnected: Tablet disconnected")
        XCTAssertEqual(SessionPolicy.disconnectMessage(deviceName: "", remote: "127.0.0.1:52992",
                                                       reason: "Tablet disconnected", helloReceived: true),
                       "127.0.0.1:52992 disconnected: Tablet disconnected")
    }
}
