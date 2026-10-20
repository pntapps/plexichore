import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Common interface for the H.264 and MJPEG encoders.
protocol VideoEncoder: AnyObject {
    /// `onPacket(data, flags, ptsMicros)` — data is ready to put in a VIDEO message.
    var onPacket: ((Data, VideoFlags, UInt64) -> Void)? { get set }
    func encode(_ pixelBuffer: CVPixelBuffer, ptsMicros: UInt64, forceKeyframe: Bool)
    func setBitrate(kbps: Int)
    func invalidate()
    /// Average time spent encoding one frame (ms), for STATS.
    var averageEncodeMs: Double { get }
}

enum EncoderError: LocalizedError {
    case sessionCreation(OSStatus)
    var errorDescription: String? {
        switch self {
        case .sessionCreation(let s): return "Could not create the H.264 encoder (VideoToolbox status \(s))."
        }
    }
}

/// VideoToolbox H.264, real-time, low latency, no B-frames, Annex-B output.
/// Every keyframe is preceded by a separate codec-config packet (SPS+PPS, flag bit1).
final class H264Encoder: VideoEncoder, @unchecked Sendable {
    var onPacket: ((Data, VideoFlags, UInt64) -> Void)?

    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int
    private let fps: Int
    private let lock = NSLock()
    private var encodeStart: [UInt64: UInt64] = [:]   // pts -> wall micros
    private var emaEncodeMs: Double = 0

    private static let startCode: [UInt8] = [0, 0, 0, 1]

    var averageEncodeMs: Double {
        lock.lock(); defer { lock.unlock() }
        return emaEncodeMs
    }

