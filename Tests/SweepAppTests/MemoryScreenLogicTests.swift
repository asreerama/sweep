import SweepSystem
import SweepUI
import SwiftUI
import XCTest
@testable import SweepApp

/// Pure logic behind `MemoryScreen` (module 3, PLAN §3): pressure tint/label, breakdown
/// fractions, memory formatting, and the quit-eligibility/force-quit decision. None of this
/// touches `NSRunningApplication` or `StatsSampler` directly.
///
/// NOTE for wiring: see `LargeOldFilesLogicTests.swift` — same target, not yet registered.
final class MemoryScreenLogicTests: XCTestCase {

    // MARK: - Pressure

    func testPressureTintMatchesEstablishedSemanticColors() {
        XCTAssertEqual(MemoryScreenLogic.pressureTint(.normal), SweepTokens.accent)
        XCTAssertEqual(MemoryScreenLogic.pressureTint(.warning), SweepTokens.tierCaution)
        XCTAssertEqual(MemoryScreenLogic.pressureTint(.critical), SweepTokens.tierExpert)
    }

    func testPressureLabelsAreHumanReadable() {
        XCTAssertEqual(MemoryScreenLogic.pressureLabel(.normal), "Normal")
        XCTAssertEqual(MemoryScreenLogic.pressureLabel(.warning), "Warning")
        XCTAssertEqual(MemoryScreenLogic.pressureLabel(.critical), "Critical")
    }

    // MARK: - Breakdown fractions

    private func stats(total: UInt64, free: UInt64 = 0, app: UInt64 = 0, wired: UInt64 = 0, compressed: UInt64 = 0) -> MemoryStats {
        MemoryStats(
            totalBytes: total, freeBytes: free, activeBytes: 0, inactiveBytes: 0,
            wiredBytes: wired, compressedBytes: compressed, appMemoryBytes: app,
            swapInsBytes: 0, swapOutsBytes: 0
        )
    }

    func testBreakdownFractionsOfTotal() {
        let result = MemoryScreenLogic.breakdown(stats(total: 100, free: 10, app: 50, wired: 20, compressed: 20))
        XCTAssertEqual(result.app, 0.5, accuracy: 0.0001)
        XCTAssertEqual(result.wired, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result.compressed, 0.2, accuracy: 0.0001)
        XCTAssertEqual(result.free, 0.1, accuracy: 0.0001)
    }

    func testBreakdownClampsAboveOne() {
        // appMemoryBytes larger than totalBytes should never happen, but the readout must not
        // render past a full bar if it does.
        let result = MemoryScreenLogic.breakdown(stats(total: 100, app: 500))
        XCTAssertEqual(result.app, 1.0)
    }

    func testBreakdownIsAllZeroWhenTotalIsZero() {
        let result = MemoryScreenLogic.breakdown(stats(total: 0))
        XCTAssertEqual(result.app, 0)
        XCTAssertEqual(result.free, 0)
    }

    // MARK: - Memory formatting (binary units, per Formatting.swift's documented exception)

    func testFormatMemoryUsesBinaryNotDecimalUnits() {
        // 1 GiB (1,073,741,824 B) should read as "1 GB" under .memory countStyle, distinguishing
        // this call site from `SweepFormat.bytes`, which is decimal and would read "1.07 GB".
        let text = MemoryScreenLogic.formatMemory(1_073_741_824)
        XCTAssertTrue(text.contains("1"), "expected the binary-GB reading to still show as roughly 1, got \(text)")
    }

    func testFormatMemoryIsMonotonicWithMagnitude() {
        let small = MemoryScreenLogic.formatMemory(1_000_000)
        let large = MemoryScreenLogic.formatMemory(50_000_000_000)
        XCTAssertNotEqual(small, large)
    }

    // MARK: - Quit eligibility

    func testQuittablePIDsIsTheIntersection() {
        let result = MemoryScreenLogic.quittablePIDs(processFootprints: [1, 2, 3], regularAppPIDs: [2, 3, 4])
        XCTAssertEqual(Set(result), [2, 3])
    }

    func testQuittablePIDsExcludesProcessesWithNoRunningApp() {
        // A pid present in the footprint list but never resolved to a `.regular` running app
        // (a daemon, a helper, another user's process) must never be offered a Quit button.
        let result = MemoryScreenLogic.quittablePIDs(processFootprints: [42], regularAppPIDs: [])
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Terminate → force-quit gate

    func testSuccessfulTerminateNeedsNoConfirmation() {
        XCTAssertEqual(MemoryScreenLogic.afterTerminateAttempt(succeeded: true), .quit)
    }

    func testFailedTerminateOffersForceQuit() {
        XCTAssertEqual(MemoryScreenLogic.afterTerminateAttempt(succeeded: false), .offerForceQuit)
    }
}
