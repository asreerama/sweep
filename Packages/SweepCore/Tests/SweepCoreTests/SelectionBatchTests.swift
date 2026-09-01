import XCTest
@testable import SweepCore
import SweepPolicy

/// Codex G1 finding #5: a bare `[SelectionReceipt]` carried no proof of which scan session it
/// came from, no catalog digest, and no freshness bound. `SelectionBatch` closes all three:
/// mixed-session batches are refused at mint time, and `CleanService` refuses a stale or
/// cross-catalog batch before a single receipt is authorized against anything.
final class SelectionBatchTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CleanService.resetBundledCatalogDirectoryForTesting()
    }

    override func tearDown() {
        CleanService.resetBundledCatalogDirectoryForTesting()
        super.tearDown()
    }

    // MARK: - Mixed scan sessions refused at mint time

    func testMintingABatchFromTwoDifferentScanSessionsIsRefused() throws {
        let home = try FixtureHome("batch-mixed-sessions")
        try home.write("Library/Logs/AppOne/junk.log")
        try home.write("Library/Logs/AppTwo/junk.log")

        let receiptOne = try home.receipt(at: "Library/Logs/AppOne", ruleID: "rule.one")
        let receiptTwo = try home.receipt(at: "Library/Logs/AppTwo", ruleID: "rule.two")
        // `FixtureHome.receipt` mints a fresh `scanSessionID` (a fresh `UUID()`) per call, so these
        // two receipts already belong to two different sessions: exactly the shape a caller could
        // otherwise scavenge together from two unrelated scans.

        XCTAssertThrowsError(
            try SelectionBatch(
                receipts: [receiptOne, receiptTwo], scanSessionID: receiptOne.scanSessionID,
                catalogDigest: "irrelevant", mintedAt: Date()
            )
        ) { error in
            guard case SelectionBatch.MintError.mixedScanSessions = error else {
                return XCTFail("expected mixedScanSessions, got \(error)")
            }
        }
    }

    /// `ScanResult.sealedBatch` can never produce a mixed-session batch in the first place: every
    /// receipt it seals shares the one scan's own `scanID` by construction, so this is the
    /// positive-path proof that a real scan's own receipts always mint cleanly.
    func testSealedBatchFromARealScanAlwaysSharesOneSession() async throws {
        let home = try FixtureHome("batch-one-session")
        try home.write("Library/Logs/App/junk.log")
        let resolvedRoot = try XCTUnwrap(SweepPolicy.resolvedRoots(for: .userLogs, home: home.root).first)
        let scanResult = try await ScanEngine().run(ScanRequest(roots: [resolvedRoot.url], ruleID: "rule.id"))

        let batch = try scanResult.sealedBatch(catalogDigest: "digest")
        XCTAssertEqual(batch.scanSessionID, scanResult.summary.scanID)
        XCTAssertTrue(batch.receipts.allSatisfy { $0.scanSessionID == scanResult.summary.scanID })
    }

    // MARK: - Stale batch refused at execute time

    func testStaleSelectionBatchIsRefusedBeforeAnythingIsAuthorized() async throws {
        let home = try FixtureHome("batch-stale")
        try home.write("Library/Logs/JunkApp/junk.log")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.batch.stale", tier: .safe)
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)
        let receipt = try home.receipt(at: "Library/Logs/JunkApp", ruleID: rule.id)
        let digest = try CleanService.currentCatalogDigest()

        let staleMintTime = Date().addingTimeInterval(-(SelectionBatch.maxAge + 1))
        let batch = try SelectionBatch(
            receipts: [receipt], scanSessionID: receipt.scanSessionID, catalogDigest: digest, mintedAt: staleMintTime
        )
        let request = CleanRequest(
            batch: batch, selectedCandidateIDs: [receipt.id],
            journalURL: home.url("journal.jsonl"), home: home.root
        )

        do {
            _ = try await CleanServiceTests.collect(CleanService.runPipeline(request))
            XCTFail("expected staleSelectionBatch to be thrown")
        } catch let error as CleanServiceError {
            guard error == .staleSelectionBatch else { return XCTFail("expected staleSelectionBatch, got \(error)") }
        }
        XCTAssertTrue(home.exists("Library/Logs/JunkApp/junk.log"), "nothing is touched once the batch is refused")
    }

    /// A batch minted just under the max age must still run normally. The fix must not turn
    /// every request into a stale refusal.
    func testFreshSelectionBatchWellUnderMaxAgeIsAccepted() async throws {
        let home = try FixtureHome("batch-fresh")
        try home.write("Library/Logs/JunkApp/junk.log")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.batch.fresh", tier: .safe)
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)
        let receipt = try home.receipt(at: "Library/Logs/JunkApp", ruleID: rule.id)
        let digest = try CleanService.currentCatalogDigest()

        let batch = try SelectionBatch(
            receipts: [receipt], scanSessionID: receipt.scanSessionID, catalogDigest: digest, mintedAt: Date()
        )
        let request = CleanRequest(
            batch: batch, selectedCandidateIDs: [receipt.id],
            journalURL: home.url("journal.jsonl"), home: home.root
        )

        let events = try await CleanServiceTests.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(CleanServiceTests.finishedReport(in: events))
        XCTAssertEqual(report.succeededCount, 1, "\(report.outcomes)")
    }

    // MARK: - Cross-catalog batch refused at execute time

    func testBatchMintedUnderADifferentCatalogIsRefused() async throws {
        let home = try FixtureHome("batch-cross-catalog")
        try home.write("Library/Logs/JunkApp/junk.log")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.batch.crosscatalog", tier: .safe)
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)
        let receipt = try home.receipt(at: "Library/Logs/JunkApp", ruleID: rule.id)

        // A digest that does not, and cannot, match whatever `CleanService` actually pinned:
        // standing in for "this batch was minted while a different catalog.json was on disk."
        let wrongDigest = String(repeating: "0", count: 64)
        let batch = try SelectionBatch(
            receipts: [receipt], scanSessionID: receipt.scanSessionID, catalogDigest: wrongDigest, mintedAt: Date()
        )
        let request = CleanRequest(
            batch: batch, selectedCandidateIDs: [receipt.id],
            journalURL: home.url("journal.jsonl"), home: home.root
        )

        do {
            _ = try await CleanServiceTests.collect(CleanService.runPipeline(request))
            XCTFail("expected catalogMismatch to be thrown")
        } catch let error as CleanServiceError {
            guard error == .catalogMismatch else { return XCTFail("expected catalogMismatch, got \(error)") }
        }
        XCTAssertTrue(home.exists("Library/Logs/JunkApp/junk.log"), "nothing is touched once the batch is refused")
    }

    // MARK: - currentCatalogDigest() is the pinned digest, cached like loadPinnedBundledCatalog()

    func testCurrentCatalogDigestMatchesWhatCleanServiceActuallyPins() throws {
        let home = try FixtureHome("batch-digest-matches")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.batch.digest", tier: .safe)
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)

        let digest = try CleanService.currentCatalogDigest()
        let pinned = try CleanService.loadPinnedBundledCatalog()
        XCTAssertEqual(digest, pinned.sha256Hex)
    }
}
