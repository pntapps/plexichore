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
    private var _sawFirstMessage = false

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
    var link: SessionPolicy.Link?
    /// The link query started at HELLO (Windows `_linkTask`) finished; CONFIG waits ≤ 0.4 s for it.
    var linkResolved = false
    /// Encoder / capture failure escalation of this session (Windows `_pipelineFailures`, `_disallowHw`, ...).
    var failures = SessionPolicy.FailureState()
    /// Bumped whenever a pipeline is replaced, so a late "ended" callback of an old one is ignored.
    var pipelineGeneration = 0
    /// The tablet asked for auto scale (CONFIG/UI "scaleAuto").
    var scaleAuto = true

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

    /// Points input at a display (or disables input with nil). `frameSize` = encoded frame size (mirror letterboxing).
    func setInputTarget(displayID: CGDirectDisplayID?, touchMode: String, frameSize: CGSize? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let displayID {
            if let inj = _injector {
                if inj.displayID != displayID { inj.reset() }
                inj.displayID = displayID
                inj.touchMode = touchMode
            } else {
                _injector = InputInjector(displayID: displayID, touchMode: touchMode)
            }
            _injector?.frameSize = frameSize
            _injector?.naturalScrolling = InputMapping.systemNaturalScrolling()
        } else {
            _injector?.reset()
            _injector = nil
            keyInjector.releaseAll()
        }
    }

    /// Session queue: true for the very first message only (PROTOCOL: HELLO must come first).
    func markFirstMessage() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if _sawFirstMessage { return false }
        _sawFirstMessage = true
        return true
    }

    // MARK: Hot path (session queue)

    func handleInput(_ payload: Data) {
        let pointers = InputParser.parse(payload)
        guard !pointers.isEmpty else { return }   // Windows InputInjector.Post drops empty events
        lock.lock(); defer { lock.unlock() }
        guard _streaming, let inj = _injector else { return }
        inj.handle(pointers)
    }

    func handleKey(_ payload: Data) {
        guard let msg = try? JSONDecoder().decode(KeyMessage.self, from: payload) else { return }
        // Under `lock`: setInputTarget(nil) calls keyInjector.releaseAll() on the main actor.
        lock.lock(); defer { lock.unlock() }
        if _streaming { keyInjector.handle(msg) }
    }

    func requestKeyframe() {
        pipeline?.requestKeyframe()
    }
}
