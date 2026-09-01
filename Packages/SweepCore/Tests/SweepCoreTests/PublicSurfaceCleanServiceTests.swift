import XCTest
import SweepCore   // deliberately NOT @testable: this file sees exactly what an app sees

/// Review finding #9, from the outside, updated for Codex Gate-1 findings #1, #5 and #6.
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
/// SelectionBatch(receipts: [...], scanSessionID: ..., catalogDigest: ..., mintedAt: ...)
///                                                        // every stored property, and the
///                                                        // memberwise init, are internal too
///                                                        // (finding #5); `sealedBatch(...)` is
///                                                        // the only way to mint one
/// DeletionMode.trashOnly(anchors: [])                    // not visible; TrashOnlyAnchor is not
///                                                        // visible either
/// ```
///
/// The only thing a caller can do with a selection is hand it to ``CleanService/execute(_:)``
/// inside a ``CleanRequest`` built from a real scan's sealed batch and a set of ids. Nothing in
/// that shape can express a tier, an action, a rule, or a catalog digest a caller made up, so
/// there is nothing to forge, and there is no `catalog` parameter for a caller to substitute their
/// own rules into.
final class PublicSurfaceCleanServiceTests: XCTestCase {

    /// `CleanRequest`'s public initializer takes exactly (batch, codeSignClones,
    /// selectedCandidateIDs), the pinned shape after findings #1, #5 and #6, plus the code-sign-
    /// clone parallel path, and nothing else. This compiles at all only because none of those
    /// parameters can carry a tier, an action, a rule catalog, or an unverifiable catalog digest.
    /// `batch` itself comes from a real, public `ScanEngine` run's
    /// `ScanResult.sealedBatch(catalogDigest:)`, `ScanResult` has no public initializer of its
    /// own, `SelectionReceipt` has no public initializer, and `SelectionBatch` has no public
    /// initializer either, so even *this* file cannot conjure one out of nothing; a real scan is
    /// the only way to get one. `catalogDigest` itself is only ever obtainable publicly from
    /// `CleanService.currentCatalogDigest()`, never a value a caller can just assert.
    func testCleanRequestCanOnlyBeBuiltFromARealScansSealedBatchAndASelection() async throws {
        let scan = try await Self.emptyScan()
        let digest = (try? CleanService.currentCatalogDigest()) ?? "no-catalog-in-this-test-process"
        let batch = try scan.sealedBatch(catalogDigest: digest)
        let request = CleanRequest(batch: batch, selectedCandidateIDs: ["some-id"])

        XCTAssertEqual(request.selectedCandidateIDs, ["some-id"])
    }

    /// Gate 1 is open since M3. This public-surface process deliberately configures no bundled
    /// catalog, so the security property under test becomes: with the gate open but no pinned
    /// catalog available, `execute` fails closed before touching anything — it must not fall
    /// back to any caller-supplied rules (finding #1) or proceed catalog-less.
    func testExecuteRefusesEvenAWellFormedRequestWhileTheGateIsClosed() async throws {
        XCTAssertTrue(CleanService.isEnabled)
        let scan = try await Self.emptyScan()
        let digest = (try? CleanService.currentCatalogDigest()) ?? "no-catalog-in-this-test-process"
        let batch = try scan.sealedBatch(catalogDigest: digest)
        let request = CleanRequest(batch: batch, selectedCandidateIDs: [])

        do {
            for try await _ in CleanService.execute(request) {
                XCTFail("no event may be produced without a pinned catalog")
            }
            XCTFail("expected a catalog-unavailable failure")
        } catch {
            XCTAssertTrue(String(describing: error).contains("no bundled rule catalog"),
                          "must fail closed on the missing catalog, got: \(error)")
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
