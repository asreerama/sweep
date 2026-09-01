import XCTest
@testable import SweepApp
@testable import SweepCore
import SweepUI

/// Codex Gate-1 finding #8: "CleanAdapter-level execution test through the real CleanService
/// pipeline against a fixture." `gate1Open` is a hardcoded `static let false` and stays exactly
/// that — this test never touches it. Instead it uses the internal test seam SweepCore already
/// exposes for this purpose, `CleanService.runPipeline`, injected into `CleanAdapter` through its
/// test-only initializer, so everything *after* the gate check — authorization against a
/// hash-pinned bundled catalog, the WAL, the trash-only executor, a real `FileManager.trashItem`
/// call — runs for real.
///
/// `CleanAdapter`'s production shape always resolves operation roots against the real account
/// home (it has no fixture-home override on purpose — see `CleanAdapter.swift`'s own doc comment
/// on why one is deliberately not offered), so the "fixture" here is a disposable, uniquely
/// named subdirectory of the tester's own real `~/Library/Logs`, created and removed by this
/// test, mirroring how `AuthorizedCleanPlanTests` already reasons `.userLogs` is safe to exercise
/// directly for the same reason.
final class CleanAdapterPipelineTests: XCTestCase {

    override func setUp() {
        super.setUp()
        SweepCore.CleanService.resetBundledCatalogDirectoryForTesting()
    }

    override func tearDown() {
        SweepCore.CleanService.resetBundledCatalogDirectoryForTesting()
        super.tearDown()
    }

