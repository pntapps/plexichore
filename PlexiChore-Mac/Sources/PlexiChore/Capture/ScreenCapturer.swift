import Foundation
import CoreGraphics
import CoreMedia
import CoreVideo
import ScreenCaptureKit

enum CaptureError: LocalizedError {
    case permissionDenied
    case displayNotFound(CGDirectDisplayID)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Screen Recording permission is required. Enable PlexiChore in System Settings › Privacy & Security › Screen Recording, then relaunch."
        case .displayNotFound(let id):
            return "Display \(id) is not available for capture."
        }
    }
}

/// ScreenCaptureKit capture of one display, delivering 420v (NV12 video-range) pixel buffers.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    /// Called on `sampleQueue` for each new complete frame.
    var onFrame: ((CVPixelBuffer) -> Void)?
    /// Called (any queue) if the stream stops unexpectedly.
    var onStopped: ((Error) -> Void)?

    let sampleQueue: DispatchQueue
    private var _scStream: SCStream?
    private var _stopRequested = false
    private let stateLock = NSLock()

    private var scStream: SCStream? {
        get { stateLock.lock(); defer { stateLock.unlock() }; return _scStream }
        set { stateLock.lock(); _scStream = newValue; stateLock.unlock() }
    }

    private var stopRequested: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _stopRequested
    }

    init(sampleQueue: DispatchQueue) {
        self.sampleQueue = sampleQueue
        super.init()
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }

        // A freshly created virtual display can take a moment to show up in SCShareableContent.
        var target: SCDisplay?
        for attempt in 0..<20 {
            if stopRequested { throw CancellationError() }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            target = content.displays.first(where: { $0.displayID == displayID })
            if target != nil { break }
            if attempt < 19 { try await Task.sleep(nanoseconds: 250_000_000) }
        }
        guard let display = target else { throw CaptureError.displayNotFound(displayID) }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange   // '420v'
        config.showsCursor = true
        config.queueDepth = 6
        config.colorSpaceName = CGColorSpace.sRGB
        config.capturesAudio = false

        let s = SCStream(filter: filter, configuration: config, delegate: self)
        try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: sampleQueue)
        if stopRequested { throw CancellationError() }
        try await s.startCapture()
        // stop() may have run while startCapture was pending: it found no stream, so stop this one now.
        if !commit(s) {
            try? await s.stopCapture()
            throw CancellationError()
        }
    }

    func stop() async {
        guard let s = requestStop() else { return }
        try? await s.stopCapture()
    }

    /// Keeps `s` as the running stream unless stop() was requested meanwhile (then false).
    private func commit(_ s: SCStream) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        if _stopRequested { return false }
        _scStream = s
        return true
    }

    /// Marks the capturer stopped and hands back the stream to stop, if any.
    private func requestStop() -> SCStream? {
        stateLock.lock(); defer { stateLock.unlock() }
        _stopRequested = true
        let s = _scStream
        _scStream = nil
        return s
    }

    /// Changes fps/size on the fly without restarting the stream.
    func update(width: Int, height: Int, fps: Int) async {
        guard let s = scStream else { return }
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(max(1, fps)))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.showsCursor = true
        config.queueDepth = 6
        config.colorSpaceName = CGColorSpace.sRGB
        try? await s.updateConfiguration(config)
    }

    // MARK: SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, CMSampleBufferIsValid(sampleBuffer) else { return }
        // Only complete frames carry new pixels; idle/blank frames are skipped.
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let info = attachments.first,
              let rawStatus = info[SCStreamFrameInfo.status] as? Int,
              let status = SCFrameStatus(rawValue: rawStatus),
              status == .complete,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        onFrame?(pixelBuffer)
    }

    // MARK: SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.lock()
        let wasCurrent = _scStream === stream
        if wasCurrent { _scStream = nil }
        let stopping = _stopRequested
        stateLock.unlock()
        if wasCurrent && !stopping { onStopped?(error) }
    }
}
