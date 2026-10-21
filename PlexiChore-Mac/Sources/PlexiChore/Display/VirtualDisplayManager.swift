import AppKit
import CoreGraphics
import CVirtualDisplay
import os

enum DisplayPlacement: String {
    case right, left, top, bottom
}

enum VirtualDisplayError: LocalizedError {
    case unsupported
    case creationFailed
    case didNotAppear
    /// The safety net released the display recently (emergency hotkey, sleep, watchdog…): mirror until it expires.
    case safetyHold(DisplaySafetyReason, TimeInterval)
    /// Too many create cycles in a short time (e.g. a flapping USB-C hub).
    case rateLimited(TimeInterval)
    /// Physical displays are still being added/removed.
    case displaysUnstable

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This macOS version does not provide CGVirtualDisplay."
        case .creationFailed: return "macOS refused to create the virtual display."
        case .didNotAppear: return "The virtual display did not come online."
        case .safetyHold(let r, let s):
            return r == .emergency
                ? "the virtual display was released with \(EmergencyHotKey.displayString); retry in \(Int(s.rounded(.up))) s"
                : "the virtual display is paused for safety (\(r.rawValue)); retry in \(Int(s.rounded(.up))) s"
        case .rateLimited(let s): return "displays changed too often; retry in \(Int(s.rounded(.up))) s"
        case .displaysUnstable: return "the Mac's displays are still being connected/disconnected"
        }
    }
}

/// What the caller wants the virtual display to look like.
struct VirtualDisplayRequest: Equatable {
    var name: String
    /// Stable per tablet so WindowServer remembers one arrangement per tablet instead of
    /// collecting a new "monitor" every session.
    var serial: UInt32
    var backingWidth: Int
    var backingHeight: Int
    var hiDPI: Bool
    var ppi: Double
    var refreshRate: Double
    var placement: DisplayPlacement
    var primary: Bool

    /// Fields that need a new CGVirtualDisplay when they change (placement/primary don't).
    func sameDisplay(as o: VirtualDisplayRequest) -> Bool {
        serial == o.serial && backingWidth == o.backingWidth && backingHeight == o.backingHeight
            && hiDPI == o.hiDPI && refreshRate == o.refreshRate
    }

    /// Non-zero serial derived from a tablet id (FNV-1a).
    static func serial(for deviceId: String) -> UInt32 {
        var h: UInt32 = 2_166_136_261
        for b in deviceId.utf8 { h = (h ^ UInt32(b)) &* 16_777_619 }
        return h == 0 ? 1 : h
    }
}

/// Owns the (at most one) PlexiChore virtual display used for "extend" / "primary" mode, plus the safety net that
/// keeps it from ever leaving the Mac with a black / unusable screen (see DisplaySafety.swift). The safety net
/// installs itself; the host only wires `hasActiveClient`, `onSafetyRelease` (and optionally `onShouldRecreate`).
@MainActor
final class VirtualDisplayManager {
    nonisolated static var isSupported: Bool { PXVirtualDisplay.isSupported() }

    private(set) var display: PXVirtualDisplay?
    private(set) var current: VirtualDisplayRequest?
    /// True when the display really came up 2x (macOS silently drops HiDPI for some sizes).
    private(set) var actualHiDPI = false
    private(set) var isPrimary = false

    /// Called when WindowServer removes the display on its own. Also used to ask for recreation after wake when
    /// `onShouldRecreate` is not set.
    var onTerminated: (() -> Void)?

    // MARK: Safety hooks (set by the host)

    /// "Is a tablet currently streaming / connected?" nil = unknown: the client-gone backstop is then disabled and
    /// a watching client is assumed (the virtual-only grace still applies).
    var hasActiveClient: (() -> Bool)?
    /// The user allows the tablet to stay the only display (lid closed); checked together with AC power.
    var allowVirtualOnly: (() -> Bool)?
    /// The safety net released (destroyed = true) or demoted (primary → extend, destroyed = false) the display.
    /// The host should reconfigure the active session (ensureDisplay then fails with `.safetyHold` → mirror).
    var onSafetyRelease: ((DisplaySafetyEvent) -> Void)?
    /// After wake: the display was removed for sleep and a client is still active — reconfigure it.
    var onShouldRecreate: (() -> Void)?
    /// Main thread: the display was created / destroyed, or a safety hold was set / expired (refresh UI).
    var onStateChange: (() -> Void)?

