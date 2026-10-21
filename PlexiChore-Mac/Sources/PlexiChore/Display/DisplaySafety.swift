import AppKit
import Carbon.HIToolbox
import CoreGraphics
@preconcurrency import CVirtualDisplay
import Foundation
import IOKit.ps
import os

// Safety net around the PlexiChore virtual display (see VirtualDisplayManager+Safety).
//
// Incident this exists for (macOS 27, MacBook Air): a USB-C hub carrying charger + external monitor + tablet flapped;
// the external monitor (which the built-in was mirroring) vanished, the virtual display was recreated (id 78 → 81),
// and a minute later the Mac's screen was black and needed a forced reset. The rules enforced here:
//   * a physical display add/remove storm is debounced; nothing is created while displays are unstable;
//   * the virtual display is never left as the main / only usable display without a watching client;
//   * the virtual display is never part of a mirror set;
//   * creation is rate limited (no create/destroy thrash while a hub flaps);
//   * it is torn down on sleep, quit, SIGTERM/SIGINT/SIGHUP, a global hotkey (⌃⌥⌘D), SIGUSR1, and by a watchdog when
//     the main thread stalls during a display reconfiguration.

/// Why the safety net released (or demoted) the virtual display.
enum DisplaySafetyReason: String, Sendable {
    case emergency            // hotkey / menu "Release display" / SIGUSR1
    case sleep                // NSWorkspace.willSleep
    case terminating          // app quit / SIGTERM / SIGINT / SIGHUP
    case noPhysicalDisplay    // only the virtual display was left usable
    case physicalDisplayLost  // a physical display vanished while the tablet was main (primary → extend)
    case virtualBecameMain    // macOS made the virtual display main on its own and it could not be demoted
    case watchdog             // main thread stalled during a display reconfiguration
    case clientGone           // no client for longer than the backstop grace
    case mirrorSet            // the virtual display ended up in a mirror set and could not be taken out
    case terminatedBySystem   // WindowServer removed the display on its own (short hold before recreating)

    var message: String {
        switch self {
        case .emergency: return "Virtual display released (⌃⌥⌘D). Mirroring only for a while."
        case .sleep: return "Virtual display removed for sleep."
        case .terminating: return "Virtual display removed (PlexiChore is quitting)."
        case .noPhysicalDisplay: return "No Mac display was usable — removed the virtual display so the Mac screen comes back."
        case .physicalDisplayLost: return "A Mac display disconnected — gave the main display back to the Mac."
        case .virtualBecameMain: return "macOS made the tablet the main display — removed the virtual display for safety."
        case .watchdog: return "The Mac stopped responding during a display change — removed the virtual display."
        case .clientGone: return "No tablet is connected — removed the virtual display."
        case .terminatedBySystem: return "macOS removed the virtual display — waiting for the displays to settle."
        case .mirrorSet: return "macOS mirrored a display with the tablet — removed the virtual display for safety."
        }
    }
}

struct DisplaySafetyEvent: Sendable {
    let reason: DisplaySafetyReason
    /// true: the virtual display is gone (capture of it fails); false: only demoted (primary → extend), still alive.
    let destroyed: Bool
    var message: String { destroyed ? reason.message : "A Mac display changed — gave the main display back to the Mac (extending instead)." }
}

// MARK: - Pure policy (unit-testable)

/// Sliding-window limiter for virtual display CREATIONS (destroying is always allowed: it is the safe direction).
struct CreationRateLimiter {
    /// Planned re-creations (rotation, scale change, reconnect) are normal; this only stops a create/destroy loop.
    var maxCreations = 8
    var window: TimeInterval = 60
    /// Minimum time between the last destroy and the next create (WindowServer needs to finish the removal).
    var minGapAfterDestroy: TimeInterval = 0.5   // destroyAndWait already waits until the old display is offline
    private(set) var creations: [Date] = []
    private(set) var lastDestroy: Date?

    /// nil when a creation may happen now, else how long to wait.
    func delayBeforeCreate(now: Date = Date()) -> TimeInterval? {
        var wait: TimeInterval = 0
        let recent = creations.filter { now.timeIntervalSince($0) < window }
        if recent.count >= maxCreations, let oldest = recent.min() {
            wait = max(wait, window - now.timeIntervalSince(oldest))
        }
        if let d = lastDestroy {
            wait = max(wait, minGapAfterDestroy - now.timeIntervalSince(d))
        }
        return wait > 0 ? wait : nil
    }

    mutating func recordCreate(now: Date = Date()) {
        creations = creations.filter { now.timeIntervalSince($0) < window } + [now]
    }

    mutating func recordDestroy(now: Date = Date()) { lastDestroy = now }
}

