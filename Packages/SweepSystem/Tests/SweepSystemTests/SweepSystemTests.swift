import Foundation
import XCTest
@testable import SweepSystem

/// Smoke test that the module builds and its public types are reachable. Per-module behavior is
/// covered by MemoryStatsTests, CPUStatsTests, DiskStatsTests, NetworkStatsTests,
/// ProcessStatsTests, BatteryStatsTests, and StatsSamplerTests.
final class SweepSystemTests: XCTestCase {
    func testSystemSnapshotIsConstructible() {
        let snapshot = SystemSnapshot(
            timestamp: Date(),
            memory: .unavailable,
            memoryPressure: .normal,
            cpu: .unavailable,
            disks: [],
            network: .unavailable,
            topProcesses: [],
            battery: nil
        )
        XCTAssertEqual(snapshot.memoryPressure, .normal)
    }
}