    func testCleanAdapterRunsTheRealPipelineAgainstAFixtureNodeAndTrashesIt() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logsRoot = home.appending(path: "Library/Logs")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: logsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("~/Library/Logs is not available in this environment")
        }

        let nodeName = "SweepCleanAdapterPipelineTest-\(UUID().uuidString)"
        let nodeURL = logsRoot.appending(path: nodeName, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: nodeURL, withIntermediateDirectories: true)
            try Data("junk".utf8).write(to: nodeURL.appending(path: "junk.log"))
        } catch {
            throw XCTSkip("cannot write a disposable fixture under ~/Library/Logs here: \(error)")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: nodeURL) }

        // Trashing can be unavailable depending on the volume `~/Library/Logs` lives on; skip
        // rather than fail, mirroring every other real-Trash test in this codebase.
        let probeURL = logsRoot.appending(path: "sweep-adapter-pipeline-probe-\(UUID().uuidString).txt")
        try Data("probe".utf8).write(to: probeURL)
        var probe: NSURL?
        do {
            try FileManager.default.trashItem(at: probeURL, resultingItemURL: &probe)
            if let probe = probe as URL? { try? FileManager.default.removeItem(at: probe) }
        } catch {
            try? FileManager.default.removeItem(at: probeURL)
            throw XCTSkip("FileManager.trashItem unavailable here: \(error.localizedDescription)")
        }

        let ruleID = "test.cleanadapter.pipeline"
        let rule = Rule(
            id: ruleID, title: "Adapter pipeline test", group: .systemJunk, root: .userLogs,
            pattern: "*", itemTypes: [.directory], tier: .safe, action: .trash, undo: .trashRestore,
            rationale: "CleanAdapter-level pipeline regression test (Codex G1 finding #8)"
        )
        let catalog = RuleCatalog(rules: [rule])

        let schemaDirectory = FileManager.default.temporaryDirectory
            .appending(path: "CleanAdapterPipelineTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: schemaDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: schemaDirectory) }
        try Data("{}".utf8).write(to: schemaDirectory.appending(path: "schema.json"))
        try JSONEncoder().encode(catalog).write(to: schemaDirectory.appending(path: "catalog.json"))
        SweepCore.CleanService.configureBundledCatalogDirectory(schemaDirectory)

        // Codex G1 finding #6: the context must carry the identity reviewed at "scan" time so
        // `CleanAdapter` can bind its depth-1 rescan candidate to it by device+inode.
        let reviewedIdentity = try SweepCore.FileIdentity.read(at: nodeURL)
        let context = CleanExecutionContext(
            catalog: catalog, ruleIDByItemID: [nodeURL.path: ruleID],
            reviewedIdentityByItemID: [nodeURL.path: reviewedIdentity]
        )
        let item = InventoryItem(id: nodeURL.path, title: nodeName, byteCount: 4, tier: .safe)
        // The internal test seam, not `gate1Open`: `runPipeline` is what SweepCore itself uses to
        // prove the pipeline correct while the gate stays closed (`CleanServiceTests` does the
        // same). Reachable here only because this file `@testable import SweepCore`.
        let adapter = CleanAdapter(context: context, items: [item], executePipeline: { SweepCore.CleanService.runPipeline($0) })

        var finalReport: SweepUI.CleanReport?
        for try await event in adapter.execute(itemIDs: [item.id]) {
            if case .finished(let report) = event { finalReport = report }
        }

        let report = try XCTUnwrap(finalReport)
        XCTAssertEqual(report.succeededCount, 1, "\(report.outcomes)")
        XCTAssertTrue(report.failures.isEmpty, "\(report.failures)")
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: nodeURL.path),
            "the real CleanService pipeline, reached through CleanAdapter, actually trashed the fixture node"
        )
    }

    /// Codex G1 finding #6 (NOT-CLOSED): a decoy object occupying the reviewed path (same path,
    /// different inode) must be refused with a distinct "changed since review" outcome, never
    /// matched and trashed just because its pathname happens to line up with what was reviewed.
    func testCleanAdapterRefusesADecoyOccupyingTheReviewedPath() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logsRoot = home.appending(path: "Library/Logs")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: logsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("~/Library/Logs is not available in this environment")
        }

        let nodeName = "SweepCleanAdapterDecoyTest-\(UUID().uuidString)"
        let nodeURL = logsRoot.appending(path: nodeName, directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: nodeURL, withIntermediateDirectories: true)
            try Data("reviewed".utf8).write(to: nodeURL.appending(path: "junk.log"))
        } catch {
            throw XCTSkip("cannot write a disposable fixture under ~/Library/Logs here: \(error)")
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: nodeURL) }

        // The identity a "scan" would have captured for the object the user actually reviewed.
        let reviewedIdentity = try SweepCore.FileIdentity.read(at: nodeURL)

        // Swap it out from under its own path: remove it and put a fresh directory with the same
        // name (and even the same file inside) in its place. Same path, different inode.
        try FileManager.default.removeItem(at: nodeURL)
        try FileManager.default.createDirectory(at: nodeURL, withIntermediateDirectories: true)
        try Data("decoy".utf8).write(to: nodeURL.appending(path: "junk.log"))
        let decoyIdentity = try SweepCore.FileIdentity.read(at: nodeURL)
        XCTAssertNotEqual(reviewedIdentity.inode, decoyIdentity.inode, "precondition: the decoy has a new inode")

        let ruleID = "test.cleanadapter.decoy"
        let rule = Rule(
            id: ruleID, title: "Adapter decoy test", group: .systemJunk, root: .userLogs,
            pattern: "*", itemTypes: [.directory], tier: .safe, action: .trash, undo: .trashRestore,
            rationale: "CleanAdapter-level identity-binding regression test (Codex G1 finding #6)"
        )
        let catalog = RuleCatalog(rules: [rule])

        let schemaDirectory = FileManager.default.temporaryDirectory
            .appending(path: "CleanAdapterDecoyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: schemaDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: schemaDirectory) }
        try Data("{}".utf8).write(to: schemaDirectory.appending(path: "schema.json"))
        try JSONEncoder().encode(catalog).write(to: schemaDirectory.appending(path: "catalog.json"))
        SweepCore.CleanService.configureBundledCatalogDirectory(schemaDirectory)

        // The context still carries the *stale* (pre-swap) reviewed identity: exactly what a
        // real `ScanModel` would hold if the swap happened between review and Clean.
        let context = CleanExecutionContext(
            catalog: catalog, ruleIDByItemID: [nodeURL.path: ruleID],
            reviewedIdentityByItemID: [nodeURL.path: reviewedIdentity]
        )
        let item = InventoryItem(id: nodeURL.path, title: nodeName, byteCount: 4, tier: .safe)
        let adapter = CleanAdapter(context: context, items: [item], executePipeline: { SweepCore.CleanService.runPipeline($0) })

        var finalReport: SweepUI.CleanReport?
        for try await event in adapter.execute(itemIDs: [item.id]) {
            if case .finished(let report) = event { finalReport = report }
        }

        let report = try XCTUnwrap(finalReport)
        XCTAssertEqual(report.succeededCount, 0, "\(report.outcomes)")
        let outcome = try XCTUnwrap(report.outcomes.first)
        let reason = try XCTUnwrap(outcome.failureReason)
        XCTAssertTrue(reason.contains("Changed since review"), "expected a distinct 'changed since review' reason, got: \(reason)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nodeURL.path),
            "the decoy must never be trashed just because its pathname matches the reviewed one"
        )
        XCTAssertEqual(
            try String(contentsOf: nodeURL.appending(path: "junk.log"), encoding: .utf8), "decoy",
            "the decoy's own content is untouched"
        )
    }
}

