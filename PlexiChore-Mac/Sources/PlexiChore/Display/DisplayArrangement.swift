import ColorSync
import CoreGraphics
import Foundation

/// Display arrangement helpers for "extend" and "primary" mode (see PROTOCOL.md `requested.mode`).
///
/// Coordinates: CoreGraphics global display space, in points. The main display is, by definition, the one whose
/// origin is (0,0); y grows DOWNWARD (so "top" means a smaller y). macOS moves the menu bar to whichever display is
/// at (0,0), which is how "primary" mode works.
///
/// Configuration scope: everything here is applied with `.forSession` (lasts until logout, which is all an
/// extend/primary session needs). `.permanently` asks for the layout to be kept as the user's default; a layout
/// containing a transient virtual display (possibly as MAIN) must never be promoted to that. `.forAppOnly` would
/// revert on exit, but the virtual display dies with the process anyway and the revert would race macOS's own
/// "main display vanished" handling; the explicit restore file below is deterministic and survives a hard kill.
/// CAVEAT (measured on macOS 27): WindowServer still records the arrangement of every display SET it has seen in
/// /Library/Preferences/com.apple.windowserver.displays.plist (`DisplayAnyUserSets`), keyed by display UUIDs, even
/// for `.forSession` changes. A virtual display that reappears with the same UUID (same vendor/product/serial) is
/// put back where it was last seen — including as the MAIN display if the app died while in primary mode. Hence
/// `placeBeside` first demotes a virtual display that came up as main (`demoteIfMain`), and `makePrimary` always
/// writes a restore record even when the virtual display is already main.
///
/// "Primary" safety: before the first change the original arrangement (display UUIDs + origins) is written to
/// `~/Library/Application Support/PlexiChore/primary-restore.json` (same semantics as Windows
/// `%APPDATA%\PlexiChore\primary-restore.json`): an existing record is kept (it is the true original after a crash),
/// `restorePrimary()` puts it back and deletes it, `restoreIfCrashed()` runs at launch.
enum DisplayArrangement {

    // MARK: - Restore record

    struct Placement: Codable, Equatable {
        var uuid: String
        var displayID: UInt32      // informational only; ids are not stable across reboots, UUIDs are
        var isMain: Bool
        var isVirtual: Bool        // our own virtual display (restored only if it is still present)
        var x: Int
        var y: Int
        var width: Int
        var height: Int
    }

    struct RestoreRecord: Codable {
        static let currentVersion = 1
        var version: Int
        var createdUtc: Date
        var virtualUUID: String
        var original: [Placement]

        var originalMain: Placement? { original.first { $0.isMain && !$0.isVirtual } }
    }

    enum ArrangementError: LocalizedError {
        case notOnline
        case cannotSaveRestoreRecord(String)
        case configurationFailed(CGError)
        case notMainAfterApply

        var errorDescription: String? {
            switch self {
            case .notOnline: return "The virtual display is not online."
            case .cannotSaveRestoreRecord(let why): return "Could not save the current display layout (\(why)); refusing to change the main display."
            case .configurationFailed(let e): return "macOS refused the display configuration (CGError \(e.rawValue))."
            case .notMainAfterApply: return "macOS did not make the virtual display the main display."
            }
        }
    }

