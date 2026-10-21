import Network
import XCTest
@testable import PlexiChore

/// ClientSession's real receive path (header/payload reassembly, PING→PONG, BYE, unknown types, oversize
/// rejection) over a loopback TCP connection on an ephemeral port (never 47800). The test plays the tablet on
/// the accepted socket; ClientSession wraps the outgoing connection, exactly as it would wrap an accepted one.
final class ClientSessionFramingTests: XCTestCase {

    /// The "tablet" end: raw bytes in, framed messages out.
    final class Peer: @unchecked Sendable {
        let conn: NWConnection
        private let lock = NSLock()
        private var buffer = Data()
        private var _frames: [(UInt8, Data)] = []
        var frames: [(UInt8, Data)] { lock.lock(); defer { lock.unlock() }; return _frames }
        private(set) var eof = false
        var onFrame: ((UInt8, Data) -> Void)?

        init(_ c: NWConnection) { conn = c }

        func start(queue: DispatchQueue) {
            conn.start(queue: queue)
            receive()
        }

        private func receive() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, error in
                guard let self else { return }
                if let data { self.feed(data) }
                if done || error != nil { self.lock.lock(); self.eof = true; self.lock.unlock(); return }
                self.receive()
            }
        }

        private func feed(_ d: Data) {
            lock.lock()
            buffer.append(d)
            var out: [(UInt8, Data)] = []
            while buffer.count >= 5 {
                let n = Int(buffer.u32BE(at: 1))
                guard buffer.count >= 5 + n else { break }
                let t = buffer.u8(at: 0)
                let p = Data(buffer.subdata(in: buffer.startIndex + 5 ..< buffer.startIndex + 5 + n))
                buffer.removeSubrange(buffer.startIndex ..< buffer.startIndex + 5 + n)
                _frames.append((t, p))
                out.append((t, p))
            }
            let cb = onFrame
            lock.unlock()
            out.forEach { cb?($0.0, $0.1) }
        }

        func send(_ d: Data) {
            conn.send(content: d, completion: .contentProcessed { _ in })
        }

        func sendSlowly(_ slice: Data, chunk: Int, gap: TimeInterval) {
            let d = Data(slice)   // re-base: a slice keeps its parent's indices
            var i = 0
            while i < d.count {
                send(d.subdata(in: i ..< min(d.count, i + chunk)))
                i += chunk
                Thread.sleep(forTimeInterval: gap)
            }
        }
    }

    private var listener: NWListener!
    private var peer: Peer!
    private var session: ClientSession!
    private let queue = DispatchQueue(label: "test.peer")
    private var received: [(MessageType, Data)] = []
    private let lock = NSLock()
    private var closeReason: String?

    override func setUpWithError() throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: params)
        let accepted = expectation(description: "accepted")
        let ready = expectation(description: "listening")
        listener.newConnectionHandler = { [weak self] c in
            guard let self, self.peer == nil else { c.cancel(); return }
            let p = Peer(c)
            p.start(queue: self.queue)
            self.peer = p
            accepted.fulfill()
        }
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: queue)
        wait(for: [ready], timeout: 5)
        let port = try XCTUnwrap(listener.port)
        XCTAssertNotEqual(port.rawValue, PlexiProtocol.tcpPort)

        let conn = NWConnection(host: "127.0.0.1", port: port, using: .tcp)
        session = ClientSession(connection: conn)
        session.onMessage = { [weak self] _, t, p in
            guard let self else { return }
            self.lock.lock(); self.received.append((t, p)); self.lock.unlock()
        }
        session.onClose = { [weak self] _, reason in
            guard let self else { return }
            self.lock.lock(); self.closeReason = reason; self.lock.unlock()
        }
        session.start()
        wait(for: [accepted], timeout: 5)
    }

    override func tearDown() {
        session?.close(reason: "test done", sendBye: false)
        peer?.conn.cancel()
        listener?.cancel()
        session = nil; peer = nil; listener = nil
    }

    private func waitFor(_ what: String, timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock(); let ok = cond(); lock.unlock()
            if ok { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        XCTFail("timed out waiting for \(what)")
    }

    private func messages() -> [(MessageType, Data)] { lock.lock(); defer { lock.unlock() }; return received }

    // MARK: Tests

    func testIsLoopbackAndDescribed() {
        XCTAssertTrue(session.isLoopback)
        XCTAssertTrue(session.remoteDescription.hasPrefix("127.0.0.1:"), session.remoteDescription)
        XCTAssertEqual(session.remoteHost, "127.0.0.1")
    }

    func testFrameSplitByteByByte() {
        let json = Data(#"{"orientation":"portrait"}"#.utf8)
        peer.sendSlowly(Frame.make(.settings, json), chunk: 1, gap: 0.002)
        waitFor("SETTINGS") { self.received.count == 1 }
        XCTAssertEqual(messages()[0].0, .settings)
        XCTAssertEqual(messages()[0].1, json)
    }

    func testHeaderSplitFromPayload() {
        let hello = Data(ProtocolJSONTests.androidHello.utf8)
        let f = Frame.make(.hello, hello)
        peer.send(f.prefix(3))
        Thread.sleep(forTimeInterval: 0.05)
        peer.send(f.subdata(in: 3 ..< 5))
        Thread.sleep(forTimeInterval: 0.05)
        peer.sendSlowly(f.suffix(from: 5), chunk: 97, gap: 0.001)
        waitFor("HELLO") { self.received.count == 1 }
        XCTAssertEqual(messages()[0].0, .hello)
        XCTAssertNoThrow(try JSONDecoder().decode(HelloMessage.self, from: messages()[0].1))
    }

    func testCoalescedFramesKeepOrder() {
        var batch = Data()
        batch += Frame.make(.requestKeyframe)
        batch += Frame.make(.key, Data(#"{"action":"down","keyCode":66}"#.utf8))
        batch += Frame.make(.input, FramingTests.input([FramingTests.pointer(kind: 0, action: 0, x: 0.5, y: 0.5)]))
        batch += Frame.make(.settings, Data(#"{"fps":30}"#.utf8))
        peer.send(batch)
        waitFor("4 messages") { self.received.count == 4 }
        XCTAssertEqual(messages().map(\.0), [.requestKeyframe, .key, .input, .settings])
        XCTAssertEqual(messages()[0].1.count, 0)
        XCTAssertEqual(InputParser.parse(messages()[2].1).count, 1)
    }

    func testPingIsEchoedAsPongAndNotForwarded() {
        var p = Data(); p.appendBE(UInt64(0xCAFE_F00D_1234_5678))
        peer.send(Frame.make(.ping, p) + Frame.make(.requestKeyframe))
        waitFor("PONG") { self.peer.frames.contains { $0.0 == MessageType.pong.rawValue } }
        let pong = peer.frames.first { $0.0 == MessageType.pong.rawValue }!
        XCTAssertEqual(pong.1, p)
        waitFor("REQUEST_KEYFRAME") { self.received.count == 1 }
        XCTAssertEqual(messages().map(\.0), [.requestKeyframe])   // PING handled internally
    }

    func testHostHeartbeatPingsWithEightBytePayload() {
        waitFor("host PING", timeout: 3) { self.peer.frames.contains { $0.0 == MessageType.ping.rawValue } }
        let ping = peer.frames.first { $0.0 == MessageType.ping.rawValue }!
        XCTAssertEqual(ping.1.count, 8)
    }

    func testUnknownTypeIsSkipped() {
        peer.send(Frame.make(.settings, Data("{}".utf8)).replacingFirstByte(0x7F)
                  + Data([0x00, 0, 0, 0, 0])
                  + Frame.make(.requestKeyframe))
        waitFor("REQUEST_KEYFRAME") { self.received.count == 1 }
        XCTAssertEqual(messages().map(\.0), [.requestKeyframe])
        XCTAssertFalse(session.isClosed)
    }

    func testOversizeLengthIsRejectedWithBye() {
        var header = Data([MessageType.video.rawValue])
        header.appendBE(UInt32(PlexiProtocol.maxPayload + 1))
        peer.send(header)
        waitFor("session close") { self.closeReason != nil }
        XCTAssertEqual(closeReason, "Payload too large")
        waitFor("BYE") { self.peer.frames.contains { $0.0 == MessageType.bye.rawValue } }
        let bye = peer.frames.first { $0.0 == MessageType.bye.rawValue }!
        XCTAssertEqual(String(data: bye.1, encoding: .utf8), "Payload too large")
        XCTAssertTrue(received.isEmpty)
    }

    func testMaxLengthHeaderIsNotRejected() {
        var header = Data([MessageType.video.rawValue])
        header.appendBE(UInt32(PlexiProtocol.maxPayload))   // exactly 16 MiB is allowed
        peer.send(header + Data(count: 1000))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertFalse(session.isClosed)
        peer.conn.cancel()   // tablet gives up mid-payload
        waitFor("session close") { self.closeReason != nil }
        XCTAssertNotEqual(closeReason, "Payload too large")
    }

    func testTabletByeEndsSession() {
        peer.send(Frame.text(.bye, "user left"))
        waitFor("session close") { self.closeReason != nil }
        XCTAssertEqual(closeReason, "Tablet: user left")
        XCTAssertTrue(session.isClosed)
    }

    func testEmptyByeReason() {
        peer.send(Frame.make(.bye))
        waitFor("session close") { self.closeReason != nil }
        XCTAssertEqual(closeReason, "Tablet said goodbye")
    }

    func testTabletDisconnectWithoutBye() {
        peer.conn.cancel()
        waitFor("session close") { self.closeReason != nil }
        XCTAssertNotNil(closeReason)
    }

    func testHostCloseSendsBye() {
        session.close(reason: "Host stopped")
        waitFor("BYE") { self.peer.frames.contains { $0.0 == MessageType.bye.rawValue } }
        XCTAssertEqual(peer.frames.last.map { String(decoding: $0.1, as: UTF8.self) }, "Host stopped")
        waitFor("session close") { self.closeReason != nil }
        XCTAssertEqual(closeReason, "Host stopped")
        // nothing can be sent after close
        XCTAssertFalse(session.sendRaw(Frame.make(.stats), droppable: false))
    }

    func testSendVideoAndConfigReachTabletInOrder() throws {
        let cfg = ConfigMessage(codec: "h264", width: 2560, height: 1600, fps: 60, bitrateKbps: 20000, mode: "extend",
                                hostName: "Mac", hostOs: "macos", monitors: [], virtualDisplayAvailable: true)
        session.sendJSON(.config, cfg)
        let sps = Data([0, 0, 0, 1, 0x67, 0x64, 0, 0x32, 0, 0, 0, 1, 0x68, 0xEE, 0x3C, 0x80])
        XCTAssertTrue(session.sendVideo(ptsMicros: 1000, flags: .codecConfig, data: sps))
        XCTAssertTrue(session.sendVideo(ptsMicros: 1000, flags: .keyframe, data: Data([0, 0, 0, 1, 0x65, 0x88])))
        waitFor("3 frames") { self.peer.frames.filter { $0.0 != MessageType.ping.rawValue }.count >= 3 }
        let f = peer.frames.filter { $0.0 != MessageType.ping.rawValue }
        XCTAssertEqual(f.map(\.0), [0x02, 0x03, 0x03])
        XCTAssertEqual(try JSONDecoder().decode(ConfigMessage.self, from: f[0].1), cfg)
        XCTAssertEqual(f[1].1.u64BE(at: 0), 1000)
        XCTAssertEqual(f[1].1.u8(at: 8), 0x02)
        XCTAssertEqual(f[1].1.suffix(from: 9), sps)
        XCTAssertEqual(f[2].1.u8(at: 8), 0x01)
    }
}

private extension Data {
    func replacingFirstByte(_ b: UInt8) -> Data { var d = self; d[d.startIndex] = b; return d }
}
