import XCTest
import SweepCore   // deliberately NOT @testable: this file sees exactly what an app sees

/// Review finding #9, from the outside. `PublicSurfaceTests.swift` proves the deletion surface
/// cannot be reached except through `FixtureExecution`; this file proves the same thing about
/// Gate 1's rule-authorization pipeline: a caller can select *what* to clean, never *how*.
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
/// CleanRequest(catalog: c, scan: s, selectedCandidateIDs: ids, tier: .safe, action: .trash)
///                                                        // no such parameters exist
/// DeletionMode.trashOnly(anchors: [])                    // not visible; TrashOnlyAnchor is not
///                                                        // visible either
/// ```
///
/// The only thing a caller can do with a selection is hand it to ``CleanService/execute(_:)``
/// inside a ``CleanRequest`` built from a catalog, a scan result, and a set of ids — nothing in
/// that shape can express a tier or an action, so there is nothing to forge.
final class PublicSurfaceCleanServiceTests: XCTestCase {

    /// `CleanRequest`'s public initializer takes exactly (catalog, scan, codeSignClones,
    /// selectedCandidateIDs) — the pinned triple, plus the code-sign-clone parallel path, and
    /// nothing else. This compiles at all only because none of those parameters can carry a tier
    /// or an action. `scan` itself comes from a real, public `ScanEngine` run — `ScanResult` and
    /// `ScanSummary` have no public initializer of their own, so even *this* file cannot conjure
    /// one out of nothing; a real scan is the only way to get one.
    func testCleanRequestCanOnlyBeBuiltFromCatalogARealScanAndASelection() async throws {
        let scan = try await Self.emptyScan()
        let catalog = RuleCatalog(rules: [])
        let request = CleanRequest(catalog: catalog, scan: scan, selectedCandidateIDs: ["some-id"])

        XCTAssertEqual(request.selectedCandidateIDs, ["some-id"])
        XCTAssertEqual(request.catalog.rules.count, 0)
    }

    /// Gate 1 is closed in this build (`CleanService.isEnabled == false`), and `execute` is the
    /// *only* public entry point capable of ever mutating anything. Even with a well-formed
    /// public request, it refuses before looking at a single candidate.
    func testExecuteRefusesEvenAWellFormedRequestWhileTheGateIsClosed() async throws {
        XCTAssertFalse(CleanService.isEnabled)
        let scan = try await Self.emptyScan()
        let catalog = RuleCatalog(rules: [])
        let request = CleanRequest(catalog: catalog, scan: scan, selectedCandidateIDs: [])

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
