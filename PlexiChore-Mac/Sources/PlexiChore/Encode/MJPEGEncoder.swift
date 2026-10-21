import Foundation
import CoreImage
import CoreVideo
import ImageIO

/// MJPEG fallback: every frame is an independent JPEG (always flagged as keyframe). Last step of the encoder
/// fallback chain (hardware H.264 → software H.264 → MJPEG), like Windows `MjpegEncoder` ("sw:WIC JPEG").
final class MJPEGEncoder: VideoEncoder, @unchecked Sendable {
    var onPacket: ((Data, VideoFlags, UInt64) -> Void)?
    var onError: ((String) -> Void)?

    private let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let quality: Double
    private let width: Int
    private let height: Int
    private let lock = NSLock()
    private var emaEncodeMs: Double = 0
    private var valid = true

    let name = "sw:ImageIO JPEG"
    let isHardware = false
    let codec = "mjpeg"

    var averageEncodeMs: Double {
        lock.lock(); defer { lock.unlock() }
        return emaEncodeMs
    }

    /// `width`/`height` = CONFIG size; frames of another size (right after a seamless resize) are scaled to it.
    init(quality: String, width: Int = 0, height: Int = 0) {
        switch quality {
        case "performance": self.quality = 0.5
        case "quality": self.quality = 0.85
        default: self.quality = 0.7
        }
        self.width = width
        self.height = height
    }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsMicros: UInt64, forceKeyframe: Bool) {
        lock.lock(); let ok = valid; lock.unlock()
        guard ok else { return }
        let start = Clock.nowMicros()
        var image = CIImage(cvPixelBuffer: pixelBuffer)
        let ext = image.extent
        if width > 0, height > 0, ext.width > 0, ext.height > 0,
           Int(ext.width) != width || Int(ext.height) != height {
            image = image.transformed(by: CGAffineTransform(scaleX: CGFloat(width) / ext.width,
                                                            y: CGFloat(height) / ext.height))
        }
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [key: quality]) else { return }
        let ms = Double(Clock.nowMicros() &- start) / 1000.0
        lock.lock()
        emaEncodeMs = emaEncodeMs == 0 ? ms : emaEncodeMs * 0.9 + ms * 0.1
        lock.unlock()
        onPacket?(jpeg, .keyframe, ptsMicros)
    }

    func setBitrate(kbps: Int) { /* quality-driven; bitrate not applicable */ }
    func setFrameRate(_ fps: Int) { /* pipeline paces MJPEG */ }

    func invalidate() {
        lock.lock(); valid = false; lock.unlock()
    }
}
