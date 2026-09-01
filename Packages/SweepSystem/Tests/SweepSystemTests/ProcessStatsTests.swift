import XCTest
@testable import SweepSystem

final class ProcessStatsTests: XCTestCase {
    // MARK: - Pure sort/truncate (deterministic fixture data, no Darwin calls)

    func testTopByFootprintSortsDescending() {
        let fixture = [
            ProcessMemoryInfo(pid: 1, name: "small", physicalFootprintBytes: 100),
            ProcessMemoryInfo(pid: 2, name: "large", physicalFootprintBytes: 900),
            ProcessMemoryInfo(pid: 3, name: "medium", physicalFootprintBytes: 500),
        ]
        let top = ProcessStatsReader.topByFootprint(fixture, limit: 10)
        XCTAssertEqual(top.map(\.name), ["large", "medium", "small"])
    }

    func testTopByFootprintRespectsLimit() {
        let fixture = (0..<20).map { ProcessMemoryInfo(pid: pid_t($0), name: "p\($0)", physicalFootprintBytes: UInt64($0)) }
        let top = ProcessStatsReader.topByFootprint(fixture, limit: 5)
        XCTAssertEqual(top.count, 5)
        XCTAssertEqual(top.map(\.name), ["p19", "p18", "p17", "p16", "p15"])
    }

    func testTopByFootprintZeroLimitIsEmpty() {
        let fixture = [ProcessMemoryInfo(pid: 1, name: "a", physicalFootprintBytes: 1)]
        XCTAssertTrue(ProcessStatsReader.topByFootprint(fixture, limit: 0).isEmpty)
    }

    func testTopByFootprintLimitLargerThanInputReturnsAll() {
        let fixture = [ProcessMemoryInfo(pid: 1, name: "a", physicalFootprintBytes: 1)]
        XCTAssertEqual(ProcessStatsReader.topByFootprint(fixture, limit: 50).count, 1)
    }

    // MARK: - Live reads on this machine

    func testTopProcessesNonEmptyAndSortedOnThisMachine() {
        let top = ProcessStatsReader.topProcesses(limit: 10)

        XCTAssertFalse(top.isEmpty, "a running macOS system always has processes with a resolvable footprint")
        XCTAssertLessThanOrEqual(top.count, 10)

        for pair in zip(top, top.dropFirst()) {
            XCTAssertGreaterThanOrEqual(pair.0.physicalFootprintBytes, pair.1.physicalFootprintBytes)
        }
        for process in top {
            XCTAssertFalse(process.name.isEmpty)
            XCTAssertGreaterThan(process.physicalFootprintBytes, 0)
        }
    }
}
