import Foundation

/// Pure session decision logic, ported from the Windows Engine so both hosts behave the same
/// (PROTOCOL.md is authoritative). No I/O, no state: every function is deterministic and unit-tested
/// in Tests/PlexiChoreTests. Sources: PlexiChore-Desktop/src/PlexiChore.Engine/Streaming/Session.cs,
/// Session.Scale.cs, DisplayScale.cs, Protocol/Protocol.cs and App/Services/Adb/AdbDevice.cs.
///
/// Rounding note: C# `Math.Round(double)` rounds half to EVEN; the ports use `.toNearestOrEven` to match.
enum SessionPolicy {

    // MARK: - Requested settings (RequestedSettings.Sanitize)

    /// Fully resolved `requested` object (no optionals), the equivalent of Windows' sanitized RequestedSettings.
    struct Request: Equatable {
        var mode: String            // "extend" | "primary" | "mirror"
        var monitorIndex: Int
        var resolutionScale: Double // 0.25...1.0
        var fps: Int                // 5...120
        var bitrateKbps: Int        // 500...200_000
        var quality: String
        var codec: String           // "h264" | "mjpeg"
        var touchMode: String       // "touch" | "mouse" | "none"
        var position: String        // "right" | "left" | "top" | "bottom"
        var scalePercent: Int       // 0 = auto, else a value of `requestableScales`
        var orientation: String     // "landscape" | "portrait"

        var isPortrait: Bool { orientation == "portrait" }
        var isVirtualMode: Bool { mode == "extend" || mode == "primary" }
    }