    // MARK: Safety tuning
    /// Quiet time after the last physical display change before anything is created / evaluated.
    var stormQuiet: TimeInterval = 1.5
    /// Longest ensureDisplay waits for displays to settle.
    var stormMaxWait: TimeInterval = 6
    /// Backstop when the host's own teardown did not run (only with `hasActiveClient`).
    var clientGoneGrace: TimeInterval = 30
    var emergencyHold: TimeInterval = 120
    var watchdogHold: TimeInterval = 60
    /// No primary mode for this long after a physical display vanished while the tablet was main.
    var primaryHoldAfterLoss: TimeInterval = 60

    // MARK: Safety state
    private var limiter = CreationRateLimiter()
    private var hold: (until: Date, reason: DisplaySafetyReason)?
    private var primaryHoldUntil: Date?
    private var lastPhysicalChange: Date?
    private var physicalLostWhilePrimary = false
    private var noPhysicalSince: Date?
    private var clientGoneSince: Date?
    private var ownIDs: Set<CGDirectDisplayID> = []
    private var operationDepth = 0
    private var evaluation: DispatchWorkItem?
    private var evaluationFirstRequest: Date?
    private var periodic: Timer?
    private var resumeAfterWake = false
    private var holdBeforeSleep: (until: Date, reason: DisplaySafetyReason)?
    private var holdExpiry: Timer?
    /// After WindowServer killed the display: no recreation for this long (the incident's 78 → 81 recreate
    /// happened in the middle of a hub flap).
    var terminationHold: TimeInterval = 8
    /// Keeps App Nap from throttling the watchdog heartbeat (and the stream) while the display exists.
    private var activity: NSObjectProtocol?
    private var monitor: DisplayReconfigurationMonitor?
    private var hotKey: EmergencyHotKey?
    private let signals = SafetySignalHandler()
    private var observers: [NSObjectProtocol] = []
    private let log = Logger(subsystem: "com.pntapps.plexichore", category: "DisplaySafety")

