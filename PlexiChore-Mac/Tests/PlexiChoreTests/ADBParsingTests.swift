import XCTest
@testable import PlexiChore

/// Pure adb output parsing / decisions (USB/ADBParsing.swift + ADBEngine.statusText). Vectors from the
/// ADBParsing author's harness. No adb process is started.
final class ADBParsingTests: XCTestCase {
    typealias A = ADBParsing

    static let devOut = """
    * daemon not running; starting now at tcp:5037
    * daemon started successfully
    List of devices attached
    R52T30ALNWJ            device usb:17825792X product:gts8wifixx model:SM_X700 device:gts8wifi transport_id:1
    adb-R52T30ALNWJ-a1B2c3._adb-tls-connect._tcp device product:gts8wifixx model:SM_X700 device:gts8wifi transport_id:3
    192.168.1.50:5555      offline transport_id:4
    ZY22ABCDEF             unauthorized usb:1-1 transport_id:5
    XYZ123 no permissions (user in plugdev group; are your udev rules wrong?); see [http://developer.android.com/tools/device.html] usb:1-4 transport_id:6

    """

    var d: [A.DeviceLine] { A.parseDevices(Self.devOut) }

    func testParseDevicesLong() {
        let d = self.d
        XCTAssertEqual(d.count, 5)
        XCTAssertEqual(d[0].serial, "R52T30ALNWJ")
        XCTAssertTrue(d[0].isReady)
        XCTAssertEqual(d[0].model, "SM X700")
        XCTAssertEqual(d[0].transportId, "1")
        XCTAssertFalse(d[0].isWireless)
        XCTAssertTrue(d[1].isWireless && d[1].isReady)
        XCTAssertEqual(A.hardwareSerial(d[1].serial), "R52T30ALNWJ")
        XCTAssertTrue(d[2].isWireless)
        XCTAssertEqual(d[2].state, "offline")
        XCTAssertNil(A.hardwareSerial(d[2].serial))
        XCTAssertEqual(A.stateKind(d[3].state), .unauthorized)
    }

    func testMultiWordNoPermissionsState() {
        let np = d[4]
        XCTAssertEqual(np.state, "no permissions")
        XCTAssertEqual(np.props["usb"], "1-4")
        XCTAssertEqual(np.props["transport_id"], "6")
        XCTAssertEqual(np.props.count, 2)   // the "[http://…]" hint is ignored
    }

    func testServerVersionKillAndTabSeparated() {
        XCTAssertTrue(A.parseDevices("adb server version (40) doesn't match this client (41); killing...\nList of devices attached\n").isEmpty)
        XCTAssertEqual(A.parseDevices("R1\tdevice\nR2\toffline\n").map(\.state), ["device", "offline"])
        XCTAssertTrue(A.parseDevices("").isEmpty)
    }

    func testGroupByTablet() {
        let g = A.groupByTablet(d)
        XCTAssertEqual(g.count, 4)
        XCTAssertEqual(g[0].primary.serial, "R52T30ALNWJ")
        XCTAssertEqual(g[0].twins.map(\.serial), ["adb-R52T30ALNWJ-a1B2c3._adb-tls-connect._tcp"])
        // cable unauthorized, wireless ready → wireless is primary
        let g2 = A.groupByTablet(A.parseDevices("R5 unauthorized usb:1\nadb-R5-xx._adb-tls-connect._tcp device model:A\n"))
        XCTAssertEqual(g2.count, 1)
        XCTAssertTrue(g2[0].primary.serial.hasPrefix("adb-R5"))
        // ip:port twin resolved via get-serialno (case-insensitive)
        let g3 = A.groupByTablet(A.parseDevices("10.0.0.2:5555 device\nR5 device usb:1\n"), resolved: ["10.0.0.2:5555": "r5"])
        XCTAssertEqual(g3.count, 1)
        XCTAssertEqual(g3.first?.primary.serial, "R5")
    }

    func testReversePlan() {
        let p = A.reversePlan(d)
        XCTAssertEqual(p.targets, ["R52T30ALNWJ"])
        XCTAssertEqual(p.cableTwinned, ["adb-R52T30ALNWJ-a1B2c3._adb-tls-connect._tcp"])
        let p2 = A.reversePlan(A.parseDevices("A1 device usb:1\n10.0.0.9:5555 device\nadb-B2-q._adb-tls-connect._tcp device\n"))
        XCTAssertEqual(p2.targets, ["10.0.0.9:5555", "adb-B2-q._adb-tls-connect._tcp", "A1"])   // wireless first, cables last
        XCTAssertTrue(p2.cableTwinned.isEmpty)
    }

