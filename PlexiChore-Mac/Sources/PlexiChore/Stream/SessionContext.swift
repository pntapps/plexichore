import Foundation
import CoreGraphics

/// Per-connection state shared between the main actor (control) and the session queue (hot path:
/// INPUT / KEY / REQUEST_KEYFRAME). Everything mutable is guarded by `lock`.
final class SessionContext: @unchecked Sendable {
    let session: ClientSession
    let connectedAt = Date()

    private let lock = NSLock()
    private var _pipeline: StreamPipeline?
    private var _injector: InputInjector?
    private let keyInjector = KeyInjector()
    private var _streaming = false

    // Main-actor-only fields (never touched from the session queue).
    var hello: HelloMessage?
    var requested = RequestedSettings.defaults
    var approved = false
    var pairingCode: String?
    var params: StreamParameters?
    var config: ConfigMessage?
    var isConfiguring = false
    var pendingReconfigure = false
    var rttMs: Double = 0

    init(session: ClientSession) {
        self.session = session
    }

    var id: UUID { session.id }

    var pipeline: StreamPipeline? {
        get { lock.lock(); defer { lock.unlock() }; return _pipeline }
        set { lock.lock(); _pipeline = newValue; lock.unlock() }
    }

    var isStreaming: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _streaming }
        set { lock.lock(); _streaming = newValue; lock.unlock() }
    }

    /// Points input at a display (or disables input with nil).
    func setInputTarget(displayID: CGDirectDisplayID?, touchMode: String) {
        lock.lock(); defer { lock.unlock() }
        if let displayID {
            if let inj = _injector {
                if inj.displayID != displayID { inj.reset() }
                inj.displayID = displayID
                inj.touchMode = touchMode
            } else {
                _injector = InputInjector(displayID: displayID, touchMode: touchMode)
            }
        } else {
            _injector?.reset()
            _injector = nil
        }
    }

    // MARK: Hot path (session queue)

    func handleInput(_ payload: Data) {
        guard let pointers = InputParser.parse(payload) else { return }
        lock.lock(); defer { lock.unlock() }
        guard _streaming, let inj = _injector else { return }
        inj.handle(pointers)
    }

    func handleKey(_ payload: Data) {
        guard let msg = try? JSONDecoder().decode(KeyMessage.self, from: payload) else { return }
        lock.lock()
        let ok = _streaming
        lock.unlock()
        if ok { keyInjector.handle(msg) }
    }

    func requestKeyframe() {
        pipeline?.requestKeyframe()
    }
}