    static var restoreFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("PlexiChore", isDirectory: true)
            .appendingPathComponent("primary-restore.json")
    }

    /// True while the virtual display is (or, after a crash, may still be) the main display.
    static var hasPendingPrimaryRestore: Bool { FileManager.default.fileExists(atPath: restoreFileURL.path) }

    // MARK: - Extend: place beside a display

    /// Moves `virtualID` next to `mainID` on `position`, sharing that edge. On the other axis it is centered, or
    /// aligned to the top/left edge when it is at least as large as `mainID` (so the shared edge stays in contact,
    /// same rule as Windows `DisplayLayout.ComputePosition`). If that spot overlaps a third display it is pushed
    /// further out past it. Returns the origin requested (macOS may still nudge it to keep displays contiguous).
    @discardableResult
    static func placeBeside(virtualID: CGDirectDisplayID, of mainID: CGDirectDisplayID,
                            position: DisplayPlacement, settle: Bool = true) throws -> CGPoint {
        var mainID = mainID
        if mainID == virtualID || CGMainDisplayID() == virtualID {
            // macOS restored a remembered "virtual is main" layout (see type comment): give main back first.
            guard let real = try demoteIfMain(virtualID: virtualID) ?? fallbackMain(excluding: virtualID) else {
                throw ArrangementError.notOnline
            }
            mainID = real
        }
        let main = CGDisplayBounds(mainID)
        let vb = CGDisplayBounds(virtualID)
        guard vb.width > 0, vb.height > 0, main.width > 0 else { throw ArrangementError.notOnline }
        let others = activeDisplays().filter { $0 != virtualID && $0 != mainID }.map { CGDisplayBounds($0) }
        let origin = besideOrigin(main: main, size: vb.size, others: others, position: position)

        try apply([(virtualID, origin)])
        if settle { waitUntil { CGDisplayBounds(virtualID).origin != vb.origin || vb.origin == origin } }
        return origin
    }

    /// Pure geometry for `placeBeside` (integral points).
    static func besideOrigin(main: CGRect, size: CGSize, others: [CGRect], position: DisplayPlacement) -> CGPoint {
        let w = size.width.rounded(), h = size.height.rounded()
        var p: CGPoint
        switch position {
        case .right:  p = CGPoint(x: main.maxX, y: main.minY + ((main.height - h) / 2).rounded(.down))
        case .left:   p = CGPoint(x: main.minX - w, y: main.minY + ((main.height - h) / 2).rounded(.down))
        case .top:    p = CGPoint(x: main.minX + ((main.width - w) / 2).rounded(.down), y: main.minY - h)
        case .bottom: p = CGPoint(x: main.minX + ((main.width - w) / 2).rounded(.down), y: main.maxY)
        }
        // Keep the shared edge in contact (a larger tablet would otherwise stick out on both sides).
        if (position == .left || position == .right) && h >= main.height { p.y = main.minY }
        if (position == .top || position == .bottom) && w >= main.width { p.x = main.minX }

        for _ in 0..<32 {
            let r = CGRect(origin: p, size: CGSize(width: w, height: h))
            guard let hit = others.first(where: { $0.intersects(r) }) else { break }
            switch position {
            case .right:  p.x = hit.maxX
            case .left:   p.x = hit.minX - w
            case .top:    p.y = hit.minY - h
            case .bottom: p.y = hit.maxY
            }
        }
        return p
    }

    // MARK: - Primary

    /// Makes `virtualID` the macOS main display (menu bar moves there): every active display is shifted by the same
    /// offset so the virtual one lands at (0,0); the relative arrangement is preserved (tablet right of the old main
    /// → old main ends up at negative x). The original arrangement is saved to the restore file FIRST.
    /// Call after `placeBeside` so the relationship is the one the user asked for.
    static func makePrimary(virtualID: CGDirectDisplayID) throws {
        let layout = currentLayout(virtualID: virtualID)
        guard let v = layout.first(where: { $0.displayID == virtualID }) else { throw ArrangementError.notOnline }
        // Save first, ALWAYS: even when macOS already made the virtual display main on its own (remembered display
        // set), a record is needed so detach/crash recovery gives main back (fallback picks the real display).
        try saveRestoreRecord(layout: layout, virtualUUID: v.uuid)
        if CGMainDisplayID() == virtualID && v.x == 0 && v.y == 0 { return }

        let dx = -v.x, dy = -v.y
        let plan = layout.map { (CGDirectDisplayID($0.displayID), CGPoint(x: $0.x + dx, y: $0.y + dy)) }
        do {
            try apply(plan)
        } catch {
            _ = try? restorePrimary()
            throw error
        }
        waitUntil(maxWait: 0.5) { CGMainDisplayID() == virtualID }   // once per session start
        if CGMainDisplayID() != virtualID {
            _ = try? restorePrimary()
            throw ArrangementError.notMainAfterApply
        }
    }

    /// Puts the saved arrangement back (matching by UUID, skipping displays that are gone) and deletes the record.
    /// Call it BEFORE destroying the virtual display, so macOS never has to pick a new main display itself; it also
    /// works after the virtual display is gone. Displays not in the record are parked right of the restored layout.
    /// Returns true when the restored layout was verified.
    @discardableResult
    static func restorePrimary(attempts: Int = 2) throws -> Bool {
        guard let record = loadRestoreRecord() else {
            deleteRestoreRecord()
            return true
        }
        defer { deleteRestoreRecord() }   // like Windows: never loop on a record that cannot be satisfied
        guard let plan = planRestore(record, current: currentLayout(virtualID: nil)) else { return false }
        if isSatisfied(plan) { return true }
        for _ in 0..<max(1, attempts) {
            try apply(plan.map { (CGDirectDisplayID($0.displayID), CGPoint(x: $0.x, y: $0.y)) })
            waitUntil { isSatisfied(plan) }
            if isSatisfied(plan) { return true }
        }
        return isSatisfied(plan)
    }

    /// Call once at launch: a restore record whose virtual display is no longer online means the app crashed / was
    /// killed while the tablet was the main display. Returns true if a restore was attempted.
    @discardableResult
    static func restoreIfCrashed() -> Bool {
        guard hasPendingPrimaryRestore else { return false }
        guard let record = loadRestoreRecord() else { deleteRestoreRecord(); return false }
        // Online, not just active: a virtual display that ended up as a mirror slave is still alive.
        let present = DisplayProbe.onlineDisplays().contains { uuidString(for: $0) == record.virtualUUID }
        if present { return false }   // still alive (another instance owns it): leave it alone
        _ = try? restorePrimary()
        return true
    }

    /// If `virtualID` is the main display, shifts every display so a real one is at (0,0) again: the restore
    /// record's original main when present, else `fallbackMain`. Returns the new main id, or nil if nothing changed.
    @discardableResult
    static func demoteIfMain(virtualID: CGDirectDisplayID) throws -> CGDirectDisplayID? {
        guard CGMainDisplayID() == virtualID else { return nil }
        let layout = currentLayout(virtualID: virtualID)
        let recorded = loadRestoreRecord()?.originalMain?.uuid
        guard let target = layout.first(where: { $0.uuid == recorded && $0.displayID != virtualID })
                ?? fallbackMain(excluding: virtualID).flatMap({ id in layout.first { $0.displayID == id } })
        else { return nil }
        let dx = -target.x, dy = -target.y
        try apply(layout.map { (CGDirectDisplayID($0.displayID), CGPoint(x: $0.x + dx, y: $0.y + dy)) })
        let id = CGDirectDisplayID(target.displayID)
        waitUntil(maxWait: 0.4) { CGMainDisplayID() == id }
        return id
    }

    /// Best guess for "the user's real main display" when the virtual one holds that role: built-in panel first,
    /// then a non-PlexiChore display (vendor 0x5058 = our virtual displays, any process), nearest to (0,0).
    static func fallbackMain(excluding virtualID: CGDirectDisplayID) -> CGDirectDisplayID? {
        let candidates = activeDisplays().filter { $0 != virtualID }
        if let builtin = candidates.first(where: { CGDisplayIsBuiltin($0) != 0 }) { return builtin }
        func distance(_ id: CGDirectDisplayID) -> CGFloat {
            let b = CGDisplayBounds(id)
            let dx = max(b.minX, 0, -b.maxX), dy = max(b.minY, 0, -b.maxY)   // gap between rect and origin
            return dx * dx + dy * dy
        }
        let real = candidates.filter { CGDisplayVendorNumber($0) != 0x5058 }
        return (real.isEmpty ? candidates : real).min { distance($0) < distance($1) }
    }

    // MARK: - Planning (pure)

    /// Positions that put the record back for the displays now online. Returns nil when the original main display is
    /// gone (macOS then keeps whatever main it picked). The original main is normalised to (0,0).
    static func planRestore(_ record: RestoreRecord, current: [Placement]) -> [Placement]? {
        guard let origMain = record.originalMain,
              current.contains(where: { $0.uuid == origMain.uuid }) else { return nil }
        let dx = -origMain.x, dy = -origMain.y
        var plan: [Placement] = []
        var unmatched: [Placement] = []
        for c in current {
            if let o = record.original.first(where: { $0.uuid == c.uuid }) {
                var p = c
                p.x = o.x + dx; p.y = o.y + dy; p.isMain = o.isMain && !o.isVirtual
                plan.append(p)
            } else {
                unmatched.append(c)
            }
        }
        if !unmatched.isEmpty {
            let union = plan.reduce(CGRect.null) { $0.union(CGRect(x: $1.x, y: $1.y, width: $1.width, height: $1.height)) }
            var x = Int(union.maxX)
            for var u in unmatched {
                u.x = x; u.y = Int(union.minY); u.isMain = false
                plan.append(u)
                x += max(1, u.width)
            }
        }
        return plan
    }

    static func isSatisfied(_ plan: [Placement]) -> Bool {
        let now = currentLayout(virtualID: nil)
        return plan.allSatisfy { p in now.contains { $0.uuid == p.uuid && $0.x == p.x && $0.y == p.y } }
    }

    // MARK: - Current state

    /// Active displays that own a position (mirror-set slaves excluded: only the master is moved).
    static func activeDisplays() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        guard CGGetActiveDisplayList(count, &ids, &actual) == .success else { return [] }
        return ids.prefix(Int(actual)).filter { CGDisplayMirrorsDisplay($0) == kCGNullDirectDisplay }
    }

    static func uuidString(for id: CGDirectDisplayID) -> String? {
        guard let u = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, u) as String?
    }

    static func currentLayout(virtualID: CGDirectDisplayID?) -> [Placement] {
        let main = CGMainDisplayID()
        return activeDisplays().compactMap { id in
            let b = CGDisplayBounds(id)
            guard b.width > 0, let uuid = uuidString(for: id) else { return nil }
            return Placement(uuid: uuid, displayID: id, isMain: id == main, isVirtual: id == virtualID,
                             x: Int(b.minX.rounded()), y: Int(b.minY.rounded()),
                             width: Int(b.width.rounded()), height: Int(b.height.rounded()))
        }
    }

    // MARK: - Record I/O

    private static func makeEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    static func loadRestoreRecord() -> RestoreRecord? {
        guard let data = try? Data(contentsOf: restoreFileURL) else { return nil }
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        guard let r = try? d.decode(RestoreRecord.self, from: data), r.originalMain != nil else { return nil }
        return r
    }

    /// Writes the record atomically. An existing valid record is kept: it is the true original (e.g. a crash happened
    /// while primary and recovery has not run yet); only its virtual UUID is refreshed.
    private static func saveRestoreRecord(layout: [Placement], virtualUUID: String) throws {
        var record: RestoreRecord
        if var existing = loadRestoreRecord() {
            existing.virtualUUID = virtualUUID
            record = existing
        } else {
            var original = layout
            let virtualID = original.first(where: { $0.isVirtual }).map { CGDirectDisplayID($0.displayID) } ?? 0
            if !original.contains(where: { $0.isMain && !$0.isVirtual }),
               let best = fallbackMain(excluding: virtualID),
               let i = original.firstIndex(where: { $0.displayID == best }) {
                // main is currently a virtual display (remembered display set): treat the best real one as original
                for j in original.indices { original[j].isMain = false }
                original[i].isMain = true
            }
            record = RestoreRecord(version: RestoreRecord.currentVersion, createdUtc: Date(),
                                   virtualUUID: virtualUUID, original: original)
        }
        do {
            try FileManager.default.createDirectory(at: restoreFileURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try makeEncoder().encode(record).write(to: restoreFileURL, options: .atomic)
        } catch {
            throw ArrangementError.cannotSaveRestoreRecord(error.localizedDescription)
        }
    }

    static func deleteRestoreRecord() {
        try? FileManager.default.removeItem(at: restoreFileURL)
    }

    // MARK: - Applying

    /// One CGBegin/CGComplete transaction; `.forSession` (see type comment).
    private static func apply(_ origins: [(CGDirectDisplayID, CGPoint)]) throws {
        DisplayWatchdog.shared.markSensitive()   // a stall inside CGComplete… is what the watchdog is for
        var config: CGDisplayConfigRef?
        let b = CGBeginDisplayConfiguration(&config)
        guard b == .success, let config else { throw ArrangementError.configurationFailed(b) }
        for (id, p) in origins {
            let e = CGConfigureDisplayOrigin(config, id, Int32(p.x.rounded()), Int32(p.y.rounded()))
            if e != .success {
                CGCancelDisplayConfiguration(config)
                throw ArrangementError.configurationFailed(e)
            }
        }
        let c = CGCompleteDisplayConfiguration(config, .forSession)
        if c != .success { throw ArrangementError.configurationFailed(c) }
    }

    /// Polls (≤ `maxWait`, default 0.25 s) until `done` holds; CGDisplayBounds/CGMainDisplayID update shortly after
    /// the commit. This blocks the main thread, so it is deliberately short: one operation (destroy, restore,
    /// demote + place) stays well under 1 s of blocking, and it reports a heartbeat so the stall watchdog never
    /// mistakes this bounded wait for a hang. Callers verify the outcome themselves.
    private static func waitUntil(maxWait: TimeInterval = 0.25, _ done: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + maxWait
        while !done() {
            if ProcessInfo.processInfo.systemUptime >= deadline { return }
            Thread.sleep(forTimeInterval: 0.02)
            if Thread.isMainThread { DisplayWatchdog.shared.beat() }
        }
    }
}
