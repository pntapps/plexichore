import XCTest
@testable import PlexiChore

/// Pure parts of the virtual display safety net (Display/DisplaySafety.swift): DisplaySafetyPolicy.decide and
/// CreationRateLimiter, plus VirtualDisplayRequest helpers. The debounce / hold timers live in the @MainActor
/// VirtualDisplayManager (it installs a hotkey and signal handlers on init), so only its documented tuning is
/// referenced here, not exercised.
final class DisplaySafetyTests: XCTestCase {
    typealias S = DisplaySafetySnapshot

    /// A healthy extend session: virtual display online beside one physical display, client watching.
    func snap(_ edit: (inout S) -> Void = { _ in }) -> S {
        var s = S(virtualOnline: true, virtualIsMain: false, usablePhysicalCount: 1, primaryWanted: false,
                  physicalLostWhilePrimary: false, clientActive: true, noPhysicalFor: 0, virtualInMirrorSet: false)
        edit(&s)
        return s
    }

    func decide(_ edit: (inout S) -> Void = { _ in }) -> [DisplaySafetyAction] { DisplaySafetyPolicy.decide(snap(edit)) }

    // MARK: Policy

    func testHealthyExtendDoesNothing() {
        XCTAssertEqual(decide(), [])
        XCTAssertEqual(decide { $0.virtualIsMain = true; $0.primaryWanted = true }, [])   // primary as requested
    }

    func testOfflineVirtualDisplayDoesNothing() {
        XCTAssertEqual(decide { $0.virtualOnline = false; $0.usablePhysicalCount = 0; $0.clientActive = false }, [])
    }

    func testNoPhysicalDisplayWithoutClientDestroysNow() {
        XCTAssertEqual(decide { $0.usablePhysicalCount = 0; $0.clientActive = false }, [.destroy(.noPhysicalDisplay)])
    }

    func testNoPhysicalDisplayWithClientWaitsForGrace() {
        XCTAssertEqual(DisplaySafetyPolicy.virtualOnlyGrace, 10)
        XCTAssertEqual(decide { $0.usablePhysicalCount = 0; $0.noPhysicalFor = 0 }, [])
        XCTAssertEqual(decide { $0.usablePhysicalCount = 0; $0.noPhysicalFor = 9.9 }, [])
        XCTAssertEqual(decide { $0.usablePhysicalCount = 0; $0.noPhysicalFor = 10 }, [.destroy(.noPhysicalDisplay)])
        // no other action can be combined with the destroy
        XCTAssertEqual(decide { $0.usablePhysicalCount = 0; $0.noPhysicalFor = 30; $0.virtualIsMain = true; $0.virtualInMirrorSet = true },
                       [.destroy(.noPhysicalDisplay)])
    }

    func testLidClosedOptInKeepsWatchedTabletOnly() {
        // opted in (and on AC power): a watched tablet may stay the only display past the grace
        XCTAssertEqual(decide { $0.usablePhysicalCount = 0; $0.noPhysicalFor = 600; $0.virtualOnlyAllowed = true; $0.virtualIsMain = true }, [])
        // but never once nobody watches it: opening the lid must bring the Mac's own screen back
        XCTAssertEqual(decide { $0.usablePhysicalCount = 0; $0.clientActive = false; $0.virtualOnlyAllowed = true },
                       [.destroy(.noPhysicalDisplay)])
        // the opt-in changes nothing while a physical display is usable
        XCTAssertEqual(decide { $0.virtualIsMain = true; $0.virtualOnlyAllowed = true }, [.restorePhysicalMain(.virtualBecameMain)])
    }

    func testVirtualMainWithoutPrimaryRequestIsDemoted() {
        XCTAssertEqual(decide { $0.virtualIsMain = true }, [.restorePhysicalMain(.virtualBecameMain)])
        // primary requested but nobody watching any more
        XCTAssertEqual(decide { $0.virtualIsMain = true; $0.primaryWanted = true; $0.clientActive = false },
                       [.restorePhysicalMain(.virtualBecameMain)])
    }

    func testPhysicalLossInPrimaryRestores() {
        XCTAssertEqual(decide { $0.virtualIsMain = true; $0.primaryWanted = true; $0.physicalLostWhilePrimary = true },
                       [.restorePhysicalMain(.physicalDisplayLost)])
        // macOS already moved main away: still drop primary state
        XCTAssertEqual(decide { $0.physicalLostWhilePrimary = true }, [.restorePhysicalMain(.physicalDisplayLost)])
    }

    func testMirrorSetIsUnmirroredFirst() {
        XCTAssertEqual(decide { $0.virtualInMirrorSet = true }, [.unmirror])
        XCTAssertEqual(decide { $0.virtualInMirrorSet = true; $0.virtualIsMain = true },
                       [.unmirror, .restorePhysicalMain(.virtualBecameMain)])
    }

    func testNeverLeavesVirtualAsOnlyOrUnwatchedMain() {
        // exhaustive: whatever the state, the result never keeps an unwatched virtual display as main or as the
        // only usable display past the grace
        for online in [false, true] { for isMain in [false, true] { for phys in [0, 1, 2] {
        for wanted in [false, true] { for lost in [false, true] { for client in [false, true] {
        for noPhys in [0.0, 5, 10, 60] { for mirror in [false, true] {
            let s = S(virtualOnline: online, virtualIsMain: isMain, usablePhysicalCount: phys, primaryWanted: wanted,
                      physicalLostWhilePrimary: lost, clientActive: client, noPhysicalFor: noPhys, virtualInMirrorSet: mirror)
            let a = DisplaySafetyPolicy.decide(s)
            guard online else { XCTAssertEqual(a, []); continue }
            if phys == 0 && (!client || noPhys >= 10) { XCTAssertEqual(a, [.destroy(.noPhysicalDisplay)], "\(s)") }
            if phys > 0 && isMain && (!client || !wanted || lost) {
                XCTAssertTrue(a.contains { if case .restorePhysicalMain = $0 { return true }; return false }, "\(s)")
            }
            if phys > 0 && mirror { XCTAssertEqual(a.first, .unmirror, "\(s)") }
        }}}}}}}}
    }

