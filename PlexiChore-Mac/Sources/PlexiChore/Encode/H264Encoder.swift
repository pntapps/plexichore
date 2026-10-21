import Foundation
import CoreMedia
import CoreVideo
import VideoToolbox

/// Common interface for the H.264 and MJPEG encoders.
protocol VideoEncoder: AnyObject {
    /// `onPacket(data, flags, ptsMicros)` — data is ready to put in a VIDEO message.
    var onPacket: ((Data, VideoFlags, UInt64) -> Void)? { get set }
    /// Asynchronous encoder failure ("encoder:<message>", Windows `MfH264Encoder.Error`). Called at most once.
    var onError: ((String) -> Void)? { get set }
    func encode(_ pixelBuffer: CVPixelBuffer, ptsMicros: UInt64, forceKeyframe: Bool)
    func setBitrate(kbps: Int)
    /// Cadence-only change (no new stream / IDR).
    func setFrameRate(_ fps: Int)
    func invalidate()
    /// Average time spent encoding one frame (ms), for STATS.
    var averageEncodeMs: Double { get }
    /// CONFIG `encoder` (informational), Windows format: "hw:<name>" | "sw:<name>".
    var name: String { get }
    var isHardware: Bool { get }
    /// "h264" | "mjpeg" (CONFIG `codec`).
    var codec: String { get }
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
/// Every keyframe is preceded by a separate codec-config packet (SPS+PPS, flag bit1) — same split as Windows
/// `MfH264Encoder.EmitAnnexB` (the IDR access unit itself carries no SPS/PPS).
final class H264Encoder: VideoEncoder, @unchecked Sendable {
    var onPacket: ((Data, VideoFlags, UInt64) -> Void)?
    var onError: ((String) -> Void)?

    private var session: VTCompressionSession?
    private let width: Int
    private let height: Int
    private var fps: Int
    private let keyframeIntervalSeconds: Double
    private let lock = NSLock()
    private var encodeStart: [UInt64: UInt64] = [:]   // pts -> wall micros
    private var emaEncodeMs: Double = 0
    private var consecutiveErrors = 0
    private var errorReported = false

    let isHardware: Bool
    let name: String
    let codec = "h264"

    private static let startCode: [UInt8] = [0, 0, 0, 1]
    /// kVTInvalidSessionErr: the session died (GPU reset, sleep/wake) — no point retrying frames.
    private static let invalidSession: OSStatus = -12903
    private static let maxConsecutiveErrors = 3

    var averageEncodeMs: Double {
        lock.lock(); defer { lock.unlock() }
        return emaEncodeMs
    }

    /// `allowHardware` false forces Apple's software H.264 encoder (Windows `_disallowHw` after an encoder failure,
    /// or the "Preferred video encoder: software" setting).
    init(width: Int, height: Int, fps: Int, bitrateKbps: Int, quality: String, keyframeIntervalSeconds: Double,
         profile: SessionPolicy.H264Profile = .high, allowHardware: Bool = true) throws {
        self.width = width
        self.height = height
        self.fps = max(1, fps)
        self.keyframeIntervalSeconds = max(1.0, keyframeIntervalSeconds)

        var specs: [[CFString: Any]] = []
        if allowHardware {
            // Low-latency rate control (macOS 11.3+; our minimum is 13), then plain hardware if LL rejects the size.
            // Require… makes the "hw" attempt really hardware (else creation fails and the chain moves on to software).
            specs.append([kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                          kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true,
                          kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true])
            specs.append([kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true,
                          kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true])
        } else {
            specs.append([kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: false])
        }

        var created: VTCompressionSession?
        var status: OSStatus = -1
        for spec in specs {
            created = nil
            status = VTCompressionSessionCreate(
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
            if status == noErr, created != nil { break }
        }
        guard status == noErr, let s = created else { throw EncoderError.sessionCreation(status) }
        session = s

        var hw: CFTypeRef?
        let hwStatus = VTSessionCopyProperty(s, key: kVTCompressionPropertyKey_UsingHardwareAcceleratedVideoEncoder,
                                             allocator: nil, valueOut: &hw)
        let usingHW = hwStatus == noErr ? ((hw as? Bool) ?? (hw as? NSNumber)?.boolValue ?? allowHardware) : allowHardware
        isHardware = usingHW
        // Profile from HELLO h264Profiles (SessionPolicy.h264Profile); level is left to VideoToolbox.
        let level: CFString
        let profileName: String
        switch profile {
        case .high: level = kVTProfileLevel_H264_High_AutoLevel; profileName = "High"
        case .main: level = kVTProfileLevel_H264_Main_AutoLevel; profileName = "Main"
        case .baseline: level = kVTProfileLevel_H264_Baseline_AutoLevel; profileName = "Baseline"
        }
        name = (usingHW ? "hw:" : "sw:") + "VideoToolbox H.264 \(profileName)"

        set(s, kVTCompressionPropertyKey_RealTime, kCFBooleanTrue)
        set(s, kVTCompressionPropertyKey_AllowFrameReordering, kCFBooleanFalse)

        set(s, kVTCompressionPropertyKey_ProfileLevel, level)
        // Baseline has no CABAC.
        set(s, kVTCompressionPropertyKey_H264EntropyMode, profile == .baseline ? kVTH264EntropyMode_CAVLC : kVTH264EntropyMode_CABAC)
        set(s, kVTCompressionPropertyKey_MaximizePowerEfficiency, kCFBooleanFalse)
        if quality == "performance" {
            set(s, kVTCompressionPropertyKey_PrioritizeEncodingSpeedOverQuality, kCFBooleanTrue)
        }
        applyFrameRate(s)
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

    private func applyFrameRate(_ s: VTCompressionSession) {
        set(s, kVTCompressionPropertyKey_ExpectedFrameRate, NSNumber(value: fps))
        set(s, kVTCompressionPropertyKey_MaxKeyFrameInterval, NSNumber(value: Int(Double(fps) * keyframeIntervalSeconds)))
        set(s, kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, NSNumber(value: keyframeIntervalSeconds))
    }

    func setFrameRate(_ newFps: Int) {
        guard let s = session else { return }
        lock.lock(); fps = max(1, newFps); lock.unlock()
        applyFrameRate(s)
    }

    /// Counts failures; reports "encoder:..." once after a dead session or a few failures in a row.
    private func noteResult(_ status: OSStatus) {
        lock.lock()
        if status == noErr {
            consecutiveErrors = 0
            lock.unlock()
            return
        }
        consecutiveErrors += 1
        let report = !errorReported && (status == Self.invalidSession || consecutiveErrors >= Self.maxConsecutiveErrors)
        if report { errorReported = true }
        let cb = onError
        lock.unlock()
        if report { cb?("encoder:VideoToolbox status \(status)") }
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
        lock.lock(); let curFps = fps; lock.unlock()
        let duration = CMTime(value: 1, timescale: CMTimeScale(curFps))
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
            self.noteResult(encodeStatus)
            guard encodeStatus == noErr, let sampleBuffer, !infoFlags.contains(.frameDropped) else { return }
            self.handleOutput(sampleBuffer)
        }
        if status != noErr {
            lock.lock(); encodeStart[ptsMicros] = nil; lock.unlock()
            noteResult(status)
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