    func testReverseList() {
        let rl = "UsbFfs tcp:47800 tcp:47800\nhost-19 tcp:8080 tcp:9090\n"
        XCTAssertTrue(A.hasReverse(rl))
        XCTAssertEqual(A.reverseLink(rl), .usbCable)
        XCTAssertEqual(A.reverseLink("host-19 tcp:47800 tcp:47800\n"), .usbWirelessAdb)
        XCTAssertFalse(A.hasReverse(""))
        XCTAssertNil(A.reverseLink(""))
        XCTAssertFalse(A.hasReverse("UsbFfs tcp:47800 tcp:47801"))
        XCTAssertEqual(A.parseReverseList(rl), [.init(owner: "UsbFfs", remote: "tcp:47800", local: "tcp:47800"),
                                                .init(owner: "host-19", remote: "tcp:8080", local: "tcp:9090")])
        // a cable only "holds" the reverse while it owns the listener; a wireless twin owning it means re-apply on the cable
        let wifiOwned = "host-25 tcp:47800 tcp:47800\n"
        XCTAssertTrue(A.reverseHeld(rl, wireless: false))
        XCTAssertFalse(A.reverseHeld(wifiOwned, wireless: false))
        XCTAssertTrue(A.reverseHeld(wifiOwned, wireless: true))
        XCTAssertTrue(A.reverseHeld(rl, wireless: true))
        XCTAssertFalse(A.reverseHeld("", wireless: true))
        // agrees with SessionPolicy (CONFIG link and the USB page must match)
        XCTAssertEqual(A.reverseLink(rl), SessionPolicy.reverseLink(reverseListOutput: rl))
    }

    func testVersions() {
        let v = A.parseClientVersion("Android Debug Bridge version 1.0.41\nVersion 37.0.1-15733141\nInstalled as /x/adb\n")
        XCTAssertEqual(v, .init(protocolVersion: 41, release: "37.0.1-15733141"))
        XCTAssertNil(A.parseClientVersion("garbage"))
        XCTAssertEqual(A.parseServerVersionReply("OKAY00040029"), 41)
        XCTAssertNil(A.parseServerVersionReply("FAIL0004nope"))
        XCTAssertNil(A.parseServerVersionReply("OKAY0004"))
    }

    func testTrackFrames() {
        var buf = Array("0013R52T30ALNWJ\tdevice\n0000001".utf8)
        let (fr, bad) = A.takeTrackFrames(&buf)
        XCTAssertEqual(fr, ["R52T30ALNWJ\tdevice\n", ""])
        XCTAssertFalse(bad)
        XCTAssertEqual(buf, Array("001".utf8))   // partial header kept
        var junk = Array("zzzzabc".utf8)
        let (f2, b2) = A.takeTrackFrames(&junk)
        XCTAssertTrue(f2.isEmpty)
        XCTAssertTrue(b2)
        XCTAssertTrue(junk.isEmpty)
    }

    func testBackoffSerialAndMessages() {
        XCTAssertEqual(A.backoff(failures: 0, base: 1, cap: 30), 0)
        XCTAssertEqual(A.backoff(failures: 1, base: 1, cap: 30), 1)
        XCTAssertEqual(A.backoff(failures: 4, base: 1, cap: 30), 8)
        XCTAssertEqual(A.backoff(failures: 99, base: 1, cap: 30), 30)
        XCTAssertEqual(A.parseSerialNo("R52T30ALNWJ\n"), "R52T30ALNWJ")
        XCTAssertNil(A.parseSerialNo("unknown\n"))
        XCTAssertNil(A.parseSerialNo(""))
        XCTAssertTrue(A.reportsServerVersionKill("adb server version (40) doesn't match this client (41); killing..."))
        XCTAssertEqual(A.firstMessageLine("* daemon x\nerror: device offline\n"), "error: device offline")
    }

    func testEngineStatusText() {
        XCTAssertEqual(ADBEngine.statusText(lines: d, resolved: [:], reversed: [:], failures: [:]),
                       "Allow USB debugging on the tablet (check its screen).")
        let only = A.parseDevices("R5 device usb:1\nadb-R5-x._adb-tls-connect._tcp device\n")
        XCTAssertEqual(ADBEngine.statusText(lines: only, resolved: [:], reversed: ["R5": Date()], failures: [:]),
                       "1 device ready over USB")
    }

    func testManagerDeviceMapping() {
        let devs = ADBManager.parseDevices(Self.devOut)
        XCTAssertEqual(devs[1].transport, .wirelessDebugging)
        XCTAssertEqual(devs[1].hardwareSerial, "R52T30ALNWJ")
        XCTAssertEqual(devs[0].link, .usbCable)
    }
}
