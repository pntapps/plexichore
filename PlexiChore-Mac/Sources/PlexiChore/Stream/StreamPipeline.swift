import Foundation
import CoreGraphics
import CoreVideo
import ScreenCaptureKit

struct StreamParameters: Equatable {
    var codec: String          // requested "h264" | "mjpeg" (the encoder may still fall back to MJPEG)
    var width: Int             // encoded frame size (even)
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    var quality: String
    var mode: String           // "extend" | "primary" | "mirror"
    var displayID: CGDirectDisplayID
    var periodicKeyframes: Bool
    var profile: SessionPolicy.H264Profile = .high
    /// Host setting "Preferred video encoder" (HostPreferences.preferHardwareEncoder).
    var preferHardware = true
    /// False once this session's hardware encoder failed (SessionPolicy.FailureState.disallowHardware).
    var allowHardware = true

    /// Same capture source and encoder setup; only the bitrate and/or fps differ (no new stream / IDR needed).
    func isCadenceOnlyChange(to o: StreamParameters) -> Bool {
        var probe = o
        probe.bitrateKbps = bitrateKbps
        probe.fps = fps
        return probe == self
    }
}

/// What the pipeline really produces (Windows `PipelineInfo`): feeds CONFIG codec/width/height/fps/encoder.
struct PipelineInfo: Equatable {
    var codec: String
    var width: Int
    var height: Int
    var fps: Int
    var encoderName: String
    var isHardware: Bool
    /// A new encoder instance (codec-config + IDR follow). False for a cadence-only (bitrate/fps) change.
    var newStream = true
}

struct LiveStats: Equatable {
    var captureFps: Double = 0
    var sentFps: Double = 0
    var encodeMs: Double = 0
    var bitrateKbps: Double = 0
    var droppedFrames: Int = 0
}

/// Capture → encode → send for one session. Frame work happens on `videoQueue`.
///
/// Video is gated until `activate(config:)`: the CONFIG built from the real encoder (`PipelineInfo`) always reaches
/// the tablet before the stream's codec-config + IDR (Windows: CONFIG, `ResetVideo(true)`, `RequestKeyframe`).
/// `reconfigure(to:makeConfig:)` swaps the encoder (and capture size) without restarting the capture: the mid-stream
/// CONFIG is sent, then the new encoder's codec-config + IDR (PROTOCOL.md "seamless resize").
final class StreamPipeline: @unchecked Sendable {
    private weak var session: ClientSession?
    private let videoQueue: DispatchQueue
    private let capturer: ScreenCapturer
    private var keepAlive: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?

    // videoQueue state
    private var _params: StreamParameters
    private var encoder: VideoEncoder?
    private var lastFrame: CVPixelBuffer?
    private var lastEncodeMicros: UInt64 = 0
    private var needKeyframe = true
    private var capturedFrames = 0
    private var dropped = 0
    private var stopped = false
    private var ended = false
    /// Capture stopped by `freezeCapture()`: the encoder keeps re-sending the last frame (keep-alive) until `stop()`.
    private var frozen = false
    /// After a size change: until then, frames of the old capture size are skipped (0 = no resize pending).
    private var resizeDeadlineMicros: UInt64 = 0

    // touched from encoder callback threads (guarded by `sendLock`)
    private let sendLock = NSLock()
    private var generation = 0            // outputs of older encoders are dropped
    private var videoEnabled = false
    private var waitForKeyframe = true    // after a drop: nothing but codec-config / IDR until the next IDR
    private var isMjpeg = false
    private var lastKeyRequestMicros: UInt64 = 0
    private var sentBytes = 0
    private var sentFrames = 0

    private var _onStats: (@Sendable (LiveStats) -> Void)?
    private var _onEnded: (@Sendable (String) -> Void)?

    /// Called on the main queue roughly once per second. Thread-safe (guarded by `sendLock`); cleared by `stop()`.
    var onStats: (@Sendable (LiveStats) -> Void)? {
        get { sendLock.lock(); defer { sendLock.unlock() }; return _onStats }
        set { sendLock.lock(); _onStats = newValue; sendLock.unlock() }
    }
    /// Called (any thread, at most once) when the pipeline ended by itself. Reasons follow Windows
    /// `StreamPipeline.Ended`: "encoder:<msg>" (encoder failure → escalate), "capture:<msg>" (capture lost → retry),
    /// "stopped:<msg>" (the user stopped screen sharing in macOS → end the session). Thread-safe; cleared by `stop()`.
    var onEnded: (@Sendable (String) -> Void)? {
        get { sendLock.lock(); defer { sendLock.unlock() }; return _onEnded }
        set { sendLock.lock(); _onEnded = newValue; sendLock.unlock() }
    }

