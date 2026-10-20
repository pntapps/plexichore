import AppKit
import Combine
import CoreGraphics
import Foundation
import UserNotifications

/// UI-facing summary of a connected tablet.
struct SessionSummary: Identifiable, Equatable {
    enum Phase: String { case handshake = "Connecting", pairing = "Awaiting approval", configuring = "Starting", streaming = "Streaming", error = "Error" }
    let id: UUID
    var deviceName: String
    var model: String
    var address: String
    var isUSB: Bool
    var phase: Phase
    var mode: String = ""
    var width = 0
    var height = 0
    var fps = 0
    var codec = ""
    var bitrateKbps = 0
    var rttMs: Double = 0
    var stats = LiveStats()
}

struct PendingPairing: Identifiable, Equatable {
    let id: UUID          // session id
    let deviceId: String
    let deviceName: String
    let model: String
    let address: String
    let code: String
}

/// The app's brain: owns the server, discovery, USB, virtual display and all sessions.
@MainActor
final class HostController: ObservableObject {
    // MARK: Published UI state
    @Published private(set) var serverStatus = "Starting…"
    @Published private(set) var serverListening = false
    @Published private(set) var sessions: [SessionSummary] = []
    @Published private(set) var pendingPairings: [PendingPairing] = []
    @Published private(set) var trustedDevices: [TrustedDevice] = TrustedDeviceStore.load()
    @Published private(set) var screenRecordingGranted = Permissions.screenRecordingGranted
    @Published private(set) var accessibilityGranted = Permissions.accessibilityGranted
    @Published private(set) var launchAtLogin = LaunchAtLogin.isEnabled
    @Published private(set) var lastMessage: String?
    @Published private(set) var localAddresses: [String] = []
    @Published var prefs = HostPreferences.load() {
        didSet {
            prefs.save()
            if prefs.wifiDiscovery != oldValue.wifiDiscovery {
                prefs.wifiDiscovery ? beacon.start() : beacon.stop()
            }
        }
    }

    let virtualDisplaySupported: Bool
    let hostName: String
    let adb: ADBManager

    /// Hook for the window manager (show the main window, e.g. for pairing approval).
    var presentMainWindow: (() -> Void)?

    // MARK: Internals
    private let server = HostServer()
    private let beacon: DiscoveryBeacon

    private let virtualDisplays: VirtualDisplayManager
    private var contexts: [UUID: SessionContext] = [:]
    private var activeId: UUID?
    private var destroyDisplayTask: Task<Void, Never>?
    private var permissionTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let supported = VirtualDisplayManager.isSupported
        let name = HostIdentity.computerName
        virtualDisplaySupported = supported
        hostName = name
        adb = ADBManager()
        virtualDisplays = VirtualDisplayManager()
        beacon = DiscoveryBeacon(payloadProvider: Self.makeBeaconProvider(
            id: HostIdentity.id, name: name, virtualDisplay: supported))
        // Forward ADB changes so views observing the controller refresh too.
        adb.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    /// Built in a nonisolated context so the closure can run on the discovery queue.
    nonisolated private static func makeBeaconProvider(id: String, name: String, virtualDisplay: Bool) -> @Sendable () -> Data {
        let payload = (try? JSONEncoder().encode(BeaconMessage(id: id, name: name, virtualDisplay: virtualDisplay))) ?? Data()
        return { payload }
    }

    // MARK: Startup

