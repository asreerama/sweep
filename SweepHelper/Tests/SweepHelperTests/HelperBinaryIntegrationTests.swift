import XCTest
import SweepPolicy
@testable import SweepHelper

/// The real, non-dry-run path: actually flushing DNS as root. Every other command
/// (`mdutil -E`, `tmutil thinlocalsnapshots`) needs root too and has real side effects on the
/// machine's Spotlight index / local snapshots, so this suite intentionally exercises only the
/// one operation that is both fully privileged-in-spirit and safe to actually run.
///
/// Per this task's explicit instruction, the real daemon is never registered or approved on this
/// machine — `XCTSkipUnless` makes that a visible, honest skip rather than a silently-passing
/// assertion, and this test starts running for real the moment a future session does the live
/// approval (P6/live-approval step) and runs the suite as root.
final class HelperBinaryIntegrationTests: XCTestCase {
    func testFlushDNSActuallyRunsWhenRoot() throws {
        try XCTSkipUnless(getuid() == 0, "requires root; run only on a machine where the real daemon has been approved")

        let outcome = MaintenanceExecutor.execute(.flushDNS, dryRun: false)
        guard case .succeeded = outcome else { return XCTFail("expected success, got \(outcome)") }
    }
}
