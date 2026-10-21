import AppKit
import Combine
import CoreGraphics
import Foundation
import UserNotifications
import os

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
    // ---- additive (read by HostController+UI.swift) ----
    /// When the tablet connected.
    var connectedSince = Date()
    /// CONFIG `link`: "usb-cable" | "usb-wireless-adb" | "usb-tether" | "wifi"; "" = unknown.
    var transportLink = ""
    /// CONFIG `encoder`, e.g. "hw:VideoToolbox H.264 High".
    var encoder = ""
    /// CONFIG `scalePercent` (0 = mirror / unknown).
    var scalePercent = 0
    /// The tablet asked for auto scale (requested.scalePercent == 0).
    var scaleAuto = true
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
    nonisolated private static let log = Logger(subsystem: "com.pntapps.plexichore", category: "Sessions")
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
            if prefs.serverPaused != oldValue.serverPaused {
                if prefs.serverPaused {
                    // Pause (Windows "Pause server"): drop tablets, stop listening and advertising.
                    disconnectAll()
                    server.stop()
                    beacon.stop()
                } else {
                    server.start()
                    if prefs.wifiDiscovery { beacon.start() }
                }
            } else if prefs.wifiDiscovery != oldValue.wifiDiscovery && !prefs.serverPaused {
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
        // A previous run that died in primary mode left the user's main display moved.
        if DisplayArrangement.restoreIfCrashed() {
            lastMessage = "Restored your display arrangement from the last session."
        }
        virtualDisplays.onTerminated = { [weak self] in
            guard let self, let id = self.activeId, let ctx = self.contexts[id],
                  ctx.params?.mode != "mirror" else { return }
            self.lastMessage = "macOS removed the virtual display — recreating it."
            Task { await self.reconfigure(ctx, isUpdate: false, why: "display terminated") }
        }
        // Display state for the UI (create / destroy / safety hold set or expired; fires on main).
        virtualDisplays.onStateChange = { [weak self] in self?.objectWillChange.send() }
        // Display safety net (Display/DisplaySafety.swift).
        virtualDisplays.hasActiveClient = { [weak self] in self?.activeId != nil }
        virtualDisplays.allowVirtualOnly = { [weak self] in self?.prefs.keepWithLidClosed ?? false }
        virtualDisplays.onSafetyRelease = { [weak self] event in
            guard let self else { return }
            self.lastMessage = event.message
            if let id = self.activeId, let ctx = self.contexts[id] {
                // ensureDisplay now fails with .safetyHold / .displaysUnstable / .rateLimited → mirror.
                Task { await self.reconfigure(ctx, isUpdate: true, why: "display safety") }
            }
        }
        virtualDisplays.onShouldRecreate = { [weak self] in
            guard let self, let id = self.activeId, let ctx = self.contexts[id] else { return }
            Task { await self.reconfigure(ctx, isUpdate: false, why: "wake") }
        }
        server.onStateChange = { [weak self] state in
            Task { @MainActor in self?.serverStateChanged(state) }
        }
        server.onNewSession = { [weak self] session in
            Task { @MainActor in self?.accept(session) }
        }
        if !prefs.serverPaused { server.start() } else { serverStatus = "Paused"; serverListening = false }

        beacon.onError = { [weak self] msg in
            Task { @MainActor in self?.lastMessage = msg }
        }
        if prefs.wifiDiscovery && !prefs.serverPaused { beacon.start() }
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
        // Process exit can't await: synchronous form of releaseVirtualDisplay (restores the main display too).
        destroyDisplayTask?.cancel()
        virtualDisplays.destroy()
    }

    private func serverStateChanged(_ state: HostServer.State) {
        switch state {
        case .stopped: serverStatus = prefs.serverPaused ? "Paused" : "Stopped"; serverListening = false
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

    /// Menu item "Release virtual display now" (safety net): removes it immediately and holds re-creation.
    func emergencyReleaseDisplay() {
        virtualDisplays.emergencyRelease()
    }

    /// Seconds left on a safety hold (emergency / sleep / watchdog); nil when the virtual display may be created.
    var displaySafetyHoldRemaining: TimeInterval? { virtualDisplays.safetyHoldRemaining }

    /// True while a PlexiChore virtual display exists.
    var virtualDisplayActive: Bool { virtualDisplays.display != nil }

    /// "Resume now": lift the hold and move the active session back to its requested mode right away.
    func clearDisplaySafetyHold() {
        virtualDisplays.clearSafetyHold()
        if let id = activeId, let ctx = contexts[id] {
            Task { await self.reconfigure(ctx, isUpdate: true, why: "safety hold cleared") }
        }
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
        // Not in `sessions` (UI) until HELLO arrives, like Windows (SessionStarted): the tablet's USB loopback probe
        // connects and closes without a word every few seconds (SessionPolicy.isVisibleSession).
        Self.log.debug("Connection from \(session.remoteDescription, privacy: .public)")

        session.onMessage = { [weak self, weak ctx] _, type, payload in
            guard let ctx else { return }
            // PROTOCOL session flow: HELLO is the first message (Windows: BYE "expected HELLO").
            if ctx.markFirstMessage() && type != .hello {
                ctx.session.close(reason: "expected HELLO")
                return
            }
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
            ctx.session.close(reason: "expected HELLO")
        }
    }

    private func handleHello(_ ctx: SessionContext, _ hello: HelloMessage?) {
        guard contexts[ctx.id] != nil, ctx.hello == nil else { return }
        guard let hello else {
            ctx.session.close(reason: "Malformed HELLO")
            return
        }
        // Protocol changes are additive only: like Windows, any `protocol` value is accepted.
        ctx.hello = hello
        if !sessions.contains(where: { $0.id == ctx.id }) {
            sessions.append(SessionSummary(id: ctx.id, deviceName: hello.deviceName ?? "Tablet", model: hello.model ?? "",
                                           address: ctx.session.remoteDescription, isUSB: ctx.session.isLoopback,
                                           phase: .handshake))
        }
        ctx.requested = RequestedSettings.initial(from: hello)   // no `mode` → mirror (Windows)
        ctx.scaleAuto = (ctx.requested.scalePercent ?? 0) <= 0
        // USB = adb reverse over the cable or over wireless debugging? Asked in parallel (Windows `_linkTask`).
        Task { @MainActor [weak self, weak ctx] in
            guard let self, let ctx else { return }
            let link = await self.classifyLink(ctx)
            ctx.link = link
            ctx.linkResolved = true
            self.updateSummary(ctx.id) { $0.transportLink = link?.rawValue ?? "" }
        }
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

    /// SETTINGS = partial `requested`: merge, then reconfigure (live when the display stays the same: bitrate/fps
    /// without a new IDR, size/codec/quality via a seamless encoder swap; orientation/scale/mode/position recreate
    /// or re-arrange the virtual display). Before approval (pairing) the merge is kept but nothing restarts.
    private func handleSettings(_ ctx: SessionContext, _ partial: RequestedSettings?) {
        guard let partial, contexts[ctx.id] != nil else { return }
        ctx.requested = ctx.requested.merged(with: partial)
        if partial.scalePercent != nil { ctx.scaleAuto = (ctx.requested.scalePercent ?? 0) <= 0 }
        guard ctx.approved, ctx.isStreaming || ctx.isConfiguring else { return }
        Task { await self.reconfigure(ctx, isUpdate: true, why: "settings") }
    }

    private func sessionClosed(_ id: UUID, reason: String) {
        guard let ctx = contexts.removeValue(forKey: id) else { return }
        pendingPairings.removeAll { $0.id == id }
        sessions.removeAll { $0.id == id }
        ctx.isStreaming = false
        ctx.setInputTarget(displayID: nil, touchMode: "none")
        ctx.pipelineGeneration += 1
        if let p = ctx.pipeline {
            ctx.pipeline = nil
            p.onEnded = nil
            Task { await p.stop() }
        }
        if activeId == id {
            activeId = nil
            scheduleVirtualDisplayTeardown()
        }
        if let msg = SessionPolicy.disconnectMessage(deviceName: ctx.hello?.deviceName, remote: ctx.session.remoteDescription,
                                                     reason: reason, helloReceived: ctx.hello != nil) {
            lastMessage = msg
        } else {
            // USB probe / port scan: log only (Windows logs "Session … ended: no HELLO" and raises nothing).
            Self.log.debug("\(ctx.session.remoteDescription, privacy: .public) closed before HELLO: \(reason, privacy: .public)")
        }
    }

    /// Keep the virtual display for a few seconds so a quick reconnect (rotation, Wi-Fi blip)
    /// does not reshuffle the user's windows.
    private func scheduleVirtualDisplayTeardown() {
        destroyDisplayTask?.cancel()
        destroyDisplayTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled, let self, self.activeId == nil else { return }
            await self.releaseVirtualDisplay(reason: "tablet disconnected", recoverActiveSession: false)
        }
    }

    /// THE virtual-display teardown path (also the hook for display hot-plug safety): stops every pipeline capturing
    /// the virtual display, removes it (restoring the user's main display after primary mode) and waits until
    /// WindowServer dropped it. A session that was streaming it keeps going as mirror (its extend path is marked
    /// broken for this session, Windows `_extendBroken`) so the tablet never ends up on a dead display.
    func releaseVirtualDisplay(reason: String) async {
        await releaseVirtualDisplay(reason: reason, recoverActiveSession: true)
    }

    private func releaseVirtualDisplay(reason: String, recoverActiveSession: Bool) async {
        destroyDisplayTask?.cancel()
        destroyDisplayTask = nil
        var affected: [SessionContext] = []
        if let vid = virtualDisplays.displayID {
            for ctx in contexts.values where ctx.params?.displayID == vid {
                await stopPipeline(ctx)
                affected.append(ctx)
            }
        }
        if virtualDisplays.display != nil || DisplayArrangement.hasPendingPrimaryRestore {
            await virtualDisplays.destroyAndWait()
        }
        guard recoverActiveSession else { return }
        for ctx in affected where contexts[ctx.id] != nil && !ctx.session.isClosed {
            ctx.failures.extendBroken = true
            lastMessage = "The tablet's virtual display was removed (\(reason)) — mirroring instead."
            await reconfigure(ctx, isUpdate: false, why: "virtual display released")
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
        Task { await self.reconfigure(ctx, isUpdate: false, why: "hello") }
    }

    /// Serialized (re)configuration, Windows `ReconfigureAsync` under `_reconfigLock`: a request that arrives while
    /// one runs is coalesced into one more pass afterwards.
    private func reconfigure(_ ctx: SessionContext, isUpdate: Bool, why: String) async {
        guard contexts[ctx.id] != nil, !ctx.session.isClosed else { return }
        if ctx.isConfiguring {
            ctx.pendingReconfigure = true
            return
        }
        ctx.isConfiguring = true
        var update = isUpdate
        repeat {
            ctx.pendingReconfigure = false
            await configure(ctx, isUpdate: update, why: why)
            update = true
        } while ctx.pendingReconfigure && contexts[ctx.id] != nil && !ctx.session.isClosed
        ctx.isConfiguring = false
    }

    /// Computes stream parameters, (re)creates the display + pipeline, sends CONFIG (after the encoder exists, so
    /// CONFIG carries the real codec / encoder, then codec-config + IDR follow). Size/fps/profile/scale decisions
    /// follow the Windows engine (SessionPolicy, PROTOCOL.md). Only call through `reconfigure`.
    private func configure(_ ctx: SessionContext, isUpdate: Bool, why: String) async {
        guard let hello = ctx.hello, isActive(ctx) else { return }
        if !ctx.isStreaming { updateSummary(ctx.id) { $0.phase = .configuring } }

        let req = SessionPolicy.sanitize(ctx.requested)
        let codec = SessionPolicy.codec(requested: req.codec, tabletCodecs: hello.codecs, forceMjpeg: ctx.failures.forceMjpeg)
        let bitrate = req.bitrateKbps
        let profile = SessionPolicy.h264Profile(for: hello.h264Profiles)
        let virtualAvailable = virtualDisplaySupported && prefs.allowVirtualDisplay

        var mode = SessionPolicy.effectiveMode(requested: req.mode, extendBroken: ctx.failures.extendBroken)
        if mode != "mirror" && !virtualAvailable { mode = "mirror" }
        var width = 0, height = 0
        var fps = min(req.fps, max(15, prefs.maxFps))
        var displayID: CGDirectDisplayID = CGMainDisplayID()
        var appliedScale = 0

        if mode != "mirror" {
            let target = SessionPolicy.streamTarget(hello: hello, resolutionScale: req.resolutionScale,
                                                    fps: fps, portrait: req.isPortrait)
            fps = target.fps
            let resolved = SessionPolicy.targetScalePercent(hello: hello, requested: req.scalePercent, streamSize: target.size)
            let percent = SessionPolicy.hostScalePercent(displayScaleMode: prefs.hiDPI ? prefs.displayScaleMode : "standard",
                                                         requested: req.scalePercent, resolved: resolved)
            let vmode = SessionPolicy.virtualDisplayMode(stream: target.size, scalePercent: percent)
            let tabletLong = Double(max(hello.widthPx ?? 0, hello.heightPx ?? 0, 1))
            let ppi = Double(hello.densityDpi ?? 220) * Double(vmode.backing.longEdge) / tabletLong
            let placement = DisplayPlacement(rawValue: req.position) ?? .right
            let deviceKey = hello.deviceId.flatMap { $0.isEmpty ? nil : $0 } ?? (hello.model ?? "tablet")
            let request = VirtualDisplayRequest(
                name: "PlexiChore – \(hello.deviceName ?? "Tablet")",
                serial: VirtualDisplayRequest.serial(for: deviceKey),
                backingWidth: vmode.backing.width, backingHeight: vmode.backing.height,
                hiDPI: vmode.hiDPI, ppi: max(72, ppi), refreshRate: Double(min(fps, 120)),
                placement: placement, primary: mode == "primary")
            // The capture of a display that is about to be replaced must stop first, or ScreenCaptureKit
            // fails the old stream ("Failed to find any displays"). Its encoder keeps re-sending the last frame
            // meanwhile (keep-alive), so the tablet sees no gap while the display is re-created.
            if !(virtualDisplays.current?.sameDisplay(as: request) ?? false) { await freezePipeline(ctx) }
            // The tablet may have gone (or been replaced) while the old capture stopped: never create a display then.
            guard isActive(ctx) else { return }
            do {
                destroyDisplayTask?.cancel()
                destroyDisplayTask = nil
                displayID = try await virtualDisplays.ensureDisplay(request)
                // Gone while the display came up: its teardown (scheduled by sessionClosed) was cancelled above.
                guard isActive(ctx) else { bailOut(); return }
                width = vmode.stream.width
                height = vmode.stream.height
                if mode == "primary" && !virtualDisplays.isPrimary {
                    lastMessage = "Could not make the tablet the main display — extending instead."
                    mode = "extend"
                }
                appliedScale = SessionPolicy.configScalePercent(mode: mode, applied: vmode,
                                                                actualHiDPI: virtualDisplays.actualHiDPI)
            } catch {
                lastMessage = "Extended display unavailable (\(error.localizedDescription)) — mirroring instead."
                mode = "mirror"
            }
        }

        if mode == "mirror" {
            if virtualDisplays.display != nil && activeId == ctx.id {
                await releaseVirtualDisplay(reason: "mirror mode", recoverActiveSession: false)
            }
            guard isActive(ctx) else { bailOut(); return }
            let displays = DisplayCatalog.activeDisplays()
            let target = displays.first(where: { $0.index == req.monitorIndex }) ?? displays.first
            guard let target else {
                ctx.session.close(reason: "configuration failed: no display to mirror")
                return
            }
            displayID = target.id
            // Windows: FitSize(desktop, ClampToDecoder(TabletBox(resolutionScale))) — the Mac desktop is landscape.
            let box = SessionPolicy.streamTarget(hello: hello, resolutionScale: req.resolutionScale, fps: fps, portrait: false)
            let size = SessionPolicy.fitSize(src: SessionPolicy.Size(target.pixelWidth, target.pixelHeight), box: box.size)
            (width, height, fps) = (size.width, size.height, box.fps)
        }

        // Session might have gone away while we awaited the display.
        guard isActive(ctx) else { bailOut(); return }

        let newParams = StreamParameters(codec: codec, width: width, height: height, fps: fps,
                                         bitrateKbps: bitrate, quality: req.quality, mode: mode,
                                         displayID: displayID, periodicKeyframes: prefs.periodicKeyframes,
                                         profile: profile, preferHardware: prefs.preferHardwareEncoder,
                                         allowHardware: !ctx.failures.disallowHardware)
        let link = await awaitLink(ctx)
        guard isActive(ctx) else { bailOut(); return }
        let base = ConfigMessage(codec: codec, width: width, height: height, fps: fps, bitrateKbps: bitrate,
                                 mode: mode, hostName: hostName, hostOs: "macos",
                                 monitors: DisplayCatalog.monitorInfos(),
                                 virtualDisplayAvailable: virtualAvailable,
                                 encoder: nil, scalePercent: mode != "mirror" ? appliedScale : 0,
                                 link: link?.rawValue)
        let makeConfig: @Sendable (PipelineInfo) -> ConfigMessage = { info in
            var c = base
            c.codec = info.codec
            c.width = info.width
            c.height = info.height
            c.fps = info.fps
            c.encoder = info.encoderName
            return c
        }
        let touchMode = req.touchMode
        let frameSize = CGSize(width: width, height: height)

        // Same display: live change (bitrate/fps keep the stream; anything else = seamless encoder swap).
        if isUpdate, let pipeline = ctx.pipeline, let old = ctx.params, old.displayID == displayID, !pipeline.isFrozen {
            if old == newParams {
                // Nothing the stream depends on changed (e.g. orientation in mirror, touchMode): resend CONFIG.
                if let cfg = ctx.config {
                    var c = cfg
                    c.link = base.link; c.scalePercent = base.scalePercent; c.monitors = base.monitors
                    ctx.config = c
                    ctx.session.sendJSON(.config, c)
                }
                ctx.setInputTarget(displayID: displayID, touchMode: touchMode, frameSize: frameSize)
                finishConfigure(ctx, config: ctx.config ?? base)
                return
            }
            if let info = await pipeline.reconfigure(to: newParams, makeConfig: makeConfig) {
                guard isActive(ctx) else { bailOut(); return }
                ctx.params = newParams
                ctx.config = makeConfig(info)
                ctx.setInputTarget(displayID: displayID, touchMode: touchMode, frameSize: frameSize)
                finishConfigure(ctx, config: makeConfig(info))
                return
            }
        }

        // Full (re)start. The old pipeline (capture stopped) bridges the gap with keep-alive frames of its last
        // picture until the new one is about to send its CONFIG.
        let bridge = await detachPipelineAsBridge(ctx)
        guard isActive(ctx) else { await bridge?.stop(); bailOut(); return }

        let pipeline = StreamPipeline(session: ctx.session, params: newParams)
        ctx.pipelineGeneration += 1
        let gen = ctx.pipelineGeneration
        let ctxId = ctx.id
        pipeline.onStats = { [weak self] stats in
            Task { @MainActor in self?.updateSummary(ctxId) { $0.stats = stats } }
        }
        pipeline.onEnded = { [weak self, weak ctx] reason in
            Task { @MainActor in
                guard let self, let ctx else { return }
                await self.pipelineEnded(ctx, generation: gen, reason: reason)
            }
        }
        ctx.pipeline = pipeline
        let info: PipelineInfo
        do {
            info = try await pipeline.start()
            await bridge?.stop()
        } catch {
            await bridge?.stop()
            if ctx.pipeline === pipeline { ctx.pipeline = nil }
            pipeline.onEnded = nil
            await pipeline.stop()
            guard isActive(ctx) else { bailOut(); return }
            lastMessage = error.localizedDescription
            if case CaptureError.permissionDenied = error {
                updateSummary(ctx.id) { $0.phase = .error }
                ctx.session.close(reason: "Mac could not start streaming: \(error.localizedDescription)")
                return
            }
            // Windows: extend/primary failed → retry as mirror; > 6 failures → disconnect; else retry in 1 s.
            switch SessionPolicy.onStreamStartFailed(mode: mode, state: &ctx.failures) {
            case .disconnect:
                updateSummary(ctx.id) { $0.phase = .error }
                ctx.session.close(reason: "cannot start capture: \(error.localizedDescription)")
            case .restart(let after):
                scheduleRestart(ctx, after: after, why: "retry")
            }
            return
        }
        guard isActive(ctx), ctx.pipeline === pipeline else {
            pipeline.onEnded = nil
            await pipeline.stop()
            bailOut()
            return
        }
        let config = makeConfig(info)
        ctx.params = newParams
        ctx.config = config
        pipeline.activate(config: config)     // CONFIG, then codec-config + IDR
        ctx.setInputTarget(displayID: displayID, touchMode: touchMode, frameSize: frameSize)
        ctx.isStreaming = true
        finishConfigure(ctx, config: config)
        // Windows-like forgiveness: a pipeline that streamed 30 s resets this session's failure counters.
        Task { @MainActor [weak self, weak ctx] in
            try? await Task.sleep(nanoseconds: UInt64(SessionPolicy.healthyStreamReset * 1_000_000_000))
            guard let self, let ctx, self.contexts[ctx.id] != nil, ctx.pipelineGeneration == gen, ctx.isStreaming else { return }
            SessionPolicy.streamedHealthily(state: &ctx.failures)
        }
    }

    /// The session still exists, is open and is the one streaming (one tablet at a time).
    private func isActive(_ ctx: SessionContext) -> Bool {
        contexts[ctx.id] != nil && !ctx.session.isClosed && activeId == ctx.id
    }

    /// A configure pass gave up after an await: if no tablet is active any more, make sure the virtual display
    /// (possibly just created, its teardown cancelled) still goes away.
    private func bailOut() {
        if activeId == nil { scheduleVirtualDisplayTeardown() }
    }

    /// Windows `Session.OnPipelineEnded`: escalate the encoder (hardware → software → MJPEG), retry, or give up.
    private func pipelineEnded(_ ctx: SessionContext, generation: Int, reason: String) async {
        guard contexts[ctx.id] != nil, !ctx.session.isClosed, generation == ctx.pipelineGeneration else { return }
        switch SessionPolicy.onPipelineEnded(reason: reason, state: &ctx.failures) {
        case .disconnect:
            let message = reason.hasPrefix("stopped:") ? String(reason.dropFirst("stopped:".count))
                                                       : "streaming failed: \(reason)"
            lastMessage = message
            ctx.session.close(reason: message)
        case .restart(let after):
            await stopPipeline(ctx)
            scheduleRestart(ctx, after: after, why: reason)
        }
    }

    private func scheduleRestart(_ ctx: SessionContext, after: TimeInterval, why: String) {
        Task { @MainActor [weak self, weak ctx] in
            try? await Task.sleep(nanoseconds: UInt64(after * 1_000_000_000))
            guard let self, let ctx, self.contexts[ctx.id] != nil, !ctx.session.isClosed else { return }
            await self.reconfigure(ctx, isUpdate: false, why: why)
        }
    }

    /// Stops the capture of the session's pipeline but keeps it sending keep-alive frames (see
    /// `StreamPipeline.freezeCapture`). It stays `ctx.pipeline`, so every stop path still ends it.
    private func freezePipeline(_ ctx: SessionContext) async {
        guard let p = ctx.pipeline else { return }
        ctx.pipelineGeneration += 1   // whatever it reports from now on is stale
        p.onEnded = nil
        await p.freezeCapture()
    }

    /// Takes the pipeline off the session with its capture stopped; the caller stops it once the replacement is
    /// ready (before the replacement's CONFIG goes out).
    private func detachPipelineAsBridge(_ ctx: SessionContext) async -> StreamPipeline? {
        ctx.isStreaming = false
        ctx.pipelineGeneration += 1
        guard let old = ctx.pipeline else { return nil }
        ctx.pipeline = nil
        old.onEnded = nil
        await old.freezeCapture()
        return old
    }

    private func stopPipeline(_ ctx: SessionContext) async {
        ctx.isStreaming = false
        ctx.pipelineGeneration += 1
        guard let old = ctx.pipeline else { return }
        ctx.pipeline = nil
        old.onEnded = nil
        await old.stop()
    }

    /// Windows `LinkAsync`: wait at most 0.4 s for the link query started at HELLO; nil = omit `link`.
    private func awaitLink(_ ctx: SessionContext) async -> SessionPolicy.Link? {
        var waited: TimeInterval = 0
        while !ctx.linkResolved && waited < SessionPolicy.linkQueryWait {
            try? await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        return ctx.link
    }

    private func finishConfigure(_ ctx: SessionContext, config: ConfigMessage) {
        let scaleAuto = ctx.scaleAuto
        updateSummary(ctx.id) {
            $0.phase = .streaming
            $0.mode = config.mode
            $0.width = config.width
            $0.height = config.height
            $0.fps = config.fps
            $0.codec = config.codec
            $0.bitrateKbps = config.bitrateKbps
            $0.encoder = config.encoder ?? ""
            $0.scalePercent = config.scalePercent ?? 0
            $0.scaleAuto = scaleAuto
            $0.transportLink = config.link ?? $0.transportLink
        }
    }

    /// CONFIG `link`: adb reverse transport for loopback sessions, else the local interface type.
    private func classifyLink(_ ctx: SessionContext) async -> SessionPolicy.Link? {
        let remote = ctx.session.remoteHost
        let local = ctx.session.localPathInfo
        if SessionPolicy.isLoopback(remote) {
            // adb reverse: which transport (cable / wireless debugging) serves tcp:47800 — nil = omit `link`.
            return await adb.resolveLoopbackLink(helloModel: ctx.hello?.model)
        }
        return SessionPolicy.classifyLink(remoteAddress: remote, localAddress: local.address,
                                          interfaceName: local.interface, interfaceDisplayName: nil,
                                          reverseListOutputs: [])
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