    init() {
        // Next run-loop turn: NSApp exists, the Carbon event target is ready.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.installSafetyNet() }
        }
    }

    var displayID: CGDirectDisplayID? {
        guard let d = display, d.displayID != 0 else { return nil }
        return d.displayID
    }

    /// Seconds until a safety hold (emergency / sleep / watchdog) expires; nil when creation is allowed.
    var safetyHoldRemaining: TimeInterval? {
        guard let h = hold else { return nil }
        let r = h.until.timeIntervalSinceNow
        return r > 0 ? r : nil
    }

    /// Lifts an emergency/watchdog hold (e.g. a "Re-enable extended display" menu item).
    func clearSafetyHold() { setHold(nil); primaryHoldUntil = nil }

    /// Sets (keeping a longer existing one) or clears the creation hold; a one-shot timer reports its expiry.
    private func setHold(_ reason: DisplaySafetyReason?, for seconds: TimeInterval = 0) {
        holdExpiry?.invalidate()
        holdExpiry = nil
        if let reason {
            let until = seconds.isFinite ? Date().addingTimeInterval(seconds) : Date.distantFuture
            if let h = hold, h.until > until {} else { hold = (until, reason) }
        } else {
            hold = nil
        }
        if let h = hold, h.until != .distantFuture {
            let t = Timer(fire: h.until.addingTimeInterval(0.05), interval: 0, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let h = self.hold, h.until <= Date() else { return }
                    self.hold = nil
                    self.holdExpiry = nil
                    self.onStateChange?()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            holdExpiry = t
        }
        onStateChange?()
    }

    /// The watchdog (or the signal fallback) invalidated the display from another thread: hold creation, so a
    /// pipeline restart cannot recreate the display straight into the stall.
    private func absorbExternalInvalidation() {
        guard let d = display, d.isInvalidated else { return }
        _ = DisplayWatchdog.shared.consumeFired()
        if safetyHoldRemaining == nil { setHold(.watchdog, for: watchdogHold) }
    }

    /// Creates (or reuses) the virtual display, places it beside the main display or makes it
    /// the main display. Returns its display id once it is online and has a usable mode.
    func ensureDisplay(_ req: VirtualDisplayRequest) async throws -> CGDirectDisplayID {
        guard Self.isSupported else { throw VirtualDisplayError.unsupported }
        if display?.isInvalidated == true { release(.watchdog, holdFor: watchdogHold) }
        try checkHold()

        operationDepth += 1
        defer { operationDepth -= 1; scheduleEvaluation(after: 0.5) }

        if let existing = display, existing.displayID != 0, let cur = current, cur.sameDisplay(as: req) {
            current = req
            arrange(existing.displayID, req)
            return existing.displayID
        }

        await destroyAndWait()
        try await waitForStableDisplays()
        if let wait = limiter.delayBeforeCreate() {
            guard wait <= 5 else {
                log.error("virtual display creation rate limited (\(wait, privacy: .public) s)")
                throw VirtualDisplayError.rateLimited(wait)
            }
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
        }
        try checkHold()   // the hotkey / sleep may have fired while we waited
        guard display == nil else { throw VirtualDisplayError.displaysUnstable }   // a concurrent call won

        DisplayWatchdog.shared.markSensitive()
        limiter.recordCreate()
        guard let vd = PXVirtualDisplay(name: req.name,
                                        pixelWidth: req.backingWidth,
                                        pixelHeight: req.backingHeight,
                                        ppi: req.ppi,
                                        hiDPI: req.hiDPI,
                                        refreshRate: req.refreshRate,
                                        serialNumber: req.serial) else {
            throw VirtualDisplayError.creationFailed
        }
        vd.terminationHandler = { [weak self, weak vd] in
            guard let self, let vd, self.display === vd else { return }
            self.log.error("WindowServer terminated the virtual display")
            self.limiter.recordDestroy()
            self.lastPhysicalChange = Date()   // treat as a display storm: creation waits for quiet
            self.clearDisplayState()
            if DisplayArrangement.hasPendingPrimaryRestore { _ = try? DisplayArrangement.restorePrimary() }
            self.setHold(.terminatedBySystem, for: self.terminationHold)
            // Ask for recreation only once the hold has passed (ensureDisplay would just throw before that).
            DispatchQueue.main.asyncAfter(deadline: .now() + self.terminationHold + 0.1) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.display == nil, self.safetyHoldRemaining == nil else { return }
                    self.onTerminated?()
                }
            }
        }
        display = vd
        current = req
        ownIDs.insert(vd.displayID)
        DisplayCatalog.setExcluded([vd.displayID])
        DisplayWatchdog.shared.arm(vd)
        startPeriodic()
        onStateChange?()
        if activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "PlexiChore virtual display")
        }

        let id = vd.displayID
        var online = false
        for _ in 0..<50 {   // up to ~5 s
            guard display === vd else { throw VirtualDisplayError.didNotAppear }   // released meanwhile
            // Bounds appear ~0.5 s before the display modes do; capture needs the modes.
            if Self.isOnline(id), CGDisplayBounds(id).width > 0,
               let m = CGDisplayCopyDisplayMode(id), m.pixelWidth > 0 {
                online = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard online, display === vd else {
            await destroyAndWait()
            throw VirtualDisplayError.didNotAppear
        }
        selectMode(id, req)
        if DisplayProbe.isInMirrorSet(id) { DisplayProbe.unmirror(id) }   // remembered display set
        arrange(id, req)
        return id
    }

    /// Restores the user's original main display (primary mode) and removes the virtual display.
    func destroy() {
        DisplayWatchdog.shared.markSensitive()
        absorbExternalInvalidation()
        if DisplayArrangement.hasPendingPrimaryRestore {
            _ = try? DisplayArrangement.restorePrimary()
        }
        // Never let macOS pick a new main itself while the tablet still holds the menu bar.
        if let vid = displayID, CGMainDisplayID() == vid {
            _ = try? DisplayArrangement.demoteIfMain(virtualID: vid)
        }
        let had = display != nil
        if had { limiter.recordDestroy() }
        display?.invalidate()
        clearDisplayState()
        if had { onStateChange?() }
    }

    /// `destroy()` and wait (≤ 3 s) until WindowServer really removed the display.
    func destroyAndWait() async {
        let oldID = display?.displayID ?? 0
        destroy()
        guard oldID != 0 else { return }
        for _ in 0..<30 where Self.isOnline(oldID) {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    /// Instantly removes the virtual display and gives the Mac its arrangement back; blocks re-creation for
    /// `emergencyHold` seconds (sessions fall back to mirror). Bound to ⌃⌥⌘D and SIGUSR1; call it from the menu bar.
    func emergencyRelease() {
        log.error("emergency release")
        NSSound.beep()
        release(.emergency, holdFor: emergencyHold)
        if DisplayArrangement.hasPendingPrimaryRestore { _ = try? DisplayArrangement.restorePrimary() }
    }

    private func clearDisplayState() {
        DisplayWatchdog.shared.arm(nil)
        isPrimary = false
        display = nil
        current = nil
        actualHiDPI = false
        noPhysicalSince = nil
        clientGoneSince = nil
        physicalLostWhilePrimary = false
        DisplayCatalog.setExcluded([])
        periodic?.invalidate()
        periodic = nil
        if let a = activity { ProcessInfo.processInfo.endActivity(a); activity = nil }
    }

    // MARK: Arrangement

    /// Primary mode only when a physical display exists to fall back to and no recent loss put it on hold.
    private var primaryAllowed: Bool {
        if let u = primaryHoldUntil, u > Date() { return false }
        return !DisplayProbe.usablePhysicalDisplays(excluding: displayID).isEmpty
    }

    private func arrange(_ id: CGDirectDisplayID, _ req: VirtualDisplayRequest) {
        DisplayWatchdog.shared.markSensitive()
        if req.primary && primaryAllowed {
            if isPrimary && CGMainDisplayID() == id { return }
            do {
                try DisplayArrangement.makePrimary(virtualID: id)
                isPrimary = true
                physicalLostWhilePrimary = false
                return
            } catch {
                isPrimary = false   // fall through: extend beside the main display
            }
        } else if isPrimary || DisplayArrangement.hasPendingPrimaryRestore {
            _ = try? DisplayArrangement.restorePrimary()
            isPrimary = false
        }
        // placeBeside demotes the virtual display first if macOS made it main on its own.
        _ = try? DisplayArrangement.placeBeside(virtualID: id, of: CGMainDisplayID(), position: req.placement)
    }

    /// WindowServer may restore a remembered mode for a known serial: force the one we built.
    private func selectMode(_ id: CGDirectDisplayID, _ req: VirtualDisplayRequest) {
        let wantPoints = req.hiDPI ? req.backingWidth / 2 : req.backingWidth
        defer {
            if let m = CGDisplayCopyDisplayMode(id) { actualHiDPI = m.pixelWidth >= m.width * 2 }
        }
        guard let cur = CGDisplayCopyDisplayMode(id) else { return }
        if cur.pixelWidth == req.backingWidth && cur.width == wantPoints { return }
        let opts = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode],
              let m = modes.first(where: { $0.pixelWidth == req.backingWidth && $0.pixelHeight == req.backingHeight
                                           && $0.width == wantPoints && $0.isUsableForDesktopGUI() }) else { return }
        DisplayWatchdog.shared.markSensitive()
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return }
        if CGConfigureDisplayWithDisplayMode(cfg, id, m, nil) == .success {
            CGCompleteDisplayConfiguration(cfg, .forSession)
        } else {
            CGCancelDisplayConfiguration(cfg)
        }
    }

    nonisolated static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        DisplayProbe.onlineDisplays().contains(id)
    }

    // MARK: - Safety net

    private func installSafetyNet() {
        guard monitor == nil else { return }
        DisplayWatchdog.shared.start()

        let m = DisplayReconfigurationMonitor { [weak self] e in
            MainActor.assumeIsolated { self?.handleReconfiguration(e) }
        }
        m.start()
        monitor = m

        let hk = EmergencyHotKey { [weak self] in
            MainActor.assumeIsolated { self?.emergencyRelease() }
        }
        if !hk.register() { log.error("emergency hotkey unavailable; use the menu or `killall -USR1 PlexiChore`") }
        hotKey = hk

        signals.install(release: { [weak self] reason in
            guard let self else { return }
            if reason == .emergency { self.emergencyRelease() } else { self.release(.terminating, holdFor: .infinity) }
        }, fallbackInvalidate: {
            DisplayWatchdog.shared.invalidateArmedNow()
        })

        let ws = NSWorkspace.shared.notificationCenter
        observers.append(ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.willSleep() }
        })
        observers.append(ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.didWake() }
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                                object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.release(.terminating, holdFor: .infinity) }
        })
    }

    /// Destroys the display (restoring the arrangement first), optionally blocks re-creation, tells the host.
    private func release(_ reason: DisplaySafetyReason, holdFor: TimeInterval?) {
        let had = display != nil
        destroy()
        if let holdFor { setHold(reason, for: holdFor) }
        if had {
            log.error("virtual display released: \(reason.rawValue, privacy: .public)")
            // Quitting: no host reaction wanted (it would only start reconfiguring sessions mid-shutdown).
            if reason != .terminating { onSafetyRelease?(DisplaySafetyEvent(reason: reason, destroyed: true)) }
        }
    }

    private func checkHold() throws {
        guard let h = hold else { return }
        let r = h.until.timeIntervalSinceNow
        if r > 0 { throw VirtualDisplayError.safetyHold(h.reason, r) }
        hold = nil
    }

    private func willSleep() {
        resumeAfterWake = display != nil && (hasActiveClient?() ?? true)
        holdBeforeSleep = safetyHoldRemaining != nil ? hold : nil   // keep an emergency hold across sleep
        hold = nil
        release(.sleep, holdFor: .infinity)
    }

    private func didWake() {
        guard hold?.reason == .sleep else { return }
        // Displays come back in a burst after wake: lift the hold, then let ensureDisplay's storm wait settle it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hold?.reason == .sleep else { return }
                let prior = self.holdBeforeSleep.flatMap { $0.until > Date() ? $0 : nil }
                self.holdBeforeSleep = nil
                self.setHold(nil)
                if let prior { self.setHold(prior.reason, for: prior.until.timeIntervalSinceNow) }
                if self.hold == nil, self.resumeAfterWake, self.hasActiveClient?() ?? true {
                    self.resumeAfterWake = false
                    (self.onShouldRecreate ?? self.onTerminated)?()
                }
                self.resumeAfterWake = false
            }
        }
    }

    private func isOwn(_ id: CGDirectDisplayID) -> Bool {
        ownIDs.contains(id) || CGDisplayVendorNumber(id) == DisplayProbe.plexiVendor
    }

    private func handleReconfiguration(_ e: DisplayReconfigurationMonitor.Event) {
        if e.flags.contains(.beginConfigurationFlag) { return }
        if isOwn(e.display) {
            scheduleEvaluation(after: 0.5)
            return
        }
        let lost = e.flags.contains(.removeFlag) || e.flags.contains(.disabledFlag)
            || e.flags.contains(.mirrorFlag) || e.flags.contains(.unMirrorFlag)
        // A physical display that only moved / changed desktop shape was shifted by our own display appearing or
        // leaving; that is not hub flapping, so it must not delay the next creation.
        let topology: CGDisplayChangeSummaryFlags = [.addFlag, .removeFlag, .enabledFlag, .disabledFlag,
                                                     .mirrorFlag, .unMirrorFlag, .setModeFlag, .setMainFlag]
        if !e.flags.isDisjoint(with: topology) { lastPhysicalChange = Date() }
        if lost && isPrimary {
            // Never wait out the storm while the tablet holds the menu bar and a real display just vanished.
            physicalLostWhilePrimary = true
            scheduleEvaluation(after: 0.25, force: true)
        } else {
            scheduleEvaluation(after: stormQuiet)
        }
    }

    /// Debounced: each new event pushes the evaluation out again, but never past 4 s after the first pending
    /// request (a hub that never stops flapping still gets evaluated). `force` runs it after `delay` regardless.
    private func scheduleEvaluation(after delay: TimeInterval, force: Bool = false) {
        let now = Date()
        let first = evaluationFirstRequest ?? now
        evaluationFirstRequest = first
        var at = now.addingTimeInterval(delay)
        if !force { at = min(at, max(now, first.addingTimeInterval(4))) }
        evaluation?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.evaluationFirstRequest = nil
                self?.evaluate()
            }
        }
        evaluation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + at.timeIntervalSince(now), execute: work)
    }

    private func startPeriodic() {
        guard periodic == nil else { return }
        let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        RunLoop.main.add(t, forMode: .common)
        periodic = t
    }

    private func evaluate() {
        // The watchdog killed the display while the main thread was stuck: clean up, restore, hold.
        if let d = display, d.isInvalidated {
            release(.watchdog, holdFor: watchdogHold)
            return
        }
        guard let vid = displayID else {
            // Nothing of ours is alive, but a restore record says main was moved: put it back.
            if DisplayArrangement.hasPendingPrimaryRestore { DisplayArrangement.restoreIfCrashed() }
            return
        }
        if operationDepth > 0 { return }   // ensureDisplay re-schedules when it finishes

        let now = Date()
        let usable = DisplayProbe.usablePhysicalDisplays(excluding: vid)
        let client = hasActiveClient?() ?? true
        if usable.isEmpty { noPhysicalSince = noPhysicalSince ?? now } else { noPhysicalSince = nil }

        let snapshot = DisplaySafetySnapshot(
            virtualOnline: Self.isOnline(vid),
            virtualIsMain: CGMainDisplayID() == vid,
            usablePhysicalCount: usable.count,
            primaryWanted: isPrimary && current?.primary == true,
            physicalLostWhilePrimary: physicalLostWhilePrimary,
            clientActive: client,
            noPhysicalFor: noPhysicalSince.map { now.timeIntervalSince($0) } ?? 0,
            virtualInMirrorSet: DisplayProbe.isInMirrorSet(vid),
            virtualOnlyAllowed: usable.isEmpty && (allowVirtualOnly?() ?? false) && DisplayProbe.onACPower())

        for action in DisplaySafetyPolicy.decide(snapshot) {
            guard displayID == vid else { return }
            switch action {
            case .none: break
            case .destroy(let r):
                release(r, holdFor: 30)
                return
            case .unmirror:
                DisplayProbe.unmirror(vid)
                if DisplayProbe.isInMirrorSet(vid) { release(.mirrorSet, holdFor: 60); return }
            case .restorePhysicalMain(let r):
                if !restorePhysicalMain(vid, reason: r) { return }
            }
        }

        // Backstop for a client that is gone but whose teardown never ran.
        if let has = hasActiveClient, displayID == vid {
            if has() {
                clientGoneSince = nil
            } else {
                clientGoneSince = clientGoneSince ?? now
                if now.timeIntervalSince(clientGoneSince!) >= clientGoneGrace { release(.clientGone, holdFor: nil) }
            }
        }
    }

    /// Gives main back to a physical display. Returns false when it had to destroy the virtual display instead.
    private func restorePhysicalMain(_ vid: CGDirectDisplayID, reason: DisplaySafetyReason) -> Bool {
        DisplayWatchdog.shared.markSensitive()
        let wasPrimary = isPrimary
        if DisplayArrangement.hasPendingPrimaryRestore { _ = try? DisplayArrangement.restorePrimary(attempts: 1) }
        if CGMainDisplayID() == vid { _ = try? DisplayArrangement.demoteIfMain(virtualID: vid) }
        if CGMainDisplayID() == vid {
            release(reason == .physicalDisplayLost ? reason : .virtualBecameMain, holdFor: 60)
            return false
        }
        isPrimary = false
        physicalLostWhilePrimary = false
        if reason == .physicalDisplayLost { primaryHoldUntil = Date().addingTimeInterval(primaryHoldAfterLoss) }
        _ = try? DisplayArrangement.placeBeside(virtualID: vid, of: CGMainDisplayID(),
                                                position: current?.placement ?? .right, settle: false)
        if wasPrimary {
            log.error("primary demoted: \(reason.rawValue, privacy: .public)")
            onSafetyRelease?(DisplaySafetyEvent(reason: reason, destroyed: false))
        }
        return true
    }

    /// Waits until no physical display changed for `stormQuiet` seconds (≤ `stormMaxWait`).
    private func waitForStableDisplays() async throws {
        let start = Date()
        while let last = lastPhysicalChange, Date().timeIntervalSince(last) < stormQuiet {
            if Date().timeIntervalSince(start) > stormMaxWait { throw VirtualDisplayError.displaysUnstable }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
    }
}