    func start() {
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.serverStateChanged(state) }
        }
        server.onNewSession = { [weak self] session in
            Task { @MainActor in self?.accept(session) }
        }
        server.start()

        beacon.onError = { [weak self] msg in
            Task { @MainActor in self?.lastMessage = msg }
        }
        if prefs.wifiDiscovery { beacon.start() }
        adb.start()

        refreshPermissions()
        refreshAddresses()
        let t = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshPermissions()
                self?.refreshAddresses()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        permissionTimer = t

        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
    }

    func shutdown() {
        for ctx in contexts.values {
            ctx.session.close(reason: "Host is shutting down")
        }
        server.stop()
        beacon.stop()
        virtualDisplays.destroy()
    }

    private func serverStateChanged(_ state: HostServer.State) {
        switch state {
        case .stopped: serverStatus = "Stopped"; serverListening = false
        case .starting: serverStatus = "Starting…"; serverListening = false
        case .listening: serverStatus = "Listening on port \(PlexiProtocol.tcpPort)"; serverListening = true
        case .failed(let msg): serverStatus = msg; serverListening = false
        }
    }

    func refreshPermissions() {
        let sr = Permissions.screenRecordingGranted
        let ax = Permissions.accessibilityGranted
        if sr != screenRecordingGranted { screenRecordingGranted = sr }
        if ax != accessibilityGranted { accessibilityGranted = ax }
        let login = LaunchAtLogin.isEnabled
        if login != launchAtLogin { launchAtLogin = login }
    }

    private func refreshAddresses() {
        let list = DiscoveryBeacon.localIPv4Addresses().map { "\($0.address) (\($0.interface))" }
        if list != localAddresses { localAddresses = list }
    }

    // MARK: User actions

    func requestScreenRecording() {
        if !Permissions.requestScreenRecording() { Permissions.openScreenRecordingSettings() }
        refreshPermissions()
    }

    func requestAccessibility() {
        if !Permissions.requestAccessibility() { Permissions.openAccessibilitySettings() }
        refreshPermissions()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        if let err = LaunchAtLogin.set(enabled) { lastMessage = err }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    func removeTrusted(_ device: TrustedDevice) {
        trustedDevices.removeAll { $0.deviceId == device.deviceId }
        TrustedDeviceStore.save(trustedDevices)
    }

    func disconnect(_ id: UUID) {
        contexts[id]?.session.close(reason: "Disconnected from the Mac")
    }

    func disconnectAll() {
        for ctx in contexts.values { ctx.session.close(reason: "Disconnected from the Mac") }
    }

    func approvePairing(_ id: UUID) {
        guard let ctx = contexts[id], let hello = ctx.hello, let code = ctx.pairingCode else { return }
        pendingPairings.removeAll { $0.id == id }
        ctx.approved = true
        ctx.session.sendJSON(.pairing, PairingMessage(status: "approved", code: code))
        if let deviceId = hello.deviceId, !deviceId.isEmpty {
            let now = Date()
            trustedDevices.removeAll { $0.deviceId == deviceId }
            trustedDevices.append(TrustedDevice(deviceId: deviceId, name: hello.deviceName ?? "Tablet",
                                                model: hello.model, addedAt: now, lastSeen: now))
            TrustedDeviceStore.save(trustedDevices)
        }
        beginStreaming(ctx)
    }

    func rejectPairing(_ id: UUID) {
        guard let ctx = contexts[id] else { return }
        pendingPairings.removeAll { $0.id == id }
        ctx.session.sendJSON(.pairing, PairingMessage(status: "rejected", code: ctx.pairingCode ?? ""))
        ctx.session.close(reason: "Connection rejected on the Mac")
    }

    // MARK: Sessions

    private func accept(_ session: ClientSession) {
        let ctx = SessionContext(session: session)
        contexts[session.id] = ctx
        sessions.append(SessionSummary(id: session.id, deviceName: "Tablet", model: "",
                                       address: session.remoteDescription, isUSB: session.isLoopback,
                                       phase: .handshake))

        session.onMessage = { [weak self, weak ctx] _, type, payload in
            guard let ctx else { return }
            // Hot path stays on the session queue.
            switch type {
            case .input:
                ctx.handleInput(payload)
            case .key:
                ctx.handleKey(payload)
            case .requestKeyframe:
                ctx.requestKeyframe()
            case .hello:
                let hello = try? JSONDecoder().decode(HelloMessage.self, from: payload)
                Task { @MainActor in self?.handleHello(ctx, hello) }
            case .settings:
                let partial = try? JSONDecoder().decode(RequestedSettings.self, from: payload)
                Task { @MainActor in self?.handleSettings(ctx, partial) }
            default:
                break   // CONFIG/VIDEO/STATS/PAIRING are host→tablet only
            }
        }
        session.onRTT = { [weak self] s, rtt in
            Task { @MainActor in self?.updateSummary(s.id) { $0.rttMs = rtt } }
        }
        session.onClose = { [weak self] s, reason in
            Task { @MainActor in self?.sessionClosed(s.id, reason: reason) }
        }
        session.start()

        // HELLO must arrive promptly.
        Task { @MainActor [weak ctx] in
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            guard let ctx, ctx.hello == nil, !ctx.session.isClosed else { return }
            ctx.session.close(reason: "No HELLO received")
        }
    }

    private func handleHello(_ ctx: SessionContext, _ hello: HelloMessage?) {
        guard contexts[ctx.id] != nil, ctx.hello == nil else { return }
        guard let hello else {
            ctx.session.close(reason: "Malformed HELLO")
            return
        }
        if let v = hello.protocol, v != PlexiProtocol.version {
            ctx.session.close(reason: "Unsupported protocol version \(v) (host speaks \(PlexiProtocol.version))")
            return
        }
        ctx.hello = hello
        ctx.requested = RequestedSettings.defaults.merged(with: hello.requested ?? RequestedSettings())
        updateSummary(ctx.id) {
            $0.deviceName = hello.deviceName ?? "Tablet"
            $0.model = hello.model ?? ""
        }

        let deviceId = hello.deviceId ?? ""
        let trusted = !deviceId.isEmpty && trustedDevices.contains { $0.deviceId == deviceId }
        if ctx.session.isLoopback || trusted || !prefs.requirePairing {
            ctx.approved = true
            if trusted, let i = trustedDevices.firstIndex(where: { $0.deviceId == deviceId }) {
                trustedDevices[i].lastSeen = Date()
                TrustedDeviceStore.save(trustedDevices)
            }
            beginStreaming(ctx)
            return
        }

        // Unknown Wi-Fi tablet → pairing approval.
        let code = String(format: "%04d", Int.random(in: 0...9999))
        ctx.pairingCode = code
        ctx.session.sendJSON(.pairing, PairingMessage(status: "waiting", code: code))
        updateSummary(ctx.id) { $0.phase = .pairing }
        let pending = PendingPairing(id: ctx.id, deviceId: deviceId, deviceName: hello.deviceName ?? "Tablet",
                                     model: hello.model ?? "", address: ctx.session.remoteHost, code: code)
        pendingPairings.append(pending)
        notifyPairing(pending)
        presentMainWindow?()

        // Auto-reject after 2 minutes.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 120_000_000_000)
            guard let self, self.pendingPairings.contains(where: { $0.id == pending.id }) else { return }
            self.rejectPairing(pending.id)
        }
    }

    private func handleSettings(_ ctx: SessionContext, _ partial: RequestedSettings?) {
        guard let partial, contexts[ctx.id] != nil, ctx.approved else { return }
        ctx.requested = ctx.requested.merged(with: partial)
        guard ctx.isStreaming || ctx.isConfiguring else { return }
        if ctx.isConfiguring {
            ctx.pendingReconfigure = true
            return
        }
        Task { await self.configure(ctx, isUpdate: true) }
    }

    private func sessionClosed(_ id: UUID, reason: String) {
        guard let ctx = contexts.removeValue(forKey: id) else { return }
        pendingPairings.removeAll { $0.id == id }
        sessions.removeAll { $0.id == id }
        ctx.isStreaming = false
        ctx.setInputTarget(displayID: nil, touchMode: "none")
        if let p = ctx.pipeline {
            ctx.pipeline = nil
            Task { await p.stop() }
        }
        if activeId == id {
            activeId = nil
            scheduleVirtualDisplayTeardown()
        }
        let name = ctx.hello?.deviceName ?? ctx.session.remoteDescription
        lastMessage = "\(name) disconnected: \(reason)"
    }

    /// Keep the virtual display for a few seconds so a quick reconnect (rotation, Wi-Fi blip)
    /// does not reshuffle the user's windows.
    private func scheduleVirtualDisplayTeardown() {
        destroyDisplayTask?.cancel()
        destroyDisplayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, self.activeId == nil else { return }
            self.virtualDisplays.destroy()
        }
    }

    // MARK: Streaming

    private func beginStreaming(_ ctx: SessionContext) {
        // One tablet streams at a time: the newest wins.
        if let current = activeId, current != ctx.id, let other = contexts[current] {
            other.session.close(reason: "Another tablet connected to this Mac")
        }
        activeId = ctx.id
        destroyDisplayTask?.cancel()
        destroyDisplayTask = nil

        if !Permissions.screenRecordingGranted {
            Permissions.requestScreenRecording()
            refreshPermissions()
            if !Permissions.screenRecordingGranted {
                lastMessage = "Grant Screen Recording permission to PlexiChore, then reconnect the tablet."
                presentMainWindow?()
                ctx.session.close(reason: "Screen Recording permission is not granted on the Mac. Open PlexiChore on the Mac to allow it.")
                return
            }
        }
        if !Permissions.accessibilityGranted {
            Permissions.requestAccessibility()   // input will start working once granted
        }
        Task { await self.configure(ctx, isUpdate: false) }
    }

    /// Computes stream parameters, (re)creates the display + pipeline, sends CONFIG.
    private func configure(_ ctx: SessionContext, isUpdate: Bool) async {
        guard let hello = ctx.hello, contexts[ctx.id] != nil else { return }
        ctx.isConfiguring = true
        updateSummary(ctx.id) { $0.phase = .configuring }
        defer { ctx.isConfiguring = false }

        let req = ctx.requested
        let supported = ["h264", "mjpeg"]
        var tabletCodecs = (hello.codecs ?? []).map { $0.lowercased() }
        if tabletCodecs.isEmpty { tabletCodecs = ["h264"] }
        var codec = (req.codec ?? "h264").lowercased()
        if !supported.contains(codec) || !tabletCodecs.contains(codec) {
            codec = tabletCodecs.first(where: { supported.contains($0) }) ?? "h264"
        }
        let fps = min(max(req.fps ?? 60, 15), max(15, prefs.maxFps))
        let bitrate = min(max(req.bitrateKbps ?? 20_000, 1_000), 150_000)
        let quality = req.quality ?? "balanced"
        let touchMode = req.touchMode ?? "touch"

        let tabletW = max(320, hello.widthPx ?? 1920)
        let tabletH = max(240, hello.heightPx ?? 1200)
        let maxW = max(640, hello.maxDecodeWidth ?? 3840)
        let maxH = max(480, hello.maxDecodeHeight ?? 2160)

        var mode = (req.mode ?? "extend").lowercased()
        var width = 0, height = 0
        var displayID: CGDirectDisplayID = CGMainDisplayID()

        if mode == "extend" && virtualDisplaySupported && prefs.allowVirtualDisplay {
            let scale = min(max(req.resolutionScale ?? 1.0, 0.5), 1.0)
            var (w, h) = Self.fit(width: Double(tabletW) * scale, height: Double(tabletH) * scale,
                                  maxWidth: Double(maxW), maxHeight: Double(maxH))
            if prefs.hiDPI { w -= w % 4; h -= h % 4 }   // keep the 2x point size integral & even
            let ppi = Double(hello.densityDpi ?? 220) * (Double(w) / Double(tabletW))
            let placement = DisplayPlacement(rawValue: (req.position ?? "right").lowercased()) ?? .right
            do {
                displayID = try await virtualDisplays.ensureDisplay(
                    name: "PlexiChore – \(hello.deviceName ?? "Tablet")",
                    pixelWidth: w, pixelHeight: h, ppi: max(72, ppi), hiDPI: prefs.hiDPI,
                    refreshRate: Double(min(fps, 120)), placement: placement)
                width = w
                height = h
            } catch {
                lastMessage = "Extended display unavailable (\(error.localizedDescription)) — mirroring instead."
                mode = "mirror"
            }
        } else if mode == "extend" {
            mode = "mirror"
        }

        if mode != "extend" {
            mode = "mirror"
            if virtualDisplays.display != nil && activeId == ctx.id { virtualDisplays.destroy() }
            let displays = DisplayCatalog.activeDisplays()
            let index = req.monitorIndex ?? 0
            let target = displays.first(where: { $0.index == index }) ?? displays.first
            guard let target else {
                ctx.session.close(reason: "No display to mirror")
                return
            }
            displayID = target.id
            // Fit the display into the tablet panel (never upscale beyond the display itself).
            let boxW = min(Double(tabletW), Double(target.pixelWidth))
            let boxH = min(Double(tabletH), Double(target.pixelHeight))
            let aspect = Double(target.pixelWidth) / Double(max(1, target.pixelHeight))
            var w = boxW, h = boxW / aspect
            if h > boxH { h = boxH; w = boxH * aspect }
            (width, height) = Self.fit(width: w, height: h, maxWidth: Double(maxW), maxHeight: Double(maxH))
        }

        // Session might have gone away while we awaited the display.
        guard contexts[ctx.id] != nil, !ctx.session.isClosed else { return }

        let newParams = StreamParameters(codec: codec, width: width, height: height, fps: fps,
                                         bitrateKbps: bitrate, quality: quality, mode: mode,
                                         displayID: displayID, periodicKeyframes: prefs.periodicKeyframes)
        let config = ConfigMessage(codec: codec, width: width, height: height, fps: fps, bitrateKbps: bitrate,
                                   mode: mode, hostName: hostName, hostOs: "macos",
                                   monitors: DisplayCatalog.monitorInfos(),
                                   virtualDisplayAvailable: virtualDisplaySupported && prefs.allowVirtualDisplay)

        // Bitrate-only change → live update, no restart.
        if isUpdate, let old = ctx.params, let pipeline = ctx.pipeline {
            var cmp = old; cmp.bitrateKbps = newParams.bitrateKbps
            if cmp == newParams {
                pipeline.setBitrate(kbps: bitrate)
                ctx.params = newParams
                ctx.config = config
                ctx.session.sendJSON(.config, config)
                ctx.setInputTarget(displayID: displayID, touchMode: touchMode)
                finishConfigure(ctx, config: config)
                return
            }
        }

        // Full (re)start.
        ctx.isStreaming = false
        if let old = ctx.pipeline {
            ctx.pipeline = nil
            await old.stop()
        }
        guard contexts[ctx.id] != nil, !ctx.session.isClosed else { return }

        ctx.params = newParams
        ctx.config = config
        ctx.session.sendJSON(.config, config)

        let pipeline = StreamPipeline(session: ctx.session, params: newParams)
        let ctxId = ctx.id
        pipeline.onStats = { [weak self] stats in
            Task { @MainActor in self?.updateSummary(ctxId) { $0.stats = stats } }
        }
        pipeline.onFailure = { [weak self, weak ctx] message in
            Task { @MainActor in
                self?.lastMessage = message
                ctx?.session.close(reason: message)
            }
        }
        ctx.pipeline = pipeline
        do {
            try await pipeline.start()
        } catch {
            ctx.pipeline = nil
            await pipeline.stop()
            lastMessage = error.localizedDescription
            updateSummary(ctx.id) { $0.phase = .error }
            ctx.session.close(reason: "Mac could not start streaming: \(error.localizedDescription)")
            return
        }
        guard contexts[ctx.id] != nil, !ctx.session.isClosed else {
            await pipeline.stop()
            return
        }
        ctx.setInputTarget(displayID: displayID, touchMode: touchMode)
        ctx.isStreaming = true
        finishConfigure(ctx, config: config)
    }

    private func finishConfigure(_ ctx: SessionContext, config: ConfigMessage) {
        updateSummary(ctx.id) {
            $0.phase = .streaming
            $0.mode = config.mode
            $0.width = config.width
            $0.height = config.height
            $0.fps = config.fps
            $0.codec = config.codec
            $0.bitrateKbps = config.bitrateKbps
        }
        if ctx.pendingReconfigure {
            ctx.pendingReconfigure = false
            Task { await self.configure(ctx, isUpdate: true) }
        }
    }

    /// Scales (w, h) down to fit within (maxWidth, maxHeight) preserving aspect; returns even ints.
    static func fit(width: Double, height: Double, maxWidth: Double, maxHeight: Double) -> (Int, Int) {
        var w = width, h = height
        let s = min(1.0, maxWidth / w, maxHeight / h)
        w *= s; h *= s
        var wi = Int(w.rounded(.down)), hi = Int(h.rounded(.down))
        wi -= wi % 2; hi -= hi % 2
        return (max(wi, 128), max(hi, 128))
    }

    // MARK: Helpers

    private func updateSummary(_ id: UUID, _ change: (inout SessionSummary) -> Void) {
        guard let i = sessions.firstIndex(where: { $0.id == id }) else { return }
        var s = sessions[i]
        change(&s)
        if s != sessions[i] { sessions[i] = s }
    }

    var activeSummary: SessionSummary? {
        guard let id = activeId else { return sessions.first }
        return sessions.first { $0.id == id }
    }

    private func notifyPairing(_ p: PendingPairing) {
        NSApp.requestUserAttention(.criticalRequest)
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(p.deviceName) wants to connect"
        content.body = "Pairing code \(p.code). Open PlexiChore to approve."
        content.sound = .default
        let req = UNNotificationRequest(identifier: p.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }
    }
}
