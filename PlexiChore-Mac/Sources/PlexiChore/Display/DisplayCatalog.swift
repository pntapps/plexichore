import AppKit
import CoreGraphics

/// Enumerates the physical (non-PlexiChore) displays. Index 0 is always the main display.
enum DisplayCatalog {
    struct Display {
        let index: Int
        let id: CGDirectDisplayID
        let name: String
        /// Size in points (global coordinate space).
        let bounds: CGRect
        /// Backing size in pixels.
        let pixelWidth: Int
        let pixelHeight: Int
    }

    /// Display ids that belong to our own virtual displays (excluded from the monitor list).
    private static var excludedIDs: Set<CGDirectDisplayID> = []   // guarded by `lock`
    private static let lock = NSLock()

    static func setExcluded(_ ids: Set<CGDirectDisplayID>) {
        lock.lock(); excludedIDs = ids; lock.unlock()
    }

    private static func excluded() -> Set<CGDirectDisplayID> {
        lock.lock(); defer { lock.unlock() }
        return excludedIDs
    }

    static func activeDisplays() -> [Display] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let capacity = count
        var actual: UInt32 = 0
        guard CGGetActiveDisplayList(capacity, &ids, &actual) == .success else { return [] }
        ids = Array(ids.prefix(Int(actual)))

        let skip = excluded()
        let main = CGMainDisplayID()
        // Hide hardware-mirrored secondaries; keep only mirror-set masters.
        // Also skip every PlexiChore virtual display (vendor 0x5058), even one that is being torn down / no longer
        // tracked, so a mirror fallback after a safety release never picks the dying display.
        var filtered = ids.filter { !skip.contains($0) && CGDisplayMirrorsDisplay($0) == 0
                                    && CGDisplayVendorNumber($0) != DisplayProbe.plexiVendor }
        filtered.sort { a, b in
            if a == b { return false }
            if a == main { return true }
            if b == main { return false }
            let ba = CGDisplayBounds(a), bb = CGDisplayBounds(b)
            return ba.minX == bb.minX ? ba.minY < bb.minY : ba.minX < bb.minX
        }

        let names = screenNames()
        return filtered.enumerated().map { idx, id in
            let mode = CGDisplayCopyDisplayMode(id)
            let pw = mode?.pixelWidth ?? Int(CGDisplayPixelsWide(id))
            let ph = mode?.pixelHeight ?? Int(CGDisplayPixelsHigh(id))
            let fallback = id == main ? "Main Display" : "Display \(idx + 1)"
            return Display(index: idx, id: id, name: names[id] ?? fallback,
                           bounds: CGDisplayBounds(id), pixelWidth: pw, pixelHeight: ph)
        }
    }

    static func monitorInfos() -> [MonitorInfo] {
        activeDisplays().map { MonitorInfo(index: $0.index, name: $0.name, width: $0.pixelWidth, height: $0.pixelHeight) }
    }

    /// Localized names from NSScreen (only safe/accurate on the main thread; falls back otherwise).
    private static func screenNames() -> [CGDirectDisplayID: String] {
        guard Thread.isMainThread else { return [:] }
        var names: [CGDirectDisplayID: String] = [:]
        for screen in NSScreen.screens {
            let key = NSDeviceDescriptionKey("NSScreenNumber")
            if let num = screen.deviceDescription[key] as? NSNumber {
                names[CGDirectDisplayID(num.uint32Value)] = screen.localizedName
            }
        }
        return names
    }
}