    private let keepAliveMicros: UInt64 = 350_000   // + 100 ms timer slack stays under the 500 ms rule

    init(session: ClientSession, params: StreamParameters) {
        self.session = session
        self._params = params
        let queue = DispatchQueue(label: "plexi.video", qos: .userInteractive)
        self.videoQueue = queue
        self.capturer = ScreenCapturer(sampleQueue: queue)
    }

    var params: StreamParameters { videoQueue.sync { _params } }

    // MARK: Encoder fallback chain (Windows CreateStage: MfH264Encoder.TryCreate(hw, sw) ?? MjpegEncoder)

    /// Hardware H.264 → software H.264 → MJPEG (preferred order flips when the user prefers software;
    /// hardware is skipped entirely after a hardware failure in this session).
    static func makeEncoder(_ p: StreamParameters) -> VideoEncoder {
        if p.codec == "h264" {
            var order: [Bool] = p.preferHardware ? [true, false] : [false, true]
            if !p.allowHardware { order.removeAll { $0 } }
            for hw in order {
                if let e = try? H264Encoder(width: p.width, height: p.height, fps: p.fps,
                                            bitrateKbps: p.bitrateKbps, quality: p.quality,
                                            keyframeIntervalSeconds: p.periodicKeyframes ? 5 : 3600,
                                            profile: p.profile, allowHardware: hw) {
                    return e
                }
            }
        }
        return MJPEGEncoder(quality: p.quality, width: p.width, height: p.height)
    }

    private static func info(_ enc: VideoEncoder, _ p: StreamParameters, newStream: Bool = true) -> PipelineInfo {
        PipelineInfo(codec: enc.codec, width: p.width, height: p.height, fps: p.fps,
                     encoderName: enc.name, isHardware: enc.isHardware, newStream: newStream)
    }

    // MARK: Lifecycle

    /// Builds the encoder and starts the capture. Video stays gated until `activate(config:)`.
    func start() async throws -> PipelineInfo {
        let p = videoQueue.sync { _params }
        let enc = Self.makeEncoder(p)
        install(enc)

        capturer.onFrame = { [weak self] pb in self?.handleFrame(pb) }
        capturer.onStopped = { [weak self] error in
            let ns = error as NSError
            // SCStreamError.userStopped: the user ended the share from the menu bar / Control Center.
            if ns.domain == SCStreamErrorDomain && ns.code == SCStreamError.Code.userStopped.rawValue {
                self?.end("stopped:Screen sharing was stopped on the Mac")
            } else {
                self?.end("capture:\(error.localizedDescription)")
            }
        }
        try await capturer.start(displayID: p.displayID, width: p.width, height: p.height, fps: p.fps)
        videoQueue.sync { self.startTimers() }
        return Self.info(enc, p)
    }

