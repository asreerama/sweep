import XCTest
import SweepCore   // deliberately NOT @testable: this file sees exactly what an app sees

/// Review finding #9, from the outside, updated for Codex Gate-1 findings #1 and #6.
/// `PublicSurfaceTests.swift` proves the deletion surface cannot be reached except through
/// `FixtureExecution`; this file proves the same thing about Gate 1's rule-authorization
/// pipeline: a caller can select *what* to clean, never *how*, and never *which rules apply*.
///
/// None of the following compiles from outside `SweepCore`, and that is the point:
///
/// ```swift
/// AuthorizedCleanPlan(...)                              // the type itself is not visible here
/// AuthorizedCleanPlan.authorize(ruleID:candidate:catalog:)
/// AuthorizedCleanPlan.authorize(codeSignClone:)
/// DeletionItem(authorized: somePlan)                    // ditto — DeletionItem's bridging init
///                                                        // takes an AuthorizedCleanPlan, which
///                                                        // cannot be named here either
/// CleanRequest(catalog: c, scan: s, selectedCandidateIDs: ids)
///                                                        // `catalog`/`scan` do not exist any
///                                                        // more (finding #1 / finding #6)
/// SelectionReceipt(candidateID: "x", url: ..., ...)      // every stored property, and the
///                                                        // memberwise init, are internal
/// DeletionMode.trashOnly(anchors: [])                    // not visible; TrashOnlyAnchor is not
///                                                        // visible either
/// ```
///
/// The only thing a caller can do with a selection is hand it to ``CleanService/execute(_:)``
/// inside a ``CleanRequest`` built from a real scan's receipts and a set of ids — nothing in that
/// shape can express a tier, an action, or a rule, so there is nothing to forge, and there is no
/// `catalog` parameter for a caller to substitute their own rules into.
final class PublicSurfaceCleanServiceTests: XCTestCase {

    /// `CleanRequest`'s public initializer takes exactly (receipts, codeSignClones,
    /// selectedCandidateIDs) — the pinned shape after findings #1 and #6, plus the code-sign-
    /// clone parallel path, and nothing else. This compiles at all only because none of those
    /// parameters can carry a tier, an action, or a rule catalog. `receipts` itself comes from a
    /// real, public `ScanEngine` run's `ScanResult.receipts` — `ScanResult` has no public
    /// initializer of its own and `SelectionReceipt` has no public initializer either, so even
    /// *this* file cannot conjure one out of nothing; a real scan is the only way to get one.
    func testCleanRequestCanOnlyBeBuiltFromARealScansReceiptsAndASelection() async throws {
        let scan = try await Self.emptyScan()
        let request = CleanRequest(receipts: scan.receipts, selectedCandidateIDs: ["some-id"])

        XCTAssertEqual(request.selectedCandidateIDs, ["some-id"])
        XCTAssertEqual(request.receipts.count, scan.candidates.count)
    }

    /// Gate 1 is closed in this build (`CleanService.isEnabled == false`), and `execute` is the
    /// *only* public entry point capable of ever mutating anything. Even with a well-formed
    /// public request, it refuses before looking at a single candidate — and, since finding #1,
    /// before the catalog is even loaded.
    func testExecuteRefusesEvenAWellFormedRequestWhileTheGateIsClosed() async throws {
        XCTAssertFalse(CleanService.isEnabled)
        let scan = try await Self.emptyScan()
        let request = CleanRequest(receipts: scan.receipts, selectedCandidateIDs: [])

        do {
            for try await _ in CleanService.execute(request) {
                XCTFail("no event should be produced while the gate is closed")
            }
            XCTFail("expected gateClosed")
        } catch let error as CleanServiceError {
            guard error == .gateClosed else { return XCTFail("expected gateClosed, got \(error)") }
        }
    }

    /// A minimal, real `ScanResult` obtained the only public way: running `ScanEngine` against a
    /// disposable directory.
    private static func emptyScan() async throws -> ScanResult {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "PublicSurfaceCleanServiceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await ScanEngine().run(ScanRequest(roots: [directory]))
    }
}
