import Foundation
import Network

/// One TCP connection from a tablet. Handles framing, PING/PONG, liveness and send backpressure.
/// All network callbacks run on `queue`; `send*` may be called from any thread.
final class ClientSession: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    let queue: DispatchQueue
    let remoteDescription: String
    let isLoopback: Bool

    /// Called on `queue` for every complete message except PING/PONG (handled internally).
    var onMessage: (@Sendable (ClientSession, MessageType, Data) -> Void)?
    /// Called once on `queue` when the session ends.
    var onClose: (@Sendable (ClientSession, String) -> Void)?
    /// Called on `queue` with a fresh RTT measurement in milliseconds.
    var onRTT: (@Sendable (ClientSession, Double) -> Void)?

    private let lock = NSLock()
    private var pendingBytes = 0
    private var closed = false
    private var lastReceived = Clock.nowMicros()
    private var heartbeat: DispatchSourceTimer?

    /// Frames that may be dropped are refused once this many bytes are queued in the socket.
    private let maxPendingBytes = 3 * 1024 * 1024
    private let deadAfterMicros = UInt64(SessionPolicy.deadAfter * 1_000_000)

    init(connection: NWConnection) {
        self.connection = connection
        self.queue = DispatchQueue(label: "plexi.session.\(UUID().uuidString.prefix(8))", qos: .userInteractive)
        self.remoteDescription = Self.describe(connection.endpoint)
        self.isLoopback = Self.isLoopback(connection.endpoint)
    }

    // MARK: Lifecycle

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.startHeartbeat()
                self.readHeader()
            case .failed(let error):
                self.finish(reason: "Connection failed: \(error.localizedDescription)")
            case .cancelled:
                self.finish(reason: "Connection closed")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Sends BYE (best effort) then closes.
    func close(reason: String, sendBye: Bool = true) {
        queue.async { [weak self] in
            guard let self else { return }
            if self.isClosed { return }
            if sendBye {
                let frame = Frame.text(.bye, reason)
                let conn = self.connection   // strong: must outlive this session object
                conn.send(content: frame, completion: .contentProcessed { _ in
                    conn.cancel()
                })
                // Safety net: cancel even if the send never completes.
                self.queue.asyncAfter(deadline: .now() + 0.5) { conn.cancel() }
            } else {
                self.connection.cancel()
            }
            self.finish(reason: reason, cancelConnection: !sendBye)
        }
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func finish(reason: String, cancelConnection: Bool = true) {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        heartbeat?.cancel()
        heartbeat = nil
        if cancelConnection {
            connection.cancel()   // idempotent
        }
        let handler = onClose
        onClose = nil
        onMessage = nil
        handler?(self, reason)
    }

    // MARK: Receive

    private func readHeader() {
        connection.receive(minimumIncompleteLength: PlexiProtocol.headerSize,
                           maximumLength: PlexiProtocol.headerSize) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(reason: "Receive error: \(error.localizedDescription)")
                return
            }
            guard let data, data.count == PlexiProtocol.headerSize else {
                if isComplete { self.finish(reason: "Tablet disconnected") }
                else { self.finish(reason: "Short header") }
                return
            }
            let rawType = data.u8(at: 0)
            let length = Int(data.u32BE(at: 1))
            guard length <= PlexiProtocol.maxPayload else {
                self.close(reason: "Payload too large")
                return
            }
            if length == 0 {
                self.dispatch(rawType: rawType, payload: Data())
                self.readHeader()
            } else {
                self.readPayload(rawType: rawType, length: length)
            }
        }
    }

    private func readPayload(rawType: UInt8, length: Int) {
        connection.receive(minimumIncompleteLength: length, maximumLength: length) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let error {
                self.finish(reason: "Receive error: \(error.localizedDescription)")
                return
            }
            guard let data, data.count == length else {
                self.finish(reason: isComplete ? "Tablet disconnected" : "Short payload")
                return
            }
            self.dispatch(rawType: rawType, payload: data)
            self.readHeader()
        }
    }

    private func dispatch(rawType: UInt8, payload: Data) {
        lock.lock(); lastReceived = Clock.nowMicros(); lock.unlock()
        guard let type = MessageType(rawValue: rawType) else { return }   // ignore unknown types
        switch type {
        case .ping:
            sendRaw(Frame.make(.pong, payload), droppable: false)
        case .pong:
            // Windows: exactly 8 bytes, 0 <= rtt < 60 s (a tablet echoing garbage can't fake an RTT).
            if payload.count == 8 {
                let sent = payload.u64BE(at: 0)
                let now = Clock.nowMicros()
                if now >= sent, now - sent < 60_000_000 {
                    onRTT?(self, Double(now - sent) / 1000.0)
                }
            }
        case .bye:
            let reason = String(data: payload, encoding: .utf8) ?? ""
            finish(reason: reason.isEmpty ? "Tablet said goodbye" : "Tablet: \(reason)")
        default:
            onMessage?(self, type, payload)
        }
    }

    // MARK: Heartbeat

    private func startHeartbeat() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        var lastTick = Clock.nowMicros()
        t.setEventHandler { [weak self] in
            guard let self else { return }
            let now = Clock.nowMicros()
            // Windows KeepAliveLoopAsync: if this process itself stalled (tick > 2.5 s late), don't blame the tablet.
            let stalled = now &- lastTick > UInt64(SessionPolicy.selfStallThreshold * 1_000_000)
            lastTick = now
            self.lock.lock()
            if stalled { self.lastReceived = now }
            let last = self.lastReceived
            self.lock.unlock()
            // PING first (like Windows), then the liveness check.
            var payload = Data(capacity: 8)
            payload.appendBE(now)
            self.sendRaw(Frame.make(.ping, payload), droppable: false)
            if now > last && now - last > self.deadAfterMicros {
                self.close(reason: "timeout (no message for 5 s)", sendBye: false)
            }
        }
        heartbeat = t
        t.resume()
    }

    // MARK: Send

    /// Sends an already framed message. Returns false if it was dropped due to backpressure.
    @discardableResult
    func sendRaw(_ frame: Data, droppable: Bool) -> Bool {
        lock.lock()
        if closed { lock.unlock(); return false }
        if droppable && pendingBytes > maxPendingBytes {
            lock.unlock()
            return false
        }
        pendingBytes += frame.count
        lock.unlock()

        let size = frame.count
        connection.send(content: frame, completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            self.lock.lock()
            self.pendingBytes -= size
            self.lock.unlock()
            if let error {
                self.finish(reason: "Send error: \(error.localizedDescription)")
            }
        })
        return true
    }

    func send(_ type: MessageType, _ payload: Data = Data()) {
        sendRaw(Frame.make(type, payload), droppable: false)
    }

    func sendJSON<T: Encodable>(_ type: MessageType, _ value: T) {
        sendRaw(Frame.json(type, value), droppable: false)
    }

    /// Video frames: delta frames are droppable, keyframes/codec-config never are.
    @discardableResult
    func sendVideo(ptsMicros: UInt64, flags: VideoFlags, data: Data) -> Bool {
        let droppable = !(flags.contains(.keyframe) || flags.contains(.codecConfig))
        return sendRaw(Frame.video(ptsMicros: ptsMicros, flags: flags, data: data), droppable: droppable)
    }

    var queuedBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pendingBytes
    }

    // MARK: Endpoint helpers

    static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }
        switch host {
        case .ipv4(let a):
            return a.isLoopback
        case .ipv6(let a):
            if a.isLoopback { return true }
            if let v4 = a.asIPv4 { return v4.isLoopback }
            return false
        case .name(let name, _):
            return name == "localhost"
        @unknown default:
            return false
        }
    }

    static func describe(_ endpoint: NWEndpoint) -> String {
        switch endpoint {
        case let .hostPort(host, port):
            switch host {
            case .ipv4(let a): return "\(a):\(port)"
            case .ipv6(let a):
                if let v4 = a.asIPv4 { return "\(v4):\(port)" }
                return "[\(a)]:\(port)"
            case .name(let n, _): return "\(n):\(port)"
            @unknown default: return "\(endpoint)"
            }
        default:
            return "\(endpoint)"
        }
    }

    /// Local address (host part) and interface the connection arrived on, for CONFIG `link`.
    var localPathInfo: (address: String?, interface: String?) {
        guard let path = connection.currentPath else { return (nil, nil) }
        var address: String?
        if let local = path.localEndpoint {
            let d = Self.describe(local)
            if let idx = d.lastIndex(of: ":"), !d.hasPrefix("[") { address = String(d[..<idx]) } else { address = d }
        }
        return (address, path.availableInterfaces.first?.name)
    }

    /// Host part only (used to tell Wi-Fi tablets apart in the UI).
    var remoteHost: String {
        if let idx = remoteDescription.lastIndex(of: ":"), !remoteDescription.hasPrefix("[") {
            return String(remoteDescription[..<idx])
        }
        return remoteDescription
    }
}