    /// Sends CONFIG, then lets video through starting with codec-config + IDR.
    func activate(config: ConfigMessage) {
        videoQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.session?.sendJSON(.config, config)
            self.sendLock.lock()
            self.videoEnabled = true
            self.waitForKeyframe = !self.isMjpeg
            self.sendLock.unlock()
            self.needKeyframe = true
            if let pb = self.lastFrame { self.encodeNow(pb) }
        }
    }

    /// Stops the capture (its display is about to be replaced) but keeps the encoder and the keep-alive timer, so
    /// the tablet keeps receiving the last picture (≥ 1 frame / 500 ms, PROTOCOL.md) while the virtual display is
    /// re-created (~1.3 s, CGVirtualDisplay has no live mode change). Stop it before the next pipeline activates.
    func freezeCapture() async {
        let first = videoQueue.sync { () -> Bool in
            guard !stopped, !frozen else { return false }
            frozen = true
            return true
        }
        guard first else { return }
        await capturer.stop()
    }

    var isFrozen: Bool { videoQueue.sync { frozen } }

    func stop() async {
        videoQueue.sync {
            stopped = true
            keepAlive?.cancel(); keepAlive = nil
            statsTimer?.cancel(); statsTimer = nil
            sendLock.lock(); videoEnabled = false; generation += 1; _onEnded = nil; _onStats = nil; sendLock.unlock()
        }
        await capturer.stop()
        videoQueue.sync {
            encoder?.invalidate()
            encoder = nil
            lastFrame = nil
        }
    }

    /// Live change on the same display. Cadence-only (bitrate/fps): same encoder, no new IDR, CONFIG resent.
    /// Otherwise (size, codec, quality, profile, encoder permission): a new encoder is built, the capture output is
    /// resized in place, then CONFIG (from `makeConfig`) + codec-config + IDR — the capture never restarts.
    /// Returns nil when the display differs (caller must restart the pipeline).
    func reconfigure(to newParams: StreamParameters,
                     makeConfig: @escaping @Sendable (PipelineInfo) -> ConfigMessage) async -> PipelineInfo? {
        let (old, isStopped) = videoQueue.sync { (_params, stopped) }
        guard !isStopped, !isFrozen, old.displayID == newParams.displayID else { return nil }

        if old.isCadenceOnlyChange(to: newParams) {
            if old.fps != newParams.fps {
                await capturer.update(width: newParams.width, height: newParams.height, fps: newParams.fps)
            }
            return videoQueue.sync { () -> PipelineInfo? in
                guard !stopped, let enc = encoder else { return nil }
                if old.bitrateKbps != newParams.bitrateKbps { enc.setBitrate(kbps: newParams.bitrateKbps) }
                if old.fps != newParams.fps { enc.setFrameRate(newParams.fps) }
                _params = newParams
                let info = Self.info(enc, newParams, newStream: false)
                session?.sendJSON(.config, makeConfig(info))
                return info
            }
        }

        let enc = Self.makeEncoder(newParams)   // built while the old encoder keeps streaming
        let sizeChanged = old.width != newParams.width || old.height != newParams.height
        if sizeChanged || old.fps != newParams.fps {
            await capturer.update(width: newParams.width, height: newParams.height, fps: newParams.fps)
        }
        return videoQueue.sync { () -> PipelineInfo? in
            guard !stopped else { enc.invalidate(); return nil }
            let previous = encoder
            _params = newParams
            install(enc)                              // bumps the generation: late old outputs are dropped
            previous?.invalidate()
            let info = Self.info(enc, newParams)
            session?.sendJSON(.config, makeConfig(info))
            sendLock.lock()
            waitForKeyframe = !isMjpeg
            sendLock.unlock()
            needKeyframe = true
            if sizeChanged {
                resizeDeadlineMicros = Clock.nowMicros() + 500_000
                if let pb = lastFrame, CVPixelBufferGetWidth(pb) == newParams.width,
                   CVPixelBufferGetHeight(pb) == newParams.height {
                    encodeNow(pb)
                }
            } else if let pb = lastFrame {
                encodeNow(pb)
            }
            return info
        }
    }

    func requestKeyframe() {
        videoQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            self.needKeyframe = true
            // On a static screen no new frame may arrive: re-encode the last one right away.
            if let pb = self.lastFrame { self.encodeNow(pb) }
        }
    }

    func setBitrate(kbps: Int) {
        videoQueue.async { [weak self] in
            guard let self else { return }
            self._params.bitrateKbps = kbps
            self.encoder?.setBitrate(kbps: kbps)
        }
    }

    // MARK: Internals (videoQueue)

    /// Installs `enc` as the current encoder under a new generation (videoQueue or before timers start).
    private func install(_ enc: VideoEncoder) {
        sendLock.lock()
        generation += 1
        let gen = generation
        isMjpeg = enc.codec == "mjpeg"
        sendLock.unlock()
        enc.onPacket = { [weak self] data, flags, pts in self?.deliver(data, flags: flags, pts: pts, gen: gen) }
        enc.onError = { [weak self] message in
            guard let self else { return }
            self.sendLock.lock(); let current = self.generation == gen; self.sendLock.unlock()
            if current { self.end(message) }
        }
        encoder = enc
    }

    private func end(_ reason: String) {
        videoQueue.async { [weak self] in
            guard let self, !self.stopped, !self.frozen, !self.ended else { return }
            self.ended = true
            self.onEnded?(reason)   // getter takes sendLock; nil after stop()
        }
    }

    private func handleFrame(_ pb: CVPixelBuffer) {
        guard !stopped, !frozen else { return }
        capturedFrames += 1
        if resizeDeadlineMicros != 0 {
            let p = _params
            if CVPixelBufferGetWidth(pb) == p.width && CVPixelBufferGetHeight(pb) == p.height {
                resizeDeadlineMicros = 0
            } else if Clock.nowMicros() < resizeDeadlineMicros {
                return   // an old-size frame still in flight from before the capture resize
            } else {
                resizeDeadlineMicros = 0   // never got one: encoders scale the frame
            }
        }
        lastFrame = pb
        encodeNow(pb)
    }

    /// Bytes allowed in the socket queue before frames are skipped: ~4 frames at the configured rate
    /// (Windows keeps ≤ 3 queued frames over a 192 KB socket buffer), at least 512 KB so an IDR fits.
    private var backlogLimit: Int {
        let p = _params
        let perFrame = max(1, p.bitrateKbps) * 1000 / 8 / max(1, p.fps)
        return max(512 * 1024, perFrame * 4)
    }

    private func encodeNow(_ pb: CVPixelBuffer) {
        guard let encoder, let session, !stopped else { return }
        sendLock.lock(); let enabled = videoEnabled; sendLock.unlock()
        guard enabled else { return }   // nothing is encoded before activate(): its IDR is the stream's first
        let now = Clock.nowMicros()

        // MJPEG is expensive — cap it at ~30 fps.
        if encoder.codec == "mjpeg", !needKeyframe, now &- lastEncodeMicros < 30_000 { return }

        // Backpressure: the socket is backed up — skip this frame. Nothing was encoded, so no reference breaks
        // (no IDR needed); the next frame after the backlog drains is a normal P-frame.
        if session.queuedBytes > backlogLimit {
            dropped += 1
            return
        }

        let force = needKeyframe
        needKeyframe = false
        lastEncodeMicros = now
        encoder.encode(pb, ptsMicros: now, forceKeyframe: force)
    }

    /// Encoder output (any thread). Windows SessionSender semantics: a fresh stream / a dropped delta frame means
    /// nothing but codec-config + IDR goes out until the next IDR, which is requested (≤ 1 per 250 ms).
    private func deliver(_ data: Data, flags: VideoFlags, pts: UInt64, gen: Int) {
        guard let session else { return }
        let isKey = flags.contains(.keyframe), isCfg = flags.contains(.codecConfig)
        // Generation check and send happen under one lock: install() bumps the generation under it before the
        // mid-stream CONFIG goes out, so an old-encoder frame either precedes that CONFIG or is dropped.
        sendLock.lock()
        guard gen == generation, videoEnabled else { sendLock.unlock(); return }
        var requestKey = !isMjpeg && waitForKeyframe && !isKey && !isCfg
        if !requestKey {
            if session.sendVideo(ptsMicros: pts, flags: flags, data: data) {
                if isKey { waitForKeyframe = false }
                sentBytes += data.count + 14
                if !isCfg { sentFrames += 1 }
                sendLock.unlock()
                return
            }
            // Refused by the session (socket backed up): the decoder needs a fresh IDR.
            if !isMjpeg { waitForKeyframe = true }
            requestKey = true
        }
        let now = Clock.nowMicros()
        let ask = now &- lastKeyRequestMicros >= 250_000
        if ask { lastKeyRequestMicros = now }
        sendLock.unlock()
        videoQueue.async { [weak self] in
            self?.dropped += 1
            if ask { self?.needKeyframe = true }
        }
    }

    // MARK: Timers

    private func startTimers() {
        let ka = DispatchSource.makeTimerSource(queue: videoQueue)
        ka.schedule(deadline: .now() + .milliseconds(100), repeating: .milliseconds(100))
        ka.setEventHandler { [weak self] in
            guard let self, !self.stopped, let pb = self.lastFrame else { return }
            let now = Clock.nowMicros()
            // Protocol: at least one frame every 500 ms so the tablet knows we are alive.
            if now &- self.lastEncodeMicros >= self.keepAliveMicros || self.needKeyframe {
                self.encodeNow(pb)
            }
        }
        keepAlive = ka
        ka.resume()

        var lastTick = Clock.nowMicros()
        let st = DispatchSource.makeTimerSource(queue: videoQueue)
        st.schedule(deadline: .now() + 1, repeating: 1.0)
        st.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let now = Clock.nowMicros()
            let dt = max(0.001, Double(now &- lastTick) / 1_000_000)
            lastTick = now
            self.sendLock.lock()
            let bytes = self.sentBytes, frames = self.sentFrames, enabled = self.videoEnabled
            self.sentBytes = 0; self.sentFrames = 0
            self.sendLock.unlock()
            let stats = LiveStats(captureFps: Double(self.capturedFrames) / dt,
                                  sentFps: Double(frames) / dt,
                                  encodeMs: self.encoder?.averageEncodeMs ?? 0,
                                  bitrateKbps: Double(bytes) * 8 / 1000 / dt,
                                  droppedFrames: self.dropped)
            self.capturedFrames = 0
            // STATS like Windows KeepAliveLoopAsync: frames that went out per second, encode ms (2 dp), int kbps.
            if enabled {
                let msg = StatsMessage(captureFps: (stats.sentFps * 10).rounded() / 10,
                                       encodeMs: (stats.encodeMs * 100).rounded() / 100,
                                       bitrateKbps: Int(stats.bitrateKbps))
                self.session?.sendJSON(.stats, msg)
            }
            let cb = self.onStats
            DispatchQueue.main.async { cb?(stats) }
        }
        statsTimer = st
        st.resume()
    }
}
