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
    private var scStream: SCStream?

    init(sampleQueue: DispatchQueue) {
        self.sampleQueue = sampleQueue
        super.init()
    }

    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        guard CGPreflightScreenCaptureAccess() else { throw CaptureError.permissionDenied }

        // A freshly created virtual display can take a moment to show up in SCShareableContent.
        var target: SCDisplay?
        for attempt in 0..<20 {
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
        try await s.startCapture()
        scStream = s
    }

    func stop() async {
        guard let s = scStream else { return }
        scStream = nil
        try? await s.stopCapture()
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
        scStream = nil
        onStopped?(error)
    }
}
