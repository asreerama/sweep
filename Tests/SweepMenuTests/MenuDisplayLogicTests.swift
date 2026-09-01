import Foundation
import SweepSystem
import SweepUI
import XCTest
@testable import SweepMenu

/// Pure logic behind `MenuPopoverView`: pressure tint/label mapping, and — task item 4's "byte
/// formatting reuse asserts" — that every readout this view shows is produced by calling
/// `SweepUI.SweepFormat`/`ByteCountFormatter(.memory)`, the exact same two call sites
/// `Sources/SweepApp/Shell/MenuBarStats.swift` uses, rather than a reimplementation living only
/// in `SweepMenu`.
final class MenuDisplayLogicTests: XCTestCase {

    // MARK: - Pressure

    func testPressureTintMatchesEstablishedSemanticColors() {
        XCTAssertEqual(MenuDisplayLogic.pressureTint(.normal), SweepTokens.accent)
        XCTAssertEqual(MenuDisplayLogic.pressureTint(.warning), SweepTokens.tierCaution)
        XCTAssertEqual(MenuDisplayLogic.pressureTint(.critical), SweepTokens.tierExpert)
    }

    func testPressureLabels() {
        XCTAssertEqual(MenuDisplayLogic.pressureLabel(.normal), "NORMAL")
        XCTAssertEqual(MenuDisplayLogic.pressureLabel(.warning), "WARNING")
        XCTAssertEqual(MenuDisplayLogic.pressureLabel(.critical), "CRITICAL")
    }

    // MARK: - Byte formatting reuse (never reimplemented in SweepMenu)

    func testDiskTextReusesSweepFormatBytesExactly() {
        let disk = disk(total: 1_000_000_000, available: 400_000_000)
        let expectedUsed = SweepFormat.bytes(600_000_000)
        let expectedTotal = SweepFormat.bytes(1_000_000_000)
        XCTAssertEqual(MenuDisplayLogic.diskText(disk: disk), "\(expectedUsed) / \(expectedTotal)")
    }

    func testMemoryTextReusesBinaryByteCountFormatterExactly() {
        let memory = memoryStats(total: 1_073_741_824, free: 0)
        let expected = ByteCountFormatter.string(fromByteCount: 1_073_741_824, countStyle: .memory)
        XCTAssertEqual(MenuDisplayLogic.memoryText(memory: memory), "\(expected) / \(expected)")
    }

    func testFormattedMemoryDelegatesToByteCountFormatterMemoryStyle() {
        for bytes: UInt64 in [0, 1_000_000, 1_073_741_824, 50_000_000_000] {
            XCTAssertEqual(
                MenuDisplayLogic.formattedMemory(bytes),
                ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
            )
        }
    }

    // MARK: - Fractions

    func testMemoryFractionOfTotal() {
        XCTAssertEqual(MenuDisplayLogic.memoryFraction(memory: memoryStats(total: 100, free: 40)), 0.6, accuracy: 0.0001)
    }

    func testMemoryFractionIsZeroWhenTotalIsZero() {
        XCTAssertEqual(MenuDisplayLogic.memoryFraction(memory: memoryStats(total: 0, free: 0)), 0)
    }

    func testDiskFractionOfTotal() {
        XCTAssertEqual(MenuDisplayLogic.diskFraction(disk: disk(total: 100, available: 10)), 0.9, accuracy: 0.0001)
    }

    func testDiskFractionIsZeroWhenTotalIsZero() {
        XCTAssertEqual(MenuDisplayLogic.diskFraction(disk: disk(total: 0, available: 0)), 0)
    }

    // MARK: - Fixtures

    private func memoryStats(total: UInt64, free: UInt64) -> MemoryStats {
        MemoryStats(
            totalBytes: total, freeBytes: free, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
            compressedBytes: 0, appMemoryBytes: 0, swapInsBytes: 0, swapOutsBytes: 0
        )
    }

    private func disk(total: UInt64, available: UInt64) -> DiskStats {
        DiskStats(
            volumeURL: URL(fileURLWithPath: "/"),
            volumeName: "Test Volume",
            totalBytes: total,
            availableBytes: available,
            availableForImportantUsageBytes: available,
            purgeableEstimateBytes: 0,
            isRemovable: false,
            isInternal: true
        )
    }
}