extension CleanAdapterPipelineTests {
    /// Codex G1 verdict 4 (controlling reason): a degraded or uncommitted operation must never
    /// surface as a plain success. Injects a pipeline that "succeeds" while reporting
    /// `journalingDegraded: true` and asserts the adapter marks the item failed with the
    /// degraded-journal explanation. Fixture setup mirrors the real-pipeline test so the
    /// adapter's own pre-checks (rule on record, reviewed identity, depth-1 rescan) all pass
    /// and the degraded branch is what gets exercised.
    func testDegradedOrUncommittedOperationIsNeverPresentedAsSuccess() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let logsRoot = home.appending(path: "Library/Logs")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: logsRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("~/Library/Logs is not available in this environment")
        }
        let nodeName = "SweepDegradedTest-\(UUID().uuidString)"
        let nodeURL = logsRoot.appending(path: nodeName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nodeURL, withIntermediateDirectories: true)
        try Data("junk".utf8).write(to: nodeURL.appending(path: "junk.log"))
        addTeardownBlock { try? FileManager.default.removeItem(at: nodeURL) }

        let ruleID = "test.cleanadapter.degraded"
        let rule = Rule(
            id: ruleID, title: "Degraded surfacing test", group: .systemJunk, root: .userLogs,
            pattern: "*", itemTypes: [.directory], tier: .safe, action: .trash, undo: .trashRestore,
            rationale: "Codex G1 verdict-4 regression: degraded ops must never present as success"
        )
        let catalog = RuleCatalog(rules: [rule])
        let schemaDirectory = FileManager.default.temporaryDirectory
            .appending(path: "SweepDegradedTest-catalog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: schemaDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: schemaDirectory) }
        try Data("{}".utf8).write(to: schemaDirectory.appending(path: "schema.json"))
        try JSONEncoder().encode(catalog).write(to: schemaDirectory.appending(path: "catalog.json"))
        SweepCore.CleanService.resetBundledCatalogDirectoryForTesting()
        SweepCore.CleanService.configureBundledCatalogDirectory(schemaDirectory)
        addTeardownBlock { SweepCore.CleanService.resetBundledCatalogDirectoryForTesting() }
        let reviewedIdentity = try SweepCore.FileIdentity.read(at: nodeURL)
        let context = CleanExecutionContext(
            catalog: catalog, ruleIDByItemID: [nodeURL.path: ruleID],
            reviewedIdentityByItemID: [nodeURL.path: reviewedIdentity]
        )
        let item = InventoryItem(id: nodeURL.path, title: nodeName, byteCount: 4, tier: .safe)

        let degradedPipeline: @Sendable (SweepCore.CleanRequest) -> AsyncThrowingStream<SweepCore.CleanEvent, Error> = { _ in
            AsyncThrowingStream { continuation in
                continuation.yield(.started(operationID: UUID(), itemCount: 1))
                continuation.yield(.finished(SweepCore.CleanReport(
                    operationID: UUID(), outcomes: [], committed: false,
                    catalogDigest: "test-digest", journalingDegraded: true, freedBytesEstimate: 0
                )))
                continuation.finish()
            }
        }
        let adapter = CleanAdapter(context: context, items: [item], executePipeline: degradedPipeline)

        var finalReport: SweepUI.CleanReport?
        for try await event in adapter.execute(itemIDs: [item.id]) {
            if case .finished(let report) = event { finalReport = report }
        }

        let report = try XCTUnwrap(finalReport)
        XCTAssertEqual(report.succeededCount, 0, "a degraded operation must not count as succeeded")
        XCTAssertFalse(report.failures.isEmpty, "the degraded operation must surface as a failure")
        let reason = report.failures.first.map(String.init(describing:)) ?? ""
        XCTAssertTrue(reason.localizedCaseInsensitiveContains("journal") || reason.localizedCaseInsensitiveContains("stopped"),
                      "failure reason must explain the journaling degradation, got: \(reason)")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: nodeURL.path),
            "nothing was actually trashed by the injected pipeline; the fixture must survive"
        )
    }
}
