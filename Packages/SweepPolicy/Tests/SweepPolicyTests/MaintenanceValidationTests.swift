import XCTest
@testable import SweepPolicy

final class MaintenanceValidationTests: XCTestCase {

    // MARK: - Volume allowlist

    func testMountedVolumeIsAccepted() {
        XCTAssertNil(MaintenanceValidation.validateVolume("/", mountedVolumes: ["/", "/Volumes/Data"]))
    }

    func testUnmountedVolumeIsRefused() {
        XCTAssertEqual(
            MaintenanceValidation.validateVolume("/Volumes/Evil", mountedVolumes: ["/", "/Volumes/Data"]),
            .volumeNotMounted("/Volumes/Evil")
        )
    }

    func testEmptyMountedListRefusesEverything() {
        XCTAssertEqual(MaintenanceValidation.validateVolume("/", mountedVolumes: []), .volumeNotMounted("/"))
    }

    // MARK: - Urgency bounds

    func testEveryDocumentedUrgencyLevelIsAccepted() {
        for value in MaintenanceValidation.urgencyRange {
            XCTAssertNil(MaintenanceValidation.validateUrgency(value), "urgency \(value) should be in range")
        }
    }

    func testUrgencyBelowRangeIsRefused() {
        XCTAssertEqual(MaintenanceValidation.validateUrgency(0), .urgencyOutOfRange(0))
        XCTAssertEqual(MaintenanceValidation.validateUrgency(-1), .urgencyOutOfRange(-1))
    }

    func testUrgencyAboveRangeIsRefused() {
        XCTAssertEqual(MaintenanceValidation.validateUrgency(5), .urgencyOutOfRange(5))
        XCTAssertEqual(MaintenanceValidation.validateUrgency(999), .urgencyOutOfRange(999))
    }

    // MARK: - Dispatch per operation

    func testFlushDNSNeverFailsValidation() {
        XCTAssertNil(MaintenanceValidation.validate(.flushDNS, mountedVolumes: []))
    }

    func testReindexSpotlightDispatchesToVolumeValidation() {
        XCTAssertNil(MaintenanceValidation.validate(.reindexSpotlight(volume: "/"), mountedVolumes: ["/"]))
        XCTAssertEqual(
            MaintenanceValidation.validate(.reindexSpotlight(volume: "/nope"), mountedVolumes: ["/"]),
            .volumeNotMounted("/nope")
        )
    }

    func testThinSnapshotsDispatchesToUrgencyValidation() {
        XCTAssertNil(MaintenanceValidation.validate(.thinSnapshots(urgency: 4), mountedVolumes: []))
        XCTAssertEqual(
            MaintenanceValidation.validate(.thinSnapshots(urgency: 10), mountedVolumes: []),
            .urgencyOutOfRange(10)
        )
    }
}
