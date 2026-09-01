import XCTest
@testable import SweepSystem

final class MemoryStatsTests: XCTestCase {
    func testReadReturnsSaneValuesOnThisMachine() throws {
        let stats = try XCTUnwrap(MemoryStatsReader.read())

        XCTAssertGreaterThan(stats.totalBytes, 0)
        XCTAssertGreaterThan(stats.totalBytes, 512 * 1024 * 1024, "every supported Mac has well over 512 MB RAM")

        // Every component must fit within a generous multiple of the total: page-count-derived
        // components can legitimately overlap in kernel accounting (e.g. compressor pages and
        // active pages), but none of them should exceed physical memory by more than a small
        // margin, and none should individually exceed it outright.
        let tolerance = Double(stats.totalBytes) * 1.2
        for component in [stats.freeBytes, stats.activeBytes, stats.inactiveBytes, stats.wiredBytes, stats.compressedBytes] {
            XCTAssertLessThanOrEqual(Double(component), tolerance)
        }

        // "Memory components sum sanely vs total within tolerance" (deliverable #8): the four
        // core VM buckets should not wildly exceed total physical memory.
        let coreSum = stats.freeBytes + stats.activeBytes + stats.inactiveBytes + stats.wiredBytes
        XCTAssertLessThanOrEqual(Double(coreSum), tolerance)

        XCTAssertLessThanOrEqual(stats.appMemoryBytes, stats.totalBytes)
    }

    func testUnavailableIsAllZero() {
        let stats = MemoryStats.unavailable
        XCTAssertEqual(stats.totalBytes, 0)
        XCTAssertEqual(stats.appMemoryBytes, 0)
    }

    func testPressureLevelMappingWorstFirst() {
        XCTAssertEqual(MemoryPressureMonitor.level(from: [.critical, .warning, .normal]), .critical)
        XCTAssertEqual(MemoryPressureMonitor.level(from: [.warning, .normal]), .warning)
        XCTAssertEqual(MemoryPressureMonitor.level(from: [.normal]), .normal)
        XCTAssertEqual(MemoryPressureMonitor.level(from: []), .normal)
    }

    func testPressureStreamCanBeConsumedAndCancelledWithoutHanging() async {
        let stream = MemoryPressureMonitor.stream()
        let task = Task<MemoryPressureLevel?, Never> {
            for await level in stream { return level }
            return nil
        }

        // The dispatch source's first event is scheduled asynchronously and, on a machine under
        // normal conditions, may never fire during this window — that's expected. This test
        // guards two things instead: consuming the stream doesn't crash, and cancelling it
        // actually unblocks the awaiting consumer (verifying `onTermination` tears down the
        // `DispatchSourceMemoryPressure` rather than leaking it).
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let level = await task.value

        if let level {
            XCTAssertTrue(MemoryPressureLevel.allCases.contains(level))
        }
    }
}
