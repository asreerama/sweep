import XCTest
import SweepPolicy
@testable import SweepHelper

/// Every case here runs `dryRun: true` — no process is ever spawned, no root is ever needed
/// (task spec: "dry-run mode ... tested as user"). `HelperBinaryIntegrationTests` is the
/// counterpart that actually executes commands, and is `XCTSkip`-guarded to root.
final class MaintenanceExecutorTests: XCTestCase {
    func testDryRunFlushDNSReportsBothCommandsWithoutRunningThem() {
        let outcome = MaintenanceExecutor.execute(.flushDNS, mountedVolumes: [], dryRun: true)
        guard case .succeeded(let detail) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertTrue(detail.contains("/usr/bin/dscacheutil -flushcache"))
        XCTAssertTrue(detail.contains("/usr/bin/killall -HUP mDNSResponder"))
    }

    func testDryRunReindexSpotlightRefusesAnUnmountedVolumeBeforeBuildingACommand() {
        let outcome = MaintenanceExecutor.execute(.reindexSpotlight(volume: "/Volumes/Nope"), mountedVolumes: ["/"], dryRun: true)
        guard case .failed(let reason) = outcome else { return XCTFail("expected refusal, got \(outcome)") }
        XCTAssertTrue(reason.contains("not a currently mounted volume"))
    }

    func testDryRunReindexSpotlightAcceptsAMountedVolume() {
        let outcome = MaintenanceExecutor.execute(.reindexSpotlight(volume: "/"), mountedVolumes: ["/"], dryRun: true)
        guard case .succeeded(let detail) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertTrue(detail.contains("/usr/bin/mdutil -E /"))
    }

    func testDryRunThinSnapshotsRejectsOutOfRangeUrgency() {
        let outcome = MaintenanceExecutor.execute(.thinSnapshots(urgency: 9), mountedVolumes: [], dryRun: true)
        guard case .failed(let reason) = outcome else { return XCTFail("expected refusal, got \(outcome)") }
        XCTAssertTrue(reason.contains("outside 1...4"))
    }

    func testDryRunThinSnapshotsAcceptsInRangeUrgency() {
        let outcome = MaintenanceExecutor.execute(.thinSnapshots(urgency: 3), mountedVolumes: [], dryRun: true)
        guard case .succeeded(let detail) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertTrue(detail.contains("/usr/bin/tmutil thinlocalsnapshots / 500000000000 3"))
    }

    func testValidationRunsEvenInDryRunMode() {
        // Dry run only skips the process spawn — it must never skip validation.
        let outcome = MaintenanceExecutor.execute(.thinSnapshots(urgency: -5), mountedVolumes: [], dryRun: true)
        guard case .failed = outcome else { return XCTFail("dry run must not bypass validation") }
    }

    func testIsDryRunRequestedReadsTheEnvironmentVariableExactly() {
        XCTAssertTrue(MaintenanceExecutor.isDryRunRequested(environment: ["SWEEP_HELPER_DRYRUN": "1"]))
        XCTAssertFalse(MaintenanceExecutor.isDryRunRequested(environment: [:]))
        XCTAssertFalse(MaintenanceExecutor.isDryRunRequested(environment: ["SWEEP_HELPER_DRYRUN": "0"]))
        XCTAssertFalse(MaintenanceExecutor.isDryRunRequested(environment: ["SWEEP_HELPER_DRYRUN": "true"]))
    }
}
