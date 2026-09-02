import XCTest
@testable import SweepApp
@testable import SweepCore
import SweepUI

/// Codex Gate-U adjudication finding #1: the interrupted-leftover-phase path files its "items
/// may already be in the Trash" warning only in the finished report's outcome list, and a
/// displayed report built solely from streamed `itemCompleted` events silently dropped it.
/// `UninstallModel.makeRemovalReport` must treat the finished report as authoritative.
@MainActor
final class UninstallRemovalReportTests: XCTestCase {

    private static let interruptionDetail =
        "the leftover phase was interrupted; some selected leftovers may already be in the Trash"

    private static func coreOutcome(
        id: String, outcome: ItemOutcome, failureReason: ItemFailureReason? = nil,
        allocatedSize: Int64 = 0, detail: String? = nil
    ) -> SweepCore.CleanItemOutcome {
        SweepCore.CleanItemOutcome(
            id: id, url: URL(fileURLWithPath: id), ruleID: nil, detectorSource: "test",
            tier: nil, requestedAction: .trash, outcome: outcome, failureReason: failureReason,
            trashURL: nil, allocatedSize: allocatedSize, detail: detail
        )
    }

    private static func coreReport(
        outcomes: [SweepCore.CleanItemOutcome], freedBytesEstimate: Int64 = 0
    ) -> SweepCore.CleanReport {
        SweepCore.CleanReport(
            operationID: UUID(), outcomes: outcomes, committed: false,
            catalogDigest: "test", journalingDegraded: true, freedBytesEstimate: freedBytesEstimate
        )
    }

    func testOutcomePresentOnlyInFinishedReportReachesTheDisplayedReport() {
        let trashed = Self.coreOutcome(id: "/tmp/a", outcome: .succeeded, allocatedSize: 128)
        let warning = Self.coreOutcome(
            id: "/Applications/Victim.app", outcome: .failed,
            failureReason: .journalUnavailable, detail: Self.interruptionDetail
        )
        // The stream delivered only the trashed item; the warning exists only in the report.
        let streamedOnly = [SweepUI.CleanItemOutcome(
            id: trashed.id, title: "a", byteCount: 128, status: .succeeded
        )]

        let report = UninstallModel.makeRemovalReport(
            finished: Self.coreReport(outcomes: [trashed, warning], freedBytesEstimate: 42),
            streamed: streamedOnly
        )

        XCTAssertEqual(report.outcomes.count, 2)
        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertEqual(report.freedBytes, 42)
        let displayedWarning = report.outcomes.first { $0.id == warning.id }
        XCTAssertEqual(displayedWarning?.failureReason, Self.interruptionDetail)
    }

    func testStreamedOutcomesAreTheFallbackWhenNoFinishedReportExists() {
        let streamed = [
            SweepUI.CleanItemOutcome(id: "/tmp/a", title: "a", byteCount: 1, status: .succeeded),
            SweepUI.CleanItemOutcome(id: "/tmp/b", title: "b", byteCount: 0, status: .failed(reason: "x")),
        ]
        let report = UninstallModel.makeRemovalReport(finished: nil, streamed: streamed)
        XCTAssertEqual(report.outcomes, streamed)
        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertEqual(report.freedBytes, 0)
    }
}
