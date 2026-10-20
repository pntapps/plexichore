import Foundation
import CoreImage
import CoreVideo
import ImageIO

/// MJPEG fallback: every frame is an independent JPEG (always flagged as keyframe).
final class MJPEGEncoder: VideoEncoder, @unchecked Sendable {
    var onPacket: ((Data, VideoFlags, UInt64) -> Void)?

    private let context = CIContext(options: [.useSoftwareRenderer: false, .cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    private let quality: Double
    private let lock = NSLock()
    private var emaEncodeMs: Double = 0
    private var valid = true

    var averageEncodeMs: Double {
        lock.lock(); defer { lock.unlock() }
        return emaEncodeMs
    }

    init(quality: String) {
        switch quality {
        case "performance": self.quality = 0.5
        case "quality": self.quality = 0.85
        default: self.quality = 0.7
        }
    }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsMicros: UInt64, forceKeyframe: Bool) {
        lock.lock(); let ok = valid; lock.unlock()
        guard ok else { return }
        let start = Clock.nowMicros()
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let key = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
        guard let jpeg = context.jpegRepresentation(of: image, colorSpace: colorSpace, options: [key: quality]) else { return }
        let ms = Double(Clock.nowMicros() &- start) / 1000.0
        lock.lock()
        emaEncodeMs = emaEncodeMs == 0 ? ms : emaEncodeMs * 0.9 + ms * 0.1
        lock.unlock()
        onPacket?(jpeg, .keyframe, ptsMicros)
    }

    func setBitrate(kbps: Int) { /* quality-driven; bitrate not applicable */ }

    func invalidate() {
        lock.lock(); valid = false; lock.unlock()
    }
}