    func testReasonMessagesAndEvents() {
        let all: [DisplaySafetyReason] = [.emergency, .sleep, .terminating, .noPhysicalDisplay, .physicalDisplayLost,
                                          .virtualBecameMain, .watchdog, .clientGone, .mirrorSet,
                                          .terminatedBySystem]
        XCTAssertEqual(Set(all.map(\.message)).count, all.count)
        XCTAssertTrue(DisplaySafetyReason.emergency.message.contains("⌃⌥⌘D"))
        let demoted = DisplaySafetyEvent(reason: .physicalDisplayLost, destroyed: false)
        XCTAssertNotEqual(demoted.message, DisplaySafetyReason.physicalDisplayLost.message)
        XCTAssertEqual(DisplaySafetyEvent(reason: .sleep, destroyed: true).message, DisplaySafetyReason.sleep.message)
    }

    // MARK: Rate limiter

    let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testLimiterAllowsEightPerMinute() throws {
        var l = CreationRateLimiter()
        XCTAssertEqual(l.maxCreations, 8); XCTAssertEqual(l.window, 60); XCTAssertEqual(l.minGapAfterDestroy, 0.5)
        XCTAssertNil(l.delayBeforeCreate(now: t0))
        for i in 0..<l.maxCreations {
            XCTAssertNil(l.delayBeforeCreate(now: t0.addingTimeInterval(Double(i * 5))))
            l.recordCreate(now: t0.addingTimeInterval(Double(i * 5)))
        }
        // 9th within the window waits until the oldest ages out (t0 + 60)
        let wait = try XCTUnwrap(l.delayBeforeCreate(now: t0.addingTimeInterval(40)))
        XCTAssertEqual(wait, 20, accuracy: 1e-9)
        XCTAssertNil(l.delayBeforeCreate(now: t0.addingTimeInterval(60)))
        l.recordCreate(now: t0.addingTimeInterval(60))
        XCTAssertEqual(l.creations.count, 8)   // oldest entry pruned
    }

    func testLimiterMinimumGapAfterDestroy() throws {
        var l = CreationRateLimiter()
        l.recordDestroy(now: t0)
        XCTAssertEqual(try XCTUnwrap(l.delayBeforeCreate(now: t0.addingTimeInterval(0.2))), 0.3, accuracy: 1e-6)
        XCTAssertNil(l.delayBeforeCreate(now: t0.addingTimeInterval(0.5)))
        // destroys are never limited, and the larger of the two waits wins
        for i in 0..<l.maxCreations { l.recordCreate(now: t0.addingTimeInterval(Double(i))) }
        l.recordDestroy(now: t0.addingTimeInterval(8))
        XCTAssertEqual(try XCTUnwrap(l.delayBeforeCreate(now: t0.addingTimeInterval(8.5))), 51.5, accuracy: 1e-9)
    }

    func testRateLimitWaitThresholdSemantics() {
        // ensureDisplay sleeps for waits <= 5 s and throws .rateLimited beyond that: a hub flapping 9x a minute
        var l = CreationRateLimiter()
        for i in 0..<l.maxCreations { l.recordCreate(now: t0.addingTimeInterval(Double(i * 2))) }
        XCTAssertGreaterThan(l.delayBeforeCreate(now: t0.addingTimeInterval(16)) ?? 0, 5)
        XCTAssertLessThanOrEqual(l.delayBeforeCreate(now: t0.addingTimeInterval(56)) ?? 0, 5)
        let e = VirtualDisplayError.rateLimited(12.2)
        XCTAssertTrue(e.localizedDescription.contains("13"), e.localizedDescription)   // rounded up
    }

    // MARK: VirtualDisplayRequest

    func testSerialIsStableNonZeroFNV() {
        XCTAssertEqual(VirtualDisplayRequest.serial(for: ""), 2_166_136_261)
        XCTAssertEqual(VirtualDisplayRequest.serial(for: "a"), 0xE40C_292C)   // FNV-1a 32 test vector
        XCTAssertEqual(VirtualDisplayRequest.serial(for: "tab-1"), VirtualDisplayRequest.serial(for: "tab-1"))
        XCTAssertNotEqual(VirtualDisplayRequest.serial(for: "tab-1"), VirtualDisplayRequest.serial(for: "tab-2"))
    }

    func testSameDisplayIgnoresPlacementAndPrimary() {
        let a = VirtualDisplayRequest(name: "Tab", serial: 7, backingWidth: 2560, backingHeight: 1600, hiDPI: true,
                                      ppi: 274, refreshRate: 60, placement: .right, primary: false)
        var b = a; b.placement = .left; b.primary = true; b.name = "Other"; b.ppi = 100
        XCTAssertTrue(a.sameDisplay(as: b))
        for edit in [{ (r: inout VirtualDisplayRequest) in r.serial = 8 }, { $0.backingWidth = 1600 }, { $0.backingHeight = 2560 },
                     { $0.hiDPI = false }, { $0.refreshRate = 120 }] as [(inout VirtualDisplayRequest) -> Void] {
            var c = a; edit(&c)
            XCTAssertFalse(a.sameDisplay(as: c))
        }
    }
}


