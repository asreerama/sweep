import XCTest
@testable import SweepCore
import SweepPolicy

/// Gate 1's `trashOnly` `DeletionMode`: real-filesystem descriptor descent, anchored at
/// authorization-derived roots, trash verb only.
final class TrashOnlyExecutionTests: XCTestCase {

    // MARK: - Compile-surface: the executor structurally cannot delete

    /// Deliverable #3: "trash executor structurally lacks delete verbs (compile-surface test)".
    ///
    /// `TrashOnlyFileDescriptorExecutor` conforms only to `TrashCapable`. It has no `delete`
    /// method — not disabled, not gated, simply absent — so none of these compile where the
    /// concrete type is visible, which is everywhere inside this package:
    ///
    /// ```swift
    /// let executor = TrashOnlyFileDescriptorExecutor(anchors: [:], queue: someQueue)
    /// try await executor.delete(someRequest)                    // no such method
    /// let mutating: any FileMutating = executor                 // does not conform
    /// ```
    ///
    /// What *is* checkable at runtime is the fact behind that compile error: casting any
    /// instance of this type to `any FileMutating` fails, unconditionally, because the
    /// conformance was never declared — this is a fact about the type, not a flag that could be
    /// flipped.
    func testTrashOnlyExecutorNeverConformsToFileMutating() {
        let executor: any TrashCapable = TrashOnlyFileDescriptorExecutor(
            anchors: [:], queue: BlockingIOQueue(label: "test.trashonly")
        )
        XCTAssertFalse(executor is any FileMutating, "trash-only mode's executor must never gain a delete verb")
    }

    // MARK: - Real descriptor-anchored trash, against a fixture standing in for a real root