/// Snapshot of the display state that the safety evaluation decides on.
struct DisplaySafetySnapshot: Equatable {
    var virtualOnline: Bool
    var virtualIsMain: Bool
    /// Physical (non-PlexiChore) displays that are active and awake.
    var usablePhysicalCount: Int
    var primaryWanted: Bool          // the session asked for primary AND it is in effect
    var physicalLostWhilePrimary: Bool
    var clientActive: Bool
    /// Seconds no usable physical display has been around while a client watched (0 when there is one).
    var noPhysicalFor: TimeInterval
    var virtualInMirrorSet: Bool
    /// The user opted in to keeping the tablet as the only display (lid closed) and the Mac is on AC power.
    var virtualOnlyAllowed: Bool = false
}

enum DisplaySafetyAction: Equatable {
    case none
    case destroy(DisplaySafetyReason)
    /// Give main back to a physical display (restore record / fallback); destroy if that fails.
    case restorePhysicalMain(DisplaySafetyReason)
    case unmirror
}

enum DisplaySafetyPolicy {
    /// How long a watching client may keep the virtual display as the ONLY usable display (e.g. lid closed, hub
    /// gone) before it is removed anyway: a Mac whose own screens are all dark is the failure we never accept.
    static let virtualOnlyGrace: TimeInterval = 10

    static func decide(_ s: DisplaySafetySnapshot) -> [DisplaySafetyAction] {
        guard s.virtualOnline else { return [] }
        if s.usablePhysicalCount == 0 {
            // Without a watching client the tablet-only setup always goes, opt-in or not: opening the lid then
            // brings the Mac's own screen back.
            if !s.clientActive || (!s.virtualOnlyAllowed && s.noPhysicalFor >= virtualOnlyGrace) {
                return [.destroy(.noPhysicalDisplay)]
            }
            return []   // a client is watching; re-evaluated until the grace runs out
        }
        var actions: [DisplaySafetyAction] = []
        if s.virtualInMirrorSet { actions.append(.unmirror) }
        if s.virtualIsMain {
            if s.physicalLostWhilePrimary {
                actions.append(.restorePhysicalMain(.physicalDisplayLost))
            } else if !s.primaryWanted || !s.clientActive {
                actions.append(.restorePhysicalMain(.virtualBecameMain))
            }
        } else if s.physicalLostWhilePrimary {
            // macOS already moved main away from the tablet: just drop primary state.
            actions.append(.restorePhysicalMain(.physicalDisplayLost))
        }
        return actions
    }
}

// MARK: - Display helpers

enum DisplayProbe {
    static let plexiVendor: UInt32 = 0x5058

    /// The Mac draws from AC power (the charger). Unknown → false, the safe answer.
    static func onACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == kIOPMACPowerKey
    }

    static func onlineDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        guard CGGetOnlineDisplayList(count, &ids, &actual) == .success else { return [] }
        return Array(ids.prefix(Int(actual)))
    }

    /// Physical displays a human can actually see the Mac desktop on: active, not ours (any PlexiChore virtual
    /// display has vendor 0x5058), and awake — an asleep one still counts while the virtual display sleeps too
    /// (ordinary idle display sleep is not a failure). Mirror slaves count — they show a picture.
    static func usablePhysicalDisplays(excluding virtualID: CGDirectDisplayID?) -> [CGDirectDisplayID] {
        let systemDisplaySleep = virtualID.map { CGDisplayIsAsleep($0) != 0 } ?? true
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        guard CGGetActiveDisplayList(count, &ids, &actual) == .success else { return [] }
        return ids.prefix(Int(actual)).filter { id in
            id != virtualID && CGDisplayVendorNumber(id) != plexiVendor
                && (CGDisplayIsAsleep(id) == 0 || systemDisplaySleep) && CGDisplayBounds(id).width > 0
        }
    }

    /// The virtual display mirrors something, or something mirrors it.
    static func isInMirrorSet(_ vid: CGDirectDisplayID) -> Bool {
        if CGDisplayMirrorsDisplay(vid) != kCGNullDirectDisplay { return true }
        return onlineDisplays().contains { $0 != vid && CGDisplayMirrorsDisplay($0) == vid }
    }

    /// Takes the virtual display out of any mirror set (both directions). Returns true on success / nothing to do.
    @discardableResult
    static func unmirror(_ vid: CGDirectDisplayID) -> Bool {
        let slaves = onlineDisplays().filter { $0 != vid && CGDisplayMirrorsDisplay($0) == vid }
        let mirrorsSomething = CGDisplayMirrorsDisplay(vid) != kCGNullDirectDisplay
        guard mirrorsSomething || !slaves.isEmpty else { return true }
        DisplayWatchdog.shared.markSensitive()
        var cfg: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&cfg) == .success, let cfg else { return false }
        var ok = true
        if mirrorsSomething { ok = CGConfigureDisplayMirrorOfDisplay(cfg, vid, kCGNullDirectDisplay) == .success && ok }
        for s in slaves { ok = CGConfigureDisplayMirrorOfDisplay(cfg, s, kCGNullDirectDisplay) == .success && ok }
        guard ok else { CGCancelDisplayConfiguration(cfg); return false }
        return CGCompleteDisplayConfiguration(cfg, .forSession) == .success
    }
}