    /// RequestedSettings.Sanitize (Protocol.cs). Missing fields take the Windows defaults (mode "mirror", fps 60,
    /// 20000 kbps, scale 1.0, ...); merge with the Mac's `RequestedSettings.defaults` first if a different
    /// default is wanted.
    static func sanitize(_ r: RequestedSettings) -> Request {
        let mode: String
        switch r.mode?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "extend": mode = "extend"
        case "primary": mode = "primary"
        default: mode = "mirror"
        }
        let rs = r.resolutionScale ?? 1.0
        let fps = r.fps ?? 60
        let kbps = r.bitrateKbps ?? 20_000
        let touch: String
        switch r.touchMode?.lowercased() {
        case "mouse": touch = "mouse"
        case "none": touch = "none"
        default: touch = "touch"
        }
        let pos: String
        switch r.position?.lowercased() {
        case "left": pos = "left"
        case "top": pos = "top"
        case "bottom": pos = "bottom"
        default: pos = "right"
        }
        let portrait = r.orientation?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "portrait"
        return Request(
            mode: mode,
            monitorIndex: max(0, r.monitorIndex ?? 0),
            resolutionScale: rs.isFinite ? min(max(rs, 0.25), 1.0) : 1.0,
            fps: fps <= 0 ? 60 : min(max(fps, 5), 120),
            bitrateKbps: kbps <= 0 ? 20_000 : min(max(kbps, 500), 200_000),
            quality: r.quality ?? "balanced",
            codec: r.codec?.lowercased() == "mjpeg" ? "mjpeg" : "h264",
            touchMode: touch,
            position: pos,
            scalePercent: sanitizeScaleRequest(r.scalePercent ?? 0),
            orientation: portrait ? "portrait" : "landscape")
    }

    /// DisplayScale.IsScaleOnlyChange: SETTINGS that only changed scalePercent can be applied live
    /// (re-apply scale + resend CONFIG + keyframe) without re-attaching the display or restarting the stream.
    static func isScaleOnlyChange(_ current: Request, _ next: Request) -> Bool {
        if current.scalePercent == next.scalePercent { return false }
        var probe = next
        probe.scalePercent = current.scalePercent
        return probe == current
    }

    /// Session.ReconfigureAsync: extend/primary unless the virtual path already failed in this session
    /// (`extendBroken`), else mirror. The caller still falls back to mirror when no virtual display is available.
    static func effectiveMode(requested: String, extendBroken: Bool) -> String {
        (requested == "extend" || requested == "primary") && !extendBroken ? requested : "mirror"
    }

    // MARK: - Stream size (Session.Even / TabletBox / ClampToDecoder)

    struct Size: Equatable, CustomStringConvertible {
        var width: Int
        var height: Int
        init(_ width: Int, _ height: Int) { self.width = width; self.height = height }
        var longEdge: Int { max(width, height) }
        var shortEdge: Int { min(width, height) }
        var description: String { "\(width)x\(height)" }
    }

    struct StreamTarget: Equatable {
        var size: Size
        var fps: Int
        /// True when the size had to shrink to the largest decode mode (Windows logs this).
        var limitedByDecoder: Bool
    }

    /// Session.Even: rounds (half to even) and clears bit 0; never below 2.
    static func even(_ v: Double) -> Int {
        max(2, Int(v.rounded(.toNearestOrEven)) & ~1)
    }

    /// Session.TabletBox: tablet-sized box (landscape, or portrait when held portrait) times `scale`, shrunk to
    /// maxDecodeWidth/Height compared on long/short edges (decoders accept the rotated limits too). Even sizes.
    static func tabletBox(widthPx: Int?, heightPx: Int?, maxDecodeWidth: Int?, maxDecodeHeight: Int?,
                          scale: Double, portrait: Bool = false) -> Size {
        let tw = (widthPx ?? 0) > 0 ? widthPx! : 1920
        let th = (heightPx ?? 0) > 0 ? heightPx! : 1080
        let longPx = Double(max(tw, th)), shortPx = Double(min(tw, th))
        let w = (portrait ? shortPx : longPx) * scale, h = (portrait ? longPx : shortPx) * scale
        let maxW = (maxDecodeWidth ?? 0) > 0 ? maxDecodeWidth! : 3840
        let maxH = (maxDecodeHeight ?? 0) > 0 ? maxDecodeHeight! : 2160
        let longMax = Double(max(maxW, maxH)), shortMax = Double(min(maxW, maxH))
        let f = min(1.0, min(longMax / max(w, h), shortMax / min(w, h)))
        return Size(even(w * f), even(h * f))
    }

    /// Session.ClampToDecoder: never send a size/fps the decoder can't handle (PROTOCOL.md "Decode capabilities").
    /// If a mode covers the box (long/short edges) keep the size and cap fps at the best covering mode's maxFps
    /// (but never below 30); otherwise shrink to the largest mode with >= 30 fps (or the largest at all).
    /// Without valid `decodeModes`: unchanged.
    static func clampToDecoder(_ box: Size, fps: Int, decodeModes: [DecodeMode]?) -> StreamTarget {
        let modes = (decodeModes ?? []).filter { $0.width > 0 && $0.height > 0 && $0.maxFps > 0 }
        guard !modes.isEmpty else { return StreamTarget(size: box, fps: fps, limitedByDecoder: false) }
        let bl = box.longEdge, bs = box.shortEdge
        func edges(_ m: DecodeMode) -> (l: Int, s: Int) { (max(m.width, m.height), min(m.width, m.height)) }
        let covering = modes.filter { edges($0).l >= bl && edges($0).s >= bs }
        if let maxFps = covering.map(\.maxFps).max() {
            return StreamTarget(size: box, fps: min(fps, max(maxFps, 30)), limitedByDecoder: false)
        }
        // max(by:) keeps the first of equal elements, like LINQ's stable OrderByDescending().First().
        func area(_ m: DecodeMode) -> Int64 { Int64(m.width) * Int64(m.height) }
        let best = modes.filter { $0.maxFps >= 30 }.max(by: { area($0) < area($1) })
            ?? modes.max(by: { area($0) < area($1) })!
        let (ml, ms) = edges(best)
        let f = min(1.0, min(Double(ml) / Double(bl), Double(ms) / Double(bs)))
        return StreamTarget(size: Size(even(Double(box.width) * f), even(Double(box.height) * f)),
                            fps: min(fps, max(best.maxFps, 30)), limitedByDecoder: true)
    }

    /// Session.ReconfigureAsync size step: `ClampToDecoder(TabletBox(resolutionScale, portrait), fps)`.
    /// Mirror mode always passes portrait = false (the Mac desktop is landscape); extend/primary pass
    /// `request.isPortrait`. When the attached display came out in the other orientation, call again with
    /// portrait = (attached height > width) — Windows streams what was attached instead of squeezing it.
    static func streamTarget(hello: HelloMessage, resolutionScale: Double, fps: Int, portrait: Bool) -> StreamTarget {
        let box = tabletBox(widthPx: hello.widthPx, heightPx: hello.heightPx,
                            maxDecodeWidth: hello.maxDecodeWidth, maxDecodeHeight: hello.maxDecodeHeight,
                            scale: resolutionScale, portrait: portrait)
        return clampToDecoder(box, fps: fps, decodeModes: hello.decodeModes)
    }

    /// StreamPipeline.FitSize: `src` scaled into `box` preserving aspect, never upscaled, floored to even (≥ 2).
    /// Mirror mode: the mirrored display's pixel size fitted into `streamTarget(portrait: false).size`.
    static func fitSize(src: Size, box: Size) -> Size {
        guard src.width > 0, src.height > 0, box.width > 0, box.height > 0 else { return box }
        let s = min(1.0, min(Double(box.width) / Double(src.width), Double(box.height) / Double(src.height)))
        return Size(max(2, Int((Double(src.width) * s).rounded(.down)) & ~1),
                    max(2, Int((Double(src.height) * s).rounded(.down)) & ~1))
    }

    /// Host "display scale" setting applied to the resolved scale (Mac-only; HostPreferences.displayScaleMode):
    /// "standard" → always 100 (1x), "hidpi" → 200 when the tablet asks for auto, else what it asked,
    /// anything else ("auto") → `resolved` (SessionPolicy.targetScalePercent).
    static func hostScalePercent(displayScaleMode: String, requested: Int, resolved: Int) -> Int {
        switch displayScaleMode {
        case "standard": return 100
        case "hidpi": return requested > 0 ? resolved : 200
        default: return resolved
        }
    }

    // MARK: - H.264 profile (Session.H264ProfileForTablet)

    /// Raw values are the H.264 profile_idc (= Windows eAVEncH264VProfile values 66/77/100).
    enum H264Profile: Int, Equatable {
        case baseline = 66, main = 77, high = 100
    }

    /// Session.H264ProfileForTablet: High unless the tablet lists profiles and "high" isn't among them; then Main,
    /// else Baseline. (Windows does not use `h264MaxLevel`; it lets the encoder pick the level — on macOS use the
    /// matching `kVTProfileLevel_H264_*_AutoLevel`.)
    static func h264Profile(for profiles: [String]?) -> H264Profile {
        guard let p = profiles, !p.isEmpty else { return .high }
        if p.contains(where: { $0.lowercased() == "high" }) { return .high }
        if p.contains(where: { $0.lowercased() == "main" }) { return .main }
        return .baseline
    }

    /// Codec choice from Session.ReconfigureAsync: MJPEG when requested, after repeated pipeline failures
    /// (`forceMjpeg`), or when the tablet lists codecs without "h264"; else H.264.
    static func codec(requested: String, tabletCodecs: [String]?, forceMjpeg: Bool) -> String {
        let tabletH264 = (tabletCodecs ?? []).isEmpty || tabletCodecs!.contains { $0.lowercased() == "h264" }
        return requested == "mjpeg" || forceMjpeg || !tabletH264 ? "mjpeg" : "h264"
    }

    // MARK: - Display scale (DisplayScale.cs)

    /// DisplayScale.Requestable: values a tablet may request (0 = auto).
    static let requestableScales = [100, 125, 150, 175, 200, 225, 250, 300]
    static let autoScaleMin = 125, autoScaleMax = 250

    /// DisplayScale.Nearest: nearest step, ties go to the smaller step.
    static func nearestStep(_ percent: Double, steps: [Int]) -> Int {
        var best = steps[0]
        var bestDiff = Double.greatestFiniteMagnitude
        for s in steps {
            let d = abs(Double(s) - percent)
            if d < bestDiff - 1e-9 { best = s; bestDiff = d }
        }
        return best
    }

    /// DisplayScale.SanitizeRequest: <= 0 → 0 (auto), else snapped onto `requestableScales`.
    static func sanitizeScaleRequest(_ percent: Int) -> Int {
        percent <= 0 ? 0 : nearestStep(Double(percent), steps: requestableScales)
    }

    /// DisplayScale.Auto: UI the same physical size as the tablet's Android UI: densityDpi/160 ÷ pixelRatio,
    /// nearest step, clamped to 125...250 (100 allowed when pixelRatio > 1.15, i.e. the stream is downscaled).
    /// Unknown density (0): 200 when the short edge is >= 1500 px, else 150.
    static func autoScalePercent(densityDpi: Int, pixelRatio: Double = 1.0, shortEdgePx: Int = 0) -> Int {
        let ratio = pixelRatio.isFinite && pixelRatio >= 1.0 ? pixelRatio : 1.0
        let native = densityDpi > 0 ? Double(densityDpi) / 160.0 : (shortEdgePx >= 1500 ? 2.0 : 1.5)
        let pct = native * 100.0 / ratio
        let lo = ratio > 1.15 ? 100 : autoScaleMin
        return min(max(nearestStep(pct, steps: requestableScales), lo), autoScaleMax)
    }

    /// DisplayScale.Resolve: requested (0 = auto) → concrete percent.
    static func resolveScalePercent(requested: Int, densityDpi: Int, pixelRatio: Double = 1.0, shortEdgePx: Int = 0) -> Int {
        let r = sanitizeScaleRequest(requested)
        return r == 0 ? autoScalePercent(densityDpi: densityDpi, pixelRatio: pixelRatio, shortEdgePx: shortEdgePx) : r
    }

    /// Session.PixelRatio: tablet pixels per virtual-display pixel (long/short edges), never below 1.
    /// On the Mac "virtual-display pixel" = stream pixel (the size the encoder sends).
    static func pixelRatio(tabletWidthPx: Int, tabletHeightPx: Int, virtualWidth: Int, virtualHeight: Int) -> Double {
        let tw = max(tabletWidthPx, tabletHeightPx), th = min(tabletWidthPx, tabletHeightPx)
        let vw = max(virtualWidth, virtualHeight), vh = min(virtualWidth, virtualHeight)
        guard tw > 0, th > 0, vw > 0, vh > 0 else { return 1.0 }
        return max(1.0, min(Double(tw) / Double(vw), Double(th) / Double(vh)))
    }

    /// Session.EnsureScaleAsync's target: resolved percent for a stream of `streamSize` on this tablet.
    static func targetScalePercent(hello: HelloMessage, requested: Int, streamSize: Size) -> Int {
        let w = hello.widthPx ?? 0, h = hello.heightPx ?? 0
        return resolveScalePercent(requested: requested, densityDpi: hello.densityDpi ?? 0,
                                   pixelRatio: pixelRatio(tabletWidthPx: w, tabletHeightPx: h,
                                                          virtualWidth: streamSize.width, virtualHeight: streamSize.height),
                                   shortEdgePx: min(w, h))
    }

    // MARK: - macOS virtual display mode for a scale (Mac-only; no Windows equivalent)

    /// How a scale percent can be realised with CGVirtualDisplay. macOS only has 1x and 2x (HiDPI) backing
    /// scale factors; "scaled" resolutions (e.g. looks-like 1707x1067 on a 2560x1600 panel) are HiDPI modes
    /// whose 2x backing store differs from the panel, resampled to the panel. PXVirtualDisplay already allows that:
    /// it is created with backing pixels (`pixelWidth/Height`) and, when hiDPI, one mode of pixel/2 points.
    enum ScaleStrategy: Equatable {
        /// Backing == stream size: only 100% (1x) and 200% (HiDPI) are possible; other values snap to the nearest
        /// of the two (ties → 100, the Windows "ties go lower" rule). Cheapest, always pixel-exact.
        case nativeOnly
        /// Any requestable value: HiDPI with points = stream / scale and backing = 2 × points; ScreenCaptureKit
        /// must then output the stream size (SCStreamConfiguration width/height) and resamples. Falls back to
        /// `nativeOnly` when the backing's long edge would exceed `maxBackingLongEdge`.
        case scaled(maxBackingLongEdge: Int)

        static let `default` = ScaleStrategy.scaled(maxBackingLongEdge: 6144)
    }

    struct VirtualDisplayMode: Equatable {
        /// Pass to PXVirtualDisplay(pixelWidth:pixelHeight:hiDPI:) — the framebuffer (backing store) size.
        var backing: Size
        /// The "looks like" desktop size in points (= the single CGVirtualDisplayMode when hiDPI).
        var points: Size
        var hiDPI: Bool
        /// Size the encoder sends (CONFIG width/height); differs from `backing` for scaled modes.
        var stream: Size
        /// Effective percent (100 × stream / points, snapped onto `requestableScales`): report it in CONFIG `scalePercent`.
        var scalePercent: Int
        /// Backing != stream: capture must scale to `stream`.
        var needsResample: Bool { backing != stream }
    }

    /// Maps a resolved scale percent (see `resolveScalePercent`) to a CGVirtualDisplay configuration for a stream
    /// of `stream` pixels. 100 → 1x native; 200 → HiDPI native (points = pixels / 2); others per `strategy`.
    static func virtualDisplayMode(stream: Size, scalePercent: Int, strategy: ScaleStrategy = .default) -> VirtualDisplayMode {
        let native1x = VirtualDisplayMode(backing: stream, points: stream, hiDPI: false, stream: stream, scalePercent: 100)
        let native2x = VirtualDisplayMode(backing: stream, points: Size(stream.width / 2, stream.height / 2),
                                          hiDPI: true, stream: stream, scalePercent: 200)
        func snapNative() -> VirtualDisplayMode {
            nearestStep(Double(scalePercent), steps: [100, 200]) == 200 ? native2x : native1x
        }
        let pct = sanitizeScaleRequest(scalePercent)
        if pct <= 100 { return native1x }
        if pct == 200 { return native2x }
        switch strategy {
        case .nativeOnly:
            return snapNative()
        case .scaled(let maxLong):
            let f = Double(pct) / 100.0
            let pts = Size(Int((Double(stream.width) / f).rounded(.toNearestOrEven)),
                           Int((Double(stream.height) / f).rounded(.toNearestOrEven)))
            let backing = Size(pts.width * 2, pts.height * 2)
            if backing.longEdge > maxLong || pts.shortEdge < 32 { return snapNative() }
            return VirtualDisplayMode(backing: backing, points: pts, hiDPI: true, stream: stream, scalePercent: pct)
        }
    }

    /// CONFIG `scalePercent`: the applied display's effective scale in extend/primary, 0 in mirror or when unknown
    /// (Session.ReconfigureAsync: `mode != "mirror" ? _scaleApplied : 0`). Pass what PXVirtualDisplay actually
    /// produced: PXVirtualDisplay retries without HiDPI when a 2x mode is rejected (`actualHiDPI` false), leaving a
    /// 1x display of `backing` points → report 100 × stream / backing snapped onto the steps (100 for native).
    static func configScalePercent(mode: String, applied: VirtualDisplayMode?, actualHiDPI: Bool? = nil) -> Int {
        guard mode != "mirror", let a = applied else { return 0 }
        if a.hiDPI, actualHiDPI == false {
            return nearestStep(100.0 * Double(a.stream.longEdge) / Double(max(1, a.backing.longEdge)), steps: requestableScales)
        }
        return a.scalePercent
    }

    // MARK: - Link classification (Session.NetworkLink / LinkAsync, AdbParser.ReverseLink, AdbDevice)

    enum Link: String, Equatable {
        case usbCable = "usb-cable"
        case usbWirelessAdb = "usb-wireless-adb"
        case usbTether = "usb-tether"
        case wifi = "wifi"
    }

    /// Session ctor `IPAddress.IsLoopback` (after IPv4-mapped → IPv4): 127.0.0.0/8, ::1, ::ffff:127.x.
    /// Accepts bare IPs, "[v6]:port", "v4:port" and "%zone" suffixes.
    static func isLoopback(_ remote: String) -> Bool {
        var s = remote.trimmingCharacters(in: .whitespaces).lowercased()
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") { s = String(s[s.index(after: s.startIndex)..<close]) }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        if s.filter({ $0 == ":" }).count == 1, s.contains(".") { s = String(s[..<s.firstIndex(of: ":")!]) } // v4:port
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        if s == "::1" || s == "0:0:0:0:0:0:0:1" { return true }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts[0] == "127" && parts.allSatisfy { UInt8($0) != nil }
    }

    /// AdbDevice.IsWireless: wireless debugging serial (mDNS "adb-<serial>-<id>._adb-tls-connect._tcp",
    /// "._adb._tcp", or "host:port") vs a physical cable.
    static func isWirelessAdbSerial(_ serial: String) -> Bool {
        let l = serial.lowercased()
        if l.contains("._adb-tls-connect.") || l.contains("._adb._tcp") { return true }
        return serial.range(of: #"^[\w\.\-\[\]:]+:\d{2,5}$"#, options: .regularExpression) != nil
    }

    /// AdbDevice.PhysicalSerial: the hardware serial behind a transport (nil for ip:port wireless serials).
    static func physicalAdbSerial(_ serial: String) -> String? {
        guard isWirelessAdbSerial(serial) else { return serial }
        guard let re = try? NSRegularExpression(pattern: #"^adb-(.+)-[^-.]+\._adb"#, options: .caseInsensitive),
              let m = re.firstMatch(in: serial, range: NSRange(serial.startIndex..., in: serial)),
              let r = Range(m.range(at: 1), in: serial) else { return nil }
        return String(serial[r])
    }

    /// AdbParser.ReverseLink: in `adb -s <serial> reverse --list` output, the transport serving tcp:port →
    /// "UsbFfs ..." = usb-cable, "host-N ..." = usb-wireless-adb; nil when the rule isn't listed.
    static func reverseLink(reverseListOutput: String, port: Int = Int(PlexiProtocol.tcpPort)) -> Link? {
        let needle = "tcp:\(port) tcp:\(port)"
        for raw in reverseListOutput.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard l.lowercased().hasSuffix(needle) else { continue }
            let owner = l.split(whereSeparator: { $0 == " " || $0 == "\t" }).first.map { $0.lowercased() } ?? ""
            if owner.hasPrefix("usb") { return .usbCable }
            if owner.hasPrefix("host") { return .usbWirelessAdb }
            return nil
        }
        return nil
    }

    struct AdbDeviceInfo: Equatable {
        var serial: String
        var state: String     // "device" = ready
        var model: String?    // `adb devices -l` model: (underscores may be spaces already)
    }

    /// AdbManager.ResolveLoopbackLinkAsync: serials to ask `reverse --list`, in order. Ready devices whose model
    /// matches HELLO `model` (case-insensitive, '_' / '-' = ' '), or the only ready device; cables first.
    /// Feed each output to `reverseLink`; the first non-nil answer is the link.
    static func adbLinkCandidates(_ devices: [AdbDeviceInfo], helloModel: String?) -> [String] {
        func norm(_ s: String?) -> String {
            (s ?? "").replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        }
        let ready = devices.filter { $0.state == "device" }
        var mine = ready.filter { norm($0.model) == norm(helloModel) }
        if mine.isEmpty && ready.count == 1 { mine = ready }
        // stable sort: cable (0) before wireless (1)
        return mine.enumerated()
            .sorted { (isWirelessAdbSerial($0.element.serial) ? 1 : 0, $0.offset) < (isWirelessAdbSerial($1.element.serial) ? 1 : 0, $1.offset) }
            .map(\.element.serial)
    }

    /// Session.NetworkLink: non-loopback session → "usb-tether" when the Mac side of the socket is a USB network
    /// interface (Android USB tethering: RNDIS/NCM), else "wifi". Windows matches "NDIS"/"NCM"/"ANDROID"/"USB" in
    /// the adapter description + name; pass the SCNetworkInterface localized display name and BSD name here.
    /// Mac addition: a local address in 192.168.42.0/24 (Android's classic USB-tether subnet) also counts.
    static func networkLink(localAddress: String?, interfaceName: String?, interfaceDisplayName: String?) -> Link {
        let d = ((interfaceDisplayName ?? "") + " " + (interfaceName ?? "")).uppercased()
        if d.contains("NDIS") || d.contains("NCM") || d.contains("ANDROID") || d.contains("USB") { return .usbTether }
        if let a = localAddress?.lowercased().replacingOccurrences(of: "::ffff:", with: ""), a.hasPrefix("192.168.42.") {
            return .usbTether
        }
        return .wifi
    }

    /// Session link resolution in one call. Loopback (adb reverse): the first non-nil `reverseLink` of
    /// `reverseListOutputs` (ordered like `adbLinkCandidates`), nil when unknown → omit `link` from CONFIG.
    /// Otherwise `networkLink`.
    static func classifyLink(remoteAddress: String, localAddress: String?, interfaceName: String?,
                             interfaceDisplayName: String?, reverseListOutputs: [String]) -> Link? {
        if isLoopback(remoteAddress) {
            for out in reverseListOutputs { if let l = reverseLink(reverseListOutput: out) { return l } }
            return nil
        }
        return networkLink(localAddress: localAddress, interfaceName: interfaceName, interfaceDisplayName: interfaceDisplayName)
    }

    // MARK: - Pipeline failure handling (Session.OnPipelineEnded / ReconfigureAsync)

    struct FailureState: Equatable {
        var failures = 0
        var disallowHardware = false
        var forceMjpeg = false
        var extendBroken = false
        /// Capture losses (ScreenCaptureKit), counted apart from encoder failures (Windows only counts those).
        var captureFailures = 0
    }

    /// How long a pipeline must stream before this session's failure counts are forgiven.
    static let healthyStreamReset: TimeInterval = 30

    /// A pipeline streamed `healthyStreamReset` seconds: reset the counters (the escalation flags stay — a broken
    /// hardware encoder doesn't heal by itself).
    static func streamedHealthily(state: inout FailureState) {
        state.failures = 0
        state.captureFailures = 0
    }

    enum FailureAction: Equatable {
        case restart(after: TimeInterval)
        case disconnect
    }

    /// Session.OnPipelineEnded: "encoder:"/"error:" reasons escalate (1st → software encoder, 2nd → MJPEG,
    /// > 6 → disconnect); every end restarts after 0.3 s ("resize") or 1 s.
    /// Mac additions: "capture:" (ScreenCaptureKit stream lost) restarts without escalating the encoder, with its own
    /// > 6 limit (`captureFailures`); "stopped:" (the user stopped screen sharing in macOS) disconnects at once.
    static func onPipelineEnded(reason: String, state: inout FailureState) -> FailureAction {
        if reason.hasPrefix("stopped:") { return .disconnect }
        if reason.hasPrefix("encoder:") || reason.hasPrefix("error:") {
            state.failures += 1
            if state.failures == 1 { state.disallowHardware = true }
            else if state.failures == 2 { state.forceMjpeg = true }
            if state.failures > 6 { return .disconnect }
        } else if reason.hasPrefix("capture:") {
            state.captureFailures += 1
            if state.captureFailures > 6 { return .disconnect }
        }
        return .restart(after: reason == "resize" ? 0.3 : 1.0)
    }

    /// Session.ReconfigureAsync catch: stream start failed → extend/primary marked broken (retry as mirror),
    /// > 6 failures → disconnect, else retry after 1 s.
    static func onStreamStartFailed(mode: String, state: inout FailureState) -> FailureAction {
        if mode != "mirror" { state.extendBroken = true }
        state.failures += 1
        return state.failures > 6 ? .disconnect : .restart(after: 1.0)
    }

    // MARK: - Timing constants (Session.cs)

    static let helloTimeout: TimeInterval = 10
    static let pairingTimeout: TimeInterval = 120
    /// No message from the tablet for this long → end the session ("timeout (no message for 5 s)").
    static let deadAfter: TimeInterval = 5
    /// A keep-alive tick that took longer than this means the host itself stalled: don't blame the tablet.
    static let selfStallThreshold: TimeInterval = 2.5
    /// How long CONFIG waits for the adb link query.
    static let linkQueryWait: TimeInterval = 0.4
    /// Same session rebuilding a pipeline for the same device/size/fps within this window keeps its adaptive level.
    static let levelHintWindow: TimeInterval = 30

    // MARK: - Pre-HELLO connections (Windows Session.RunAsync / CleanupAsync)

    /// Windows raises SessionStarted/SessionEnded (the only things its UI sees) only once a session got its HELLO;
    /// a connection that ends before HELLO ("no HELLO", "HELLO timeout", bad JSON) is logged and nothing else.
    /// The main source is the tablet's USB loopback probe (Android `HostDiscovery.probeUsb`: connect to
    /// 127.0.0.1:47800 through adb reverse, send nothing, close after ~250 ms, every few seconds), which would
    /// otherwise show up as "127.0.0.1:52992 disconnected: Tablet disconnected". Port scans fall in the same bucket.
    static func isVisibleSession(helloReceived: Bool) -> Bool { helloReceived }

    /// Text for the host UI's last message when a session closes; nil = log only (no HELLO yet).
    static func disconnectMessage(deviceName: String?, remote: String, reason: String, helloReceived: Bool) -> String? {
        guard isVisibleSession(helloReceived: helloReceived) else { return nil }
        let name = (deviceName?.isEmpty == false ? deviceName : nil) ?? remote
        return "\(name) disconnected: \(reason)"
    }
}