    func testTrashOnlyModeTrashesAnAuthorizedItemAndJournalsIt() async throws {
        let home = try FixtureHome("trashonly-happy")
        let file = try home.write("Library/Logs/App/junk-\(UUID().uuidString).log")

        var probe: NSURL?
        let probeFile = try home.write("probe.bin")
        do {
            try FileManager.default.trashItem(at: probeFile, resultingItemURL: &probe)
            if let probe = probe as URL? { try? FileManager.default.removeItem(at: probe) }
        } catch {
            throw XCTSkip("FileManager.trashItem unavailable here: \(error.localizedDescription)")
        }

        let resolved = try XCTUnwrap(SweepPolicy.resolvedRoots(for: .userLogs, home: home.root).first)
        let anchor = TrashOnlyAnchor(key: .operationRoot(.userLogs), url: resolved.url, identity: resolved.identity)

        let identity = try FileIdentity.read(at: file)
        let parentIdentity = try FileIdentity.read(at: file.deletingLastPathComponent())
        let item = DeletionItem(
            url: file, identity: identity, parentIdentity: parentIdentity,
            action: .trash, tier: .safe, allocatedSize: 0, ruleID: "test.userlogs.happy"
        )
        let plan = DeletionPlan(items: [item])

        let journalURL = home.url("journal.jsonl")
        let journal = try await WALJournal(url: journalURL)
        let coordinator = try DeletionCoordinator(mode: .trashOnly(anchors: [anchor]), journal: journal)

        let report = try await coordinator.execute(plan)

        XCTAssertEqual(report.succeededCount, 1, "\(report.results)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        let landed = try XCTUnwrap(report.results.first?.trashURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
        try? FileManager.default.removeItem(at: landed)

        let records = try await journal.records()
        XCTAssertTrue(records.contains { $0.kind == .planned })
        XCTAssertTrue(records.contains { $0.kind == .committed })
        let itemResult = try XCTUnwrap(records.first { $0.kind == .itemResult })
        XCTAssertEqual(itemResult.outcome, .succeeded)
        XCTAssertNotNil(itemResult.trashURL)
        await journal.close()
    }

    /// First of Gate 1's two independent gates: a `delete`-action item cannot even build a valid
    /// `trashOnly` plan — the whole plan is refused before anything is journaled.
    func testDeleteActionItemInATrashOnlyPlanIsRefusedAtValidation() async throws {
        let home = try FixtureHome("trashonly-delete-refused")
        let file = try home.write("Library/Logs/App/junk.log")
        let resolved = try XCTUnwrap(SweepPolicy.resolvedRoots(for: .userLogs, home: home.root).first)
        let anchor = TrashOnlyAnchor(key: .operationRoot(.userLogs), url: resolved.url, identity: resolved.identity)

        let identity = try FileIdentity.read(at: file)
        let item = DeletionItem(url: file, identity: identity, action: .delete, tier: .safe, allocatedSize: 0)
        let plan = DeletionPlan(items: [item])

        let journal = try await WALJournal(url: home.url("journal.jsonl"))
        let coordinator = try DeletionCoordinator(mode: .trashOnly(anchors: [anchor]), journal: journal)

        do {
            _ = try await coordinator.execute(plan)
            XCTFail("expected the plan to be refused")
        } catch let error as DeletionError {
            guard case .actionNotPermittedInTrashOnlyMode = error else {
                return XCTFail("unexpected \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        let records = try await journal.records()
        XCTAssertTrue(records.isEmpty, "refused before the write-ahead log is touched")
        await journal.close()
    }

    func testItemOutsideEveryAuthorizedRootIsRefusedAtValidation() async throws {
        let home = try FixtureHome("trashonly-outside")
        try home.makeDirectory("Library/Logs")
        let outside = try FixtureHome("trashonly-outside-victim")
        let victim = try outside.write("Library/Logs/precious.log")
        let resolved = try XCTUnwrap(SweepPolicy.resolvedRoots(for: .userLogs, home: home.root).first)
        let anchor = TrashOnlyAnchor(key: .operationRoot(.userLogs), url: resolved.url, identity: resolved.identity)

        let identity = try FileIdentity.read(at: victim)
        let item = DeletionItem(url: victim, identity: identity, action: .trash, tier: .safe, allocatedSize: 0)
        let plan = DeletionPlan(items: [item])

        let journal = try await WALJournal(url: home.url("journal.jsonl"))
        let coordinator = try DeletionCoordinator(mode: .trashOnly(anchors: [anchor]), journal: journal)

        do {
            _ = try await coordinator.execute(plan)
            XCTFail("expected the plan to be refused")
        } catch let error as DeletionError {
            guard case .outsideAuthorizedRoots = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        await journal.close()
    }

    /// Review finding #2's discipline, applied to the root itself: if the authorized root's
    /// identity changed between authorization and anchoring, the coordinator refuses to open it
    /// at all — it does not fall back to trusting the pathname.
    func testAnchorIdentityChangedIsRefusedAtConstruction() async throws {
        let home = try FixtureHome("trashonly-anchor-swap")
        let realRoot = try home.makeDirectory("Library/Logs")
        let realIdentity = try FileIdentity.read(at: realRoot)
        // A forged anchor: the real root URL, but an identity that does not match it — standing
        // in for "the root changed between authorize() and now".
        let forgedIdentity = PathIdentity(deviceID: realIdentity.deviceID, inode: realIdentity.inode + 1)
        let anchor = TrashOnlyAnchor(key: .operationRoot(.userLogs), url: realRoot, identity: forgedIdentity)

        let journal = try await WALJournal(url: home.url("journal.jsonl"))
        do {
            _ = try DeletionCoordinator(mode: .trashOnly(anchors: [anchor]), journal: journal)
            XCTFail("expected anchor construction to be refused")
        } catch let error as DeletionError {
            guard case .anchorIdentityChanged = error else { return XCTFail("unexpected \(error)") }
        }
        await journal.close()
    }

    // MARK: - Review finding #3: the per-operation quarantine directory must be created fresh

    /// A pre-existing directory at the exact name the coordinator's operation id would use is
    /// refused outright, never silently reused — the fix to `mkdirat`'s old "`EEXIST` is success"
    /// behavior for this specific call site.
    func testPreExistingOperationQuarantineDirectoryIsRefused() async throws {
        let home = try FixtureHome("trashonly-quarantine-preplanted")
        let file = try home.write("Library/Logs/App/junk.log")
        let resolved = try XCTUnwrap(SweepPolicy.resolvedRoots(for: .userLogs, home: home.root).first)
        let anchor = TrashOnlyAnchor(key: .operationRoot(.userLogs), url: resolved.url, identity: resolved.identity)

        let operationID = UUID()
        // Pre-plant the per-operation quarantine directory this exact operation id would use —
        // standing in for an attacker's guess or a stale leftover from a previous, buggy run.
        try FileManager.default.createDirectory(
            at: resolved.url
                .appending(path: FileDescriptorExecutor.quarantineDirectoryName)
                .appending(path: operationID.uuidString),
            withIntermediateDirectories: true
        )

        let identity = try FileIdentity.read(at: file)
        let parentIdentity = try FileIdentity.read(at: file.deletingLastPathComponent())
        let item = DeletionItem(
            url: file, identity: identity, parentIdentity: parentIdentity,
            action: .trash, tier: .safe, allocatedSize: 0
        )
        let plan = DeletionPlan(operationID: operationID, items: [item])

        let journal = try await WALJournal(url: home.url("journal.jsonl"))
        let coordinator = try DeletionCoordinator(mode: .trashOnly(anchors: [anchor]), journal: journal)
        let report = try await coordinator.execute(plan)

        XCTAssertEqual(report.succeededCount, 0, "a pre-existing operation quarantine directory must never be silently reused")
        XCTAssertTrue(home.exists("Library/Logs/App/junk.log"), "nothing is mutated when the slot cannot be created exclusively")
        await journal.close()
    }

    // MARK: - Multiple anchors, one execution

    func testTwoDifferentAuthorizedRootsBothTrashSuccessfully() async throws {
        let home = try FixtureHome("trashonly-two-roots")
        let logFile = try home.write("Library/Logs/App/junk-\(UUID().uuidString).log")
        let trashFile = try home.write(".Trash/old-\(UUID().uuidString).bin")

        var probe: NSURL?
        let probeFile = try home.write("probe.bin")
        do {
            try FileManager.default.trashItem(at: probeFile, resultingItemURL: &probe)
            if let probe = probe as URL? { try? FileManager.default.removeItem(at: probe) }
        } catch {
            throw XCTSkip("FileManager.trashItem unavailable here: \(error.localizedDescription)")
        }

        let logsRoot = try XCTUnwrap(SweepPolicy.resolvedRoots(for: .userLogs, home: home.root).first)
        let trashRoot = try XCTUnwrap(SweepPolicy.resolvedRoots(for: .trash, home: home.root).first)
        let anchors = [
            TrashOnlyAnchor(key: .operationRoot(.userLogs), url: logsRoot.url, identity: logsRoot.identity),
            TrashOnlyAnchor(key: .operationRoot(.trash), url: trashRoot.url, identity: trashRoot.identity),
        ]

        let items = try [logFile, trashFile].map { url in
            DeletionItem(
                url: url, identity: try FileIdentity.read(at: url),
                parentIdentity: try FileIdentity.read(at: url.deletingLastPathComponent()),
                action: .trash, tier: .safe, allocatedSize: 0
            )
        }
        let plan = DeletionPlan(items: items)

        let journal = try await WALJournal(url: home.url("journal.jsonl"))
        let coordinator = try DeletionCoordinator(mode: .trashOnly(anchors: anchors), journal: journal)
        let report = try await coordinator.execute(plan)

        XCTAssertEqual(report.succeededCount, 2, "\(report.results)")
        for result in report.results {
            if let trashURL = result.trashURL {
                try? FileManager.default.removeItem(at: trashURL)
            }
        }
        await journal.close()
    }
}