// MARK: - Main-thread stall watchdog

/// Background watchdog: if the main thread does not respond for `stallLimit` seconds inside a "sensitive" window (a
/// display reconfiguration happened or we are applying one), the armed virtual display is invalidated from the
/// watchdog thread (PXVirtualDisplay.invalidate is thread-safe). The main thread notices later
/// (`consumeFired()`), cleans up its state and restores the arrangement.
final class DisplayWatchdog: @unchecked Sendable {
    static let shared = DisplayWatchdog()

    var stallLimit: TimeInterval = 6
    var sensitiveWindow: TimeInterval = 15

    private struct State: @unchecked Sendable {   // PXVirtualDisplay is thread-safe
        var lastBeat = ProcessInfo.processInfo.systemUptime
        var sensitiveUntil: TimeInterval = 0
        var armed: PXVirtualDisplay?
        var fired = false
    }
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let queue = DispatchQueue(label: "com.pntapps.plexichore.display-watchdog", qos: .userInteractive)
    private var beatTimer: DispatchSourceTimer?
    private var checkTimer: DispatchSourceTimer?
    private let log = Logger(subsystem: "com.pntapps.plexichore", category: "DisplaySafety")

    private init() {}

    func start() {
        guard beatTimer == nil else { return }
        let beat = DispatchSource.makeTimerSource(queue: .main)
        beat.schedule(deadline: .now(), repeating: 0.5, leeway: .milliseconds(100))
        beat.setEventHandler { [weak self] in
            self?.state.withLock { $0.lastBeat = ProcessInfo.processInfo.systemUptime }
        }
        beat.resume()
        beatTimer = beat

        let check = DispatchSource.makeTimerSource(queue: queue)
        check.schedule(deadline: .now() + 1, repeating: 1.0, leeway: .milliseconds(200))
        check.setEventHandler { [weak self] in self?.check() }
        check.resume()
        checkTimer = check
    }

    /// The display the watchdog may kill (nil = disarmed).
    func arm(_ display: PXVirtualDisplay?) {
        state.withLock { $0.armed = display }
    }

    /// Opens (or extends) the window in which a main-thread stall counts as "stuck in a display reconfiguration".
    func markSensitive() {
        let now = ProcessInfo.processInfo.systemUptime
        let until = now + sensitiveWindow
        let onMain = Thread.isMainThread
        state.withLock { s in
            s.sensitiveUntil = max(s.sensitiveUntil, until)
            if onMain { s.lastBeat = now }   // the main thread is demonstrably alive right now
        }
    }

    /// Main thread proof of life from inside a deliberate (bounded) wait.
    func beat() {
        let now = ProcessInfo.processInfo.systemUptime
        state.withLock { $0.lastBeat = now }
    }

    /// True once if the watchdog killed the display since the last call.
    func consumeFired() -> Bool {
        state.withLock { s in
            defer { s.fired = false }
            return s.fired
        }
    }

    /// Invalidates the armed display right now from the calling thread (signal fallback when main is stuck).
    func invalidateArmedNow() {
        let victim: PXVirtualDisplay? = state.withLock { s in
            defer { s.armed = nil }
            if s.armed != nil { s.fired = true }
            return s.armed
        }
        victim?.invalidate()
    }

    private func check() {
        let now = ProcessInfo.processInfo.systemUptime
        let victim: PXVirtualDisplay? = state.withLock { s in
            guard let d = s.armed, now - s.lastBeat > stallLimit, now < s.sensitiveUntil + stallLimit else { return nil }
            s.armed = nil
            s.fired = true
            return d
        }
        guard let victim else { return }
        log.error("main thread stalled > \(self.stallLimit, privacy: .public)s during a display reconfiguration: invalidating virtual display \(victim.displayID, privacy: .public)")
        victim.invalidate()
    }
}

// MARK: - CoreGraphics reconfiguration callback

/// Forwards CGDisplayRegisterReconfigurationCallback events to the main queue. The callback itself does nothing but
/// record (Apple: never reconfigure displays from inside the callback).
final class DisplayReconfigurationMonitor: @unchecked Sendable {   // used from the main thread only
    struct Event { let display: CGDirectDisplayID; let flags: CGDisplayChangeSummaryFlags }

    private let handler: (Event) -> Void
    private var registered = false