    init(width: Int, height: Int, fps: Int, bitrateKbps: Int, quality: String, keyframeIntervalSeconds: Double) throws {
        self.width = width
        self.height = height
        self.fps = max(1, fps)

        var spec: [CFString: Any] = [
            kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true
        ]
        // Low-latency rate control (macOS 11.3+; our minimum is 13).
        spec[kVTVideoEncoderSpecification_EnableLowLatencyRateControl] = true

        var created: VTCompressionSession?
        var status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: Int32(width),
            height: Int32(height),
            codecType: kCMVideoCodecType_H264,
            encoderSpecification: spec as CFDictionary,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: nil,
            refcon: nil,
            compressionSessionOut: &created)
        if status != noErr || created == nil {
            // Retry without low-latency mode (e.g. unusual sizes the LL encoder rejects).
            created = nil
            status = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault,
                width: Int32(width),
                height: Int32(height),
                codecType: kCMVideoCodecType_H264,
                encoderSpecification: nil,
                imageBufferAttributes: nil,
                compressedDataAllocator: nil,
                outputCallback: nil,
                refcon: nil,
                compressionSessionOut: &created)
        }
        guard status == noErr, let s = created else { throw EncoderError.sessionCreation(status) }
        session = s

        set(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)
        let profile: CFString = quality == "performance"
            ? kVTProfileLevel_H264_Main_AutoLevel
            : kVTProfileLevel_H264_High_AutoLevel
        set(s, kVTCompressionPropertyKey_ProfileLevel, profile)
        set(s, kVTCompressionPropertyKey_H264EntropyMode, kVTH264EntropyMode_CABAC)
        set(s, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: self.fps))
        let interval = max(1.0, keyframeIntervalSeconds)
        set(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int(Double(self.fps) * interval)))
        set(s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: interval))
        set(s, kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse)
        if quality == "performance" {
            set(s, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        }
        applyBitrate(s, kbps: bitrateKbps)
        VTCompressionSessionPrepareToEncodeFrames(s)
    }

    deinit {
        invalidate()
    }

    @discardableResult
    private func set(_ s: VTCompressionSession, _ key: CFString, _ value: CFTypeRef?) -> OSStatus {
        VTSessionSetProperty(s, key: key, value: value)
    }

    private func applyBitrate(_ s: VTCompressionSession, kbps: Int) {
        let bps = max(500, kbps) * 1000
        set(s, kVTCompressionPropertyKey_AverageBitRate, NSNumber(value: bps))
        // Hard cap: 1.5x the average over a 1 s window (bytes, seconds).
        let bytesPerSecond = Double(bps) * 1.5 / 8.0
        let limits = [NSNumber(value: bytesPerSecond), NSNumber(value: 1.0)] as CFArray
        set(s, kVTCompressionPropertyKey_DataRateLimits, limits)
    }

    func setBitrate(kbps: Int) {
        guard let s = session else { return }
        applyBitrate(s, kbps: kbps)
    }

    func invalidate() {
        guard let s = session else { return }
        session = nil
        VTCompressionSessionCompleteFrames(s, untilPresentationTimeStamp: .invalid)
        VTCompressionSessionInvalidate(s)
    }

    func encode(_ pixelBuffer: CVPixelBuffer, ptsMicros: UInt64, forceKeyframe: Bool) {
        guard let s = session else { return }
        let pts = CMTime(value: CMTimeValue(ptsMicros), timescale: 1_000_000)
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        var props: CFDictionary?
        if forceKeyframe {
            props = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue as Any] as CFDictionary
        }
        lock.lock()
        encodeStart[ptsMicros] = Clock.nowMicros()
        if encodeStart.count > 64 { encodeStart.removeAll(keepingCapacity: true) }
        lock.unlock()

        let status = VTCompressionSessionEncodeFrame(
            s,
            imageBuffer: pixelBuffer,
            presentationTimeStamp: pts,
            duration: duration,
            frameProperties: props,
            infoFlagsOut: nil
        ) { [weak self] encodeStatus, infoFlags, sampleBuffer in
            guard let self else { return }
            guard encodeStatus == noErr, let sampleBuffer, !infoFlags.contains(.frameDropped) else { return }
            self.handleOutput(sampleBuffer)
        }
        if status != noErr {
            lock.lock(); encodeStart[ptsMicros] = nil; lock.unlock()
        }
    }

    // MARK: Output

    private func handleOutput(_ sampleBuffer: CMSampleBuffer) {
        let ptsTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let ptsMicros: UInt64 = ptsTime.isValid
            ? UInt64(max(0, CMTimeConvertScale(ptsTime, timescale: 1_000_000, method: .roundHalfAwayFromZero).value))
            : Clock.nowMicros()

        lock.lock()
        if let started = encodeStart.removeValue(forKey: ptsMicros) {
            let ms = Double(Clock.nowMicros() &- started) / 1000.0
            emaEncodeMs = emaEncodeMs == 0 ? ms : emaEncodeMs * 0.9 + ms * 0.1
        }
        lock.unlock()

        let isKeyframe = Self.isKeyframe(sampleBuffer)
        guard let format = CMSampleBufferGetFormatDescription(sampleBuffer) else { return }

        var nalLengthSize: Int32 = 4
        if isKeyframe {
            if let config = Self.parameterSets(format, nalLengthSize: &nalLengthSize) {
                onPacket?(config, .codecConfig, ptsMicros)
            }
        } else {
            _ = Self.parameterSetCount(format, nalLengthSize: &nalLengthSize)
        }

        guard let annexB = Self.annexB(from: sampleBuffer, nalLengthSize: Int(nalLengthSize)), !annexB.isEmpty else { return }
        onPacket?(annexB, isKeyframe ? .keyframe : [], ptsMicros)
    }

    private static func isKeyframe(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let array = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as NSArray?,
              let dict = array.firstObject as? NSDictionary else {
            return true   // no attachments => sync sample
        }
        if let notSync = dict[kCMSampleAttachmentKey_NotSync as String] as? Bool {
            return !notSync
        }
        return true
    }

    private static func parameterSetCount(_ format: CMFormatDescription, nalLengthSize: inout Int32) -> Int {
        var count = 0
        let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: &nalLengthSize)
        return st == noErr ? count : 0
    }

    /// SPS + PPS (all parameter sets) in Annex-B form.
    private static func parameterSets(_ format: CMFormatDescription, nalLengthSize: inout Int32) -> Data? {
        let count = parameterSetCount(format, nalLengthSize: &nalLengthSize)
        guard count > 0 else { return nil }
        var out = Data()
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size = 0
            let st = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if st == noErr, let ptr, size > 0 {
                out.append(contentsOf: startCode)
                out.append(ptr, count: size)
            }
        }
        return out.isEmpty ? nil : out
    }

    /// Converts AVCC (length-prefixed NAL units) to Annex-B (start codes).
    private static func annexB(from sampleBuffer: CMSampleBuffer, nalLengthSize: Int) -> Data? {
        guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { return nil }
        let total = CMBlockBufferGetDataLength(block)
        guard total > 0 else { return nil }
        var avcc = Data(count: total)
        let st = avcc.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) -> OSStatus in
            guard let base = raw.baseAddress else { return -1 }
            return CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: total, destination: base)
        }
        guard st == kCMBlockBufferNoErr else { return nil }

        let lenSize = (1...4).contains(nalLengthSize) ? nalLengthSize : 4
        var out = Data(capacity: total + 16)
        avcc.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let bytes = raw.bindMemory(to: UInt8.self)
            var offset = 0
            while offset + lenSize <= total {
                var nalLen = 0
                for i in 0..<lenSize { nalLen = (nalLen << 8) | Int(bytes[offset + i]) }
                offset += lenSize
                guard nalLen > 0, offset + nalLen <= total else { break }
                out.append(contentsOf: startCode)
                out.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[offset..<(offset + nalLen)]))
                offset += nalLen
            }
        }
        return out
    }
}
