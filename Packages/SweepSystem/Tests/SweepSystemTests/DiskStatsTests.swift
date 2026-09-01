import XCTest
@testable import SweepSystem

final class DiskStatsTests: XCTestCase {
    // MARK: - Pure math (deterministic, fixed inputs)

    func testPurgeableEstimateWhenImportantUsageIsHigher() {
        XCTAssertEqual(DiskStatsReader.purgeableEstimate(availableBytes: 100, availableForImportantUsageBytes: 150), 50)
    }

    func testPurgeableEstimateClampsAtZeroWhenLower() {
        XCTAssertEqual(DiskStatsReader.purgeableEstimate(availableBytes: 150, availableForImportantUsageBytes: 100), 0)
    }

    func testPurgeableEstimateZeroWhenEqual() {
        XCTAssertEqual(DiskStatsReader.purgeableEstimate(availableBytes: 100, availableForImportantUsageBytes: 100), 0)
    }

    // MARK: - Live reads on this machine

    func testReadAllReturnsAtLeastTheBootVolume() {
        let disks = DiskStatsReader.readAll()
        XCTAssertFalse(disks.isEmpty, "every Mac has at least a boot volume")

        for disk in disks {
            XCTAssertGreaterThan(disk.totalBytes, 0)
            XCTAssertLessThanOrEqual(disk.availableBytes, disk.totalBytes)
            XCTAssertFalse(disk.volumeName.isEmpty)
        }
    }

    func testReadRootVolumeDirectly() throws {
        let disk = try XCTUnwrap(DiskStatsReader.read(volumeURL: URL(fileURLWithPath: "/")))
        XCTAssertGreaterThan(disk.totalBytes, 0)
    }

    func testRawStatfsMatchesResourceKeyOrderOfMagnitude() throws {
        let statfsInfo = try XCTUnwrap(DiskStatsReader.readRawStatfs(path: "/"))
        let blockBytes = UInt64(statfsInfo.f_bsize) * UInt64(statfsInfo.f_blocks)

        let disk = try XCTUnwrap(DiskStatsReader.read(volumeURL: URL(fileURLWithPath: "/")))

        // Both describe the same volume's total capacity through different APIs; they should
        // agree closely, not necessarily to the byte (block accounting can differ slightly).
        let ratio = Double(disk.totalBytes) / Double(blockBytes)
        XCTAssertEqual(ratio, 1.0, accuracy: 0.05)
    }
}
