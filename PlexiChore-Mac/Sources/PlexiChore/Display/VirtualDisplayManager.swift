import AppKit
import CoreGraphics
import CVirtualDisplay

enum DisplayPlacement: String {
    case right, left, top, bottom
}

enum VirtualDisplayError: LocalizedError {
    case unsupported
    case creationFailed
    case didNotAppear

    var errorDescription: String? {
        switch self {
        case .unsupported: return "This macOS version does not provide CGVirtualDisplay."
        case .creationFailed: return "macOS refused to create the virtual display."
        case .didNotAppear: return "The virtual display did not come online."
        }
    }
}

/// Owns the (at most one) PlexiChore virtual display used for "extend" mode.
@MainActor
final class VirtualDisplayManager {
    nonisolated static var isSupported: Bool { PXVirtualDisplay.isSupported() }

    private(set) var display: PXVirtualDisplay?
    private var nextSerial: UInt32 = UInt32.random(in: 0x1000...0xFFFF)

    var displayID: CGDirectDisplayID? {
        guard let d = display, d.displayID != 0 else { return nil }
        return d.displayID
    }

    /// Creates (or reuses) a virtual display with the given backing pixel size and moves it
    /// next to the main display. Returns its display id once it is online.
    func ensureDisplay(name: String,
                       pixelWidth: Int,
                       pixelHeight: Int,
                       ppi: Double,
                       hiDPI: Bool,
                       refreshRate: Double,
                       placement: DisplayPlacement) async throws -> CGDirectDisplayID {
        guard Self.isSupported else { throw VirtualDisplayError.unsupported }

        if let existing = display, existing.displayID != 0,
           existing.pixelWidth == pixelWidth, existing.pixelHeight == pixelHeight,
           existing.hiDPI == hiDPI {
            place(existing.displayID, placement: placement)
            return existing.displayID
        }

        destroy()
        // Give WindowServer a moment to tear the old display down before creating a new one.
        try? await Task.sleep(nanoseconds: 300_000_000)

        nextSerial &+= 1
        guard let vd = PXVirtualDisplay(name: name,
                                        pixelWidth: pixelWidth,
                                        pixelHeight: pixelHeight,
                                        ppi: ppi,
                                        hiDPI: hiDPI,
                                        refreshRate: refreshRate,
                                        serialNumber: nextSerial) else {
            throw VirtualDisplayError.creationFailed
        }
        display = vd
        DisplayCatalog.setExcluded([vd.displayID])

        let id = vd.displayID
        var online = false
        for _ in 0..<50 {   // up to ~5 s
            if Self.isOnline(id) && CGDisplayBounds(id).width > 0 {
                online = true
                break
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        guard online else {
            destroy()
            throw VirtualDisplayError.didNotAppear
        }
        place(id, placement: placement)
        // Let the arrangement settle so CGDisplayBounds reflects the new origin.
        try? await Task.sleep(nanoseconds: 200_000_000)
        return id
    }

    func destroy() {
        display?.invalidate()
        display = nil
        DisplayCatalog.setExcluded([])
    }

    /// Positions `id` relative to the main display (edge-aligned, centered on the other axis).
    func place(_ id: CGDirectDisplayID, placement: DisplayPlacement) {
        let main = CGDisplayBounds(CGMainDisplayID())
        let vb = CGDisplayBounds(id)
        guard vb.width > 0, vb.height > 0 else { return }

        let x: CGFloat
        let y: CGFloat
        switch placement {
        case .right:
            x = main.maxX
            y = main.minY + (main.height - vb.height) / 2
        case .left:
            x = main.minX - vb.width
            y = main.minY + (main.height - vb.height) / 2
        case .top:
            x = main.minX + (main.width - vb.width) / 2
            y = main.minY - vb.height
        case .bottom:
            x = main.minX + (main.width - vb.width) / 2
            y = main.maxY
        }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success, let config else { return }
        let err = CGConfigureDisplayOrigin(config, id, Int32(x.rounded()), Int32(y.rounded()))
        if err != .success {
            CGCancelDisplayConfiguration(config)
            return
        }
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    nonisolated static func isOnline(_ id: CGDirectDisplayID) -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success, count > 0 else { return false }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        let capacity = count
        var actual: UInt32 = 0
        guard CGGetOnlineDisplayList(capacity, &ids, &actual) == .success else { return false }
        return ids.prefix(Int(actual)).contains(id)
    }
}