    init(handler: @escaping (Event) -> Void) { self.handler = handler }

    func start() {
        guard !registered else { return }
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        registered = CGDisplayRegisterReconfigurationCallback(Self.callback, ctx) == .success
    }

    func stop() {
        guard registered else { return }
        CGDisplayRemoveReconfigurationCallback(Self.callback, Unmanaged.passUnretained(self).toOpaque())
        registered = false
    }

    deinit { stop() }

    private static let callback: CGDisplayReconfigurationCallBack = { display, flags, userInfo in
        guard let userInfo else { return }
        DisplayWatchdog.shared.markSensitive()
        let monitor = Unmanaged<DisplayReconfigurationMonitor>.fromOpaque(userInfo).takeUnretainedValue()
        let event = Event(display: display, flags: flags)
        // Delivered on the main run loop in practice; hop anyway so the handler never runs inside the callback.
        DispatchQueue.main.async { monitor.handler(event) }
    }
}

// MARK: - Global emergency hotkey (Carbon; needs no Accessibility permission)

final class EmergencyHotKey: @unchecked Sendable {   // used from the main thread only
    /// ⌃⌥⌘D
    static let keyCode = UInt32(kVK_ANSI_D)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let displayString = "⌃⌥⌘D"

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private let log = Logger(subsystem: "com.pntapps.plexichore", category: "DisplaySafety")

    init(action: @escaping () -> Void) { self.action = action }

    @discardableResult
    func register() -> Bool {
        guard hotKeyRef == nil else { return true }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let installed = InstallEventHandler(GetApplicationEventTarget(), Self.carbonHandler, 1, &spec, ctx, &handlerRef)
        guard installed == noErr else {
            log.error("InstallEventHandler failed: \(installed, privacy: .public)")
            return false
        }
        let id = EventHotKeyID(signature: 0x5058_4448 /* 'PXDH' */, id: 1)
        let st = RegisterEventHotKey(Self.keyCode, Self.modifiers, id, GetApplicationEventTarget(), 0, &hotKeyRef)
        if st != noErr {
            log.error("RegisterEventHotKey \(Self.displayString, privacy: .public) failed: \(st, privacy: .public)")
            hotKeyRef = nil
            return false
        }
        return true
    }

    func unregister() {
        if let r = hotKeyRef { UnregisterEventHotKey(r); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
    }

    deinit { unregister() }

    private static let carbonHandler: EventHandlerUPP = { _, event, userInfo in
        guard let event, let userInfo else { return OSStatus(eventNotHandledErr) }
        var hk = EventHotKeyID()
        let st = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                   nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        guard st == noErr, hk.signature == 0x5058_4448, hk.id == 1 else { return OSStatus(eventNotHandledErr) }
        let me = Unmanaged<EmergencyHotKey>.fromOpaque(userInfo).takeUnretainedValue()
        DispatchQueue.main.async { me.action() }
        return noErr
    }
}

// MARK: - Termination / emergency signals

/// SIGTERM / SIGINT / SIGHUP → release the display, then quit; SIGUSR1 → emergency release only
/// (`killall -USR1 PlexiChore` from Terminal or SSH when the screen is unusable).
/// Handled on a background queue so it works while the main thread is stuck: the main thread gets `mainGrace`
/// to do the clean release (restore arrangement first); otherwise the display is invalidated directly.
final class SafetySignalHandler {
    private var sources: [DispatchSourceSignal] = []
    private let queue = DispatchQueue(label: "com.pntapps.plexichore.signals")
    private let mainGrace: TimeInterval = 1.5

    /// `release` runs on the main thread; `fallbackInvalidate` on the signal queue when main does not respond.
    func install(release: @escaping @MainActor (DisplaySafetyReason) -> Void,
                 fallbackInvalidate: @escaping @Sendable () -> Void) {
        guard sources.isEmpty else { return }
        for sig in [SIGTERM, SIGINT, SIGHUP, SIGUSR1] {
            signal(sig, SIG_IGN)   // let the dispatch source own it
            let src = DispatchSource.makeSignalSource(signal: sig, queue: queue)
            let quit = sig != SIGUSR1
            let grace = mainGrace
            src.setEventHandler {
                let done = DispatchSemaphore(value: 0)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { release(quit ? .terminating : .emergency) }
                    done.signal()
                }
                if done.wait(timeout: .now() + grace) == .timedOut { fallbackInvalidate() }
                guard quit else { return }
                DispatchQueue.main.async { NSApp.terminate(nil) }   // exits the process when it completes
                // Hard stop if terminate never completes (process death also removes the display). _exit: no
                // atexit handlers / static destructors racing the still-running main thread.
                Thread.sleep(forTimeInterval: 8)
                _exit(0)
            }
            src.resume()
            sources.append(src)
        }
    }
}
