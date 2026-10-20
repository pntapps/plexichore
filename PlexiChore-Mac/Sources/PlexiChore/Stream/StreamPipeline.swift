import Foundation
import CoreGraphics
import CoreVideo

struct StreamParameters: Equatable {
    var codec: String          // "h264" | "mjpeg"
    var width: Int             // encoded frame size (even)
    var height: Int
    var fps: Int
    var bitrateKbps: Int
    var quality: String
    var mode: String           // "extend" | "mirror"
    var displayID: CGDirectDisplayID
    var periodicKeyframes: Bool
}

struct LiveStats: Equatable {
    var captureFps: Double = 0
    var sentFps: Double = 0
    var encodeMs: Double = 0
    var bitrateKbps: Double = 0
    var droppedFrames: Int = 0
}

/// Capture → encode → send for one session. Frame work happens on `videoQueue`.
final class StreamPipeline: @unchecked Sendable {
    let params: StreamParameters
    private weak var session: ClientSession?
    private let videoQueue: DispatchQueue
    private let capturer: ScreenCapturer
    private var encoder: VideoEncoder?
    private var keepAlive: DispatchSourceTimer?
    private var statsTimer: DispatchSourceTimer?

    // videoQueue state
    private var lastFrame: CVPixelBuffer?
    private var lastEncodeMicros: UInt64 = 0
    private var lastNewFrameMicros: UInt64 = 0
    private var needKeyframe = true
    private var lastKeyframeMicros: UInt64 = 0
    private var capturedFrames = 0
    private var encodedFrames = 0
    private var dropped = 0
    private var stopped = false

    // counters touched from the encoder callback thread
    private let counterLock = NSLock()
    private var sentBytes = 0
    private var sentFrames = 0

    /// Called on the main actor roughly once per second.
    var onStats: (@Sendable (LiveStats) -> Void)?
    /// Called (any thread) when capture fails mid-stream.
    var onFailure: (@Sendable (String) -> Void)?

    private let backlogLimit = 1_500_000   // bytes queued in the socket before we skip frames
    private let keepAliveMicros: UInt64 = 450_000

    init(session: ClientSession, params: StreamParameters) {
        self.session = session
        self.params = params
        let queue = DispatchQueue(label: "plexi.video", qos: .userInteractive)
        self.videoQueue = queue
        self.capturer = ScreenCapturer(sampleQueue: queue)
    }

    // MARK: Lifecycle

    func start() async throws {
        let enc: VideoEncoder
        if params.codec == "mjpeg" {
            enc = MJPEGEncoder(quality: params.quality)
        } else {
            enc = try H264Encoder(width: params.width, height: params.height, fps: params.fps,
                                  bitrateKbps: params.bitrateKbps, quality: params.quality,
                                  keyframeIntervalSeconds: params.periodicKeyframes ? 5 : 3600)
        }
        enc.onPacket = { [weak self] data, flags, pts in self?.deliver(data, flags: flags, pts: pts) }
        videoQueue.sync { self.encoder = enc }

        capturer.onFrame = { [weak self] pb in self?.handleFrame(pb) }
        capturer.onStopped = { [weak self] error in
            self?.onFailure?("Capture stopped: \(error.localizedDescription)")
        }
        try await capturer.start(displayID: params.displayID, width: params.width,
                                 height: params.height, fps: params.fps)
        videoQueue.sync { self.startTimers() }
    }

    func stop() async {
        videoQueue.sync {
            stopped = true
            keepAlive?.cancel(); keepAlive = nil
            statsTimer?.cancel(); statsTimer = nil
        }
        await capturer.stop()
        videoQueue.sync {
            encoder?.invalidate()
            encoder = nil
            lastFrame = nil
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
        videoQueue.async { [weak self] in self?.encoder?.setBitrate(kbps: kbps) }
    }

    // MARK: Frames (videoQueue)

    private func handleFrame(_ pb: CVPixelBuffer) {
        guard !stopped else { return }
        capturedFrames += 1
        lastFrame = pb
        lastNewFrameMicros = Clock.nowMicros()
        encodeNow(pb)
    }

    private func encodeNow(_ pb: CVPixelBuffer) {
        guard let encoder, let session, !stopped else { return }
        let now = Clock.nowMicros()

        // MJPEG is expensive — cap it at ~30 fps.
        if params.codec == "mjpeg", !needKeyframe, now &- lastEncodeMicros < 30_000 { return }

        // Backpressure: if the socket is backed up, skip this frame and resync with an IDR later.
        if session.queuedBytes > backlogLimit {
            dropped += 1
            needKeyframe = true
            return
        }

        let force = needKeyframe
        needKeyframe = false
        if force { lastKeyframeMicros = now }
        lastEncodeMicros = now
        encodedFrames += 1
        encoder.encode(pb, ptsMicros: now, forceKeyframe: force)
    }

    private func deliver(_ data: Data, flags: VideoFlags, pts: UInt64) {
        guard let session else { return }
        let ok = session.sendVideo(ptsMicros: pts, flags: flags, data: data)
        if ok {
            counterLock.lock()
            sentBytes += data.count + 14
            if !flags.contains(.codecConfig) { sentFrames += 1 }
            counterLock.unlock()
        } else {
            // A delta frame was dropped: the decoder needs a fresh IDR.
            videoQueue.async { [weak self] in
                self?.dropped += 1
                self?.needKeyframe = true
            }
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
            self.counterLock.lock()
            let bytes = self.sentBytes, frames = self.sentFrames
            self.sentBytes = 0; self.sentFrames = 0
            self.counterLock.unlock()
            let stats = LiveStats(captureFps: Double(self.capturedFrames) / dt,
                                  sentFps: Double(frames) / dt,
                                  encodeMs: self.encoder?.averageEncodeMs ?? 0,
                                  bitrateKbps: Double(bytes) * 8 / 1000 / dt,
                                  droppedFrames: self.dropped)
            self.capturedFrames = 0
            self.encodedFrames = 0
            let msg = StatsMessage(captureFps: (stats.captureFps * 10).rounded() / 10,
                                   encodeMs: (stats.encodeMs * 10).rounded() / 10,
                                   bitrateKbps: stats.bitrateKbps.rounded())
            self.session?.sendJSON(.stats, msg)
            let cb = self.onStats
            DispatchQueue.main.async { cb?(stats) }
        }
        statsTimer = st
        st.resume()
    }
}
