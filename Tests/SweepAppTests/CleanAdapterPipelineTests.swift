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

        let context = CleanExecutionContext(catalog: catalog, ruleIDByItemID: [nodeURL.path: ruleID])
        let item = InventoryItem(id: nodeURL.path, title: nodeName, byteCount: 4, tier: .safe)
        // The internal test seam, not `gate1Open`: `runPipeline` is what SweepCore itself uses to
        // prove the pipeline correct while the gate stays closed (`CleanServiceTests` does the
        // same). Reachable here only because this file `@testable import SweepCore`.
        let adapter = CleanAdapter(context: context, items: [item], executePipeline: SweepCore.CleanService.runPipeline)

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
}
