import XCTest
@testable import SweepCore
import SweepPolicy

/// Records what it was asked to mutate and does nothing, so the gauntlet in front of the
/// mutation can be tested without a real trash round-trip.
final class RecordingExecutor: FileMutating, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var trashed: [URL] = []
    private(set) var deleted: [URL] = []
    var trashResult: URL?
    var errorToThrow: (any Error)?

    init(trashResult: URL? = nil, errorToThrow: (any Error)? = nil) {
        self.trashResult = trashResult
        self.errorToThrow = errorToThrow
    }

    func trash(_ url: URL) throws -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let errorToThrow { throw errorToThrow }
        trashed.append(url)
        return trashResult
    }

    func delete(_ url: URL) throws {
        lock.lock()
        defer { lock.unlock() }
        if let errorToThrow { throw errorToThrow }
        deleted.append(url)
    }
}

final class DeletionCoordinatorTests: XCTestCase {

    // MARK: - Happy path

    func testSafeTierDeleteInsideFixtureRootSucceeds() async throws {
        let fixture = try TempTree("del-happy")
        let file = try fixture.write("caches/app/blob.bin", bytes: 2048)
        let journalURL = fixture.url("journal.jsonl")

        let journal = try WALJournal(url: journalURL)
        let coordinator = DeletionCoordinator(mode: .fixtureOnly(root: fixture.root), journal: journal)
        let plan = try Self.plan(for: [file], action: .delete, tier: .safe)

        let report = try await coordinator.execute(plan)

        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertEqual(report.failedCount, 0)
        XCTAssertTrue(report.committed)
        XCTAssertEqual(report.plannedBytesRemoved, plan.totalAllocatedSize)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let state = try await journal.state(of: plan.operationID)
        XCTAssertEqual(state, .committed)
        let interrupted = try await journal.recover()
        XCTAssertTrue(interrupted.isEmpty)
    }

    func testTrashRecordsTheResultingURL() async throws {
        let fixture = try TempTree("del-trash")
        let file = try fixture.write("caches/doc.bin", bytes: 512)
        let trashURL = URL(fileURLWithPath: "/Users/tester/.Trash/doc.bin")
        let executor = RecordingExecutor(trashResult: trashURL)

        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(
            mode: .fixtureOnly(root: fixture.root),
            journal: journal,
            additionalDenials: .none,
            executor: executor
        )
        let plan = try Self.plan(for: [file], action: .trash, tier: .caution)

        let report = try await coordinator.execute(plan)

        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertEqual(report.results.first?.trashURL, trashURL)
        XCTAssertEqual(executor.trashed, [file])
        XCTAssertTrue(executor.deleted.isEmpty)

        let records = try await journal.records()
        let itemResult = try XCTUnwrap(records.first { $0.kind == .itemResult })
        XCTAssertEqual(itemResult.trashURL, trashURL, "the Trash URL is journaled so restore is possible")
    }

    func testRealTrashItemMovesFileOutOfTheFixture() async throws {
        let fixture = try TempTree("del-real-trash")
        let file = try fixture.write("caches/real-trash-\(UUID().uuidString).bin", bytes: 256)

        // Trashing can be unavailable depending on the volume the temp directory lives on.
        var probe: NSURL?
        let probeFile = try fixture.write("probe.bin", bytes: 1)
        do {
            try FileManager.default.trashItem(at: probeFile, resultingItemURL: &probe)
            if let probe = probe as URL? { try? FileManager.default.removeItem(at: probe) }
        } catch {
            throw XCTSkip("FileManager.trashItem unavailable here: \(error.localizedDescription)")
        }

        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(mode: .fixtureOnly(root: fixture.root), journal: journal)
        let report = try await coordinator.execute(try Self.plan(for: [file], action: .trash, tier: .safe))

        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))

        let landed = try XCTUnwrap(report.results.first?.trashURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: landed.path))
        try? FileManager.default.removeItem(at: landed)
    }

    // MARK: - Identity revalidation

    func testItemReplacedAfterScanIsRefused() async throws {
        let fixture = try TempTree("del-identity")
        let file = try fixture.write("caches/victim.bin", bytes: 1024)
        let plan = try Self.plan(for: [file], action: .delete, tier: .safe)
        let scannedInode = plan.items[0].identity.inode

        // Replace the file: same path, new inode. This is the swap the revalidation exists for.
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0x41, count: 1024).write(to: file)
        let replacedInode = try FileIdentity.read(at: file).inode
        XCTAssertNotEqual(scannedInode, replacedInode, "precondition: the replacement has a new inode")

        let executor = RecordingExecutor()
        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(
            mode: .fixtureOnly(root: fixture.root),
            journal: journal,
            additionalDenials: .none,
            executor: executor
        )

        let report = try await coordinator.execute(plan)

        XCTAssertEqual(report.changedCount, 1)
        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(report.results.first?.failureReason, .identityChanged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "the replacement must survive")
        XCTAssertTrue(executor.deleted.isEmpty, "the executor is never reached for a changed item")
    }

    func testItemModifiedInPlaceAfterScanIsRefused() async throws {
        let fixture = try TempTree("del-mtime")
        let file = try fixture.write("caches/mutating.bin", bytes: 128)
        let plan = try Self.plan(for: [file], action: .delete, tier: .safe)

        // Same inode, new mtime: a writer touched it between scan and delete.
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x42, count: 16))
        try handle.close()
        let after = try FileIdentity.read(at: file)
        XCTAssertEqual(after.inode, plan.items[0].identity.inode, "precondition: same inode")

        let executor = RecordingExecutor()
        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(
            mode: .fixtureOnly(root: fixture.root),
            journal: journal,
            additionalDenials: .none,
            executor: executor
        )

        let report = try await coordinator.execute(plan)

        XCTAssertEqual(report.changedCount, 1)
        XCTAssertEqual(report.results.first?.failureReason, .identityChanged)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertTrue(executor.deleted.isEmpty)
    }

    func testVanishedItemIsSkippedNotFailed() async throws {
        let fixture = try TempTree("del-vanished")
        let file = try fixture.write("caches/ghost.bin", bytes: 64)
        let plan = try Self.plan(for: [file], action: .delete, tier: .safe)
        try FileManager.default.removeItem(at: file)

        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(mode: .fixtureOnly(root: fixture.root), journal: journal)
        let report = try await coordinator.execute(plan)

        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.results.first?.failureReason, .vanished)
    }

    func testMixedPlanReportsPerItemOutcomes() async throws {
        let fixture = try TempTree("del-mixed")
        let good = try fixture.write("caches/good.bin", bytes: 100)
        let swapped = try fixture.write("caches/swapped.bin", bytes: 100)
        let plan = try Self.plan(for: [good, swapped], action: .delete, tier: .safe)

        try FileManager.default.removeItem(at: swapped)
        try Data(repeating: 0x43, count: 100).write(to: swapped)

        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(mode: .fixtureOnly(root: fixture.root), journal: journal)
        let report = try await coordinator.execute(plan)

        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertEqual(report.changedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: good.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: swapped.path))
        XCTAssertEqual(report.plannedBytesRemoved, plan.items[0].allocatedSize)
    }

    // MARK: - Fixture-only confinement

    func testPathOutsideFixtureRootIsRefusedBeforeAnythingIsWritten() async throws {
        let fixture = try TempTree("del-fixture")
        let outside = try TempTree("del-outside")
        let victim = try outside.write("precious.bin", bytes: 64)

        let journalURL = fixture.url("journal.jsonl")
        let journal = try WALJournal(url: journalURL)
        let executor = RecordingExecutor()
        let coordinator = DeletionCoordinator(
            mode: .fixtureOnly(root: fixture.root),
            journal: journal,
            additionalDenials: .none,
            executor: executor
        )
        let plan = try Self.plan(for: [victim], action: .delete, tier: .safe)

        do {
            _ = try await coordinator.execute(plan)
            XCTFail("expected the plan to be refused")
        } catch let error as DeletionError {
            guard case .outsideFixtureRoot = error else { return XCTFail("unexpected \(error)") }
        }

        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertTrue(executor.deleted.isEmpty)
        let records = try await journal.records()
        XCTAssertTrue(records.isEmpty, "refusal happens before the write-ahead log is touched")
    }

    func testOneOutsidePathRefusesTheWholePlan() async throws {
        let fixture = try TempTree("del-fixture-mixed")
        let outside = try TempTree("del-outside-mixed")
        let inside = try fixture.write("caches/inside.bin", bytes: 64)
        let victim = try outside.write("precious.bin", bytes: 64)

        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(mode: .fixtureOnly(root: fixture.root), journal: journal)
        let plan = try Self.plan(for: [inside, victim], action: .delete, tier: .safe)

        await XCTAssertThrowsErrorAsync(try await coordinator.execute(plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path), "fail closed: nothing runs")
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testFixtureRootItselfIsNotDeletable() {
        let root = URL(fileURLWithPath: "/private/tmp/fixture")
        XCTAssertFalse(DeletionCoordinator.isStrictlyContained(root, in: root))
        XCTAssertTrue(DeletionCoordinator.isStrictlyContained(root.appending(path: "child"), in: root))
        XCTAssertFalse(
            DeletionCoordinator.isStrictlyContained(URL(fileURLWithPath: "/private/tmp/fixture-sibling/x"), in: root)
        )
    }

    func testTraversalOutOfTheFixtureRootIsRefused() async throws {
        let fixture = try TempTree("del-traversal")
        let outside = try TempTree("del-traversal-outside")
        let victim = try outside.write("precious.bin", bytes: 32)
        let traversal = fixture.root.appending(path: "..").appending(path: victim.lastPathComponent)

        XCTAssertFalse(DeletionCoordinator.isStrictlyContained(traversal, in: fixture.root))

        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(mode: .fixtureOnly(root: fixture.root), journal: journal)
        let plan = DeletionPlan(items: [
            DeletionItem(
                url: traversal,
                identity: try FileIdentity.read(at: victim),
                action: .delete,
                tier: .safe,
                allocatedSize: 32
            ),
        ])

        await XCTAssertThrowsErrorAsync(try await coordinator.execute(plan))
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    func testLiveModeIsGatedShut() async throws {
        let fixture = try TempTree("del-live")
        let file = try fixture.write("caches/x.bin", bytes: 16)
        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        // The token is internal; outside this package `.live` cannot be constructed at all.
        let coordinator = DeletionCoordinator(mode: .live(LiveExecutionToken()), journal: journal)

        do {
            _ = try await coordinator.execute(try Self.plan(for: [file], action: .delete, tier: .safe))
            XCTFail("live mode must not execute before gate 1")
        } catch let error as DeletionError {
            guard case .liveModeNotEnabled = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    // MARK: - Policy backstop and tiers

    func testDenylistBackstopSkipsTheItem() async throws {
        let fixture = try TempTree("del-denylist")
        let denied = try fixture.write("caches/denied.bin", bytes: 64)
        let allowed = try fixture.write("caches/allowed.bin", bytes: 64)
        let deniedPath = denied.path

        let executor = RecordingExecutor()
        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(
            mode: .fixtureOnly(root: fixture.root),
            journal: journal,
            additionalDenials: DenyCheck { $0.path == deniedPath },
            executor: executor
        )

        let report = try await coordinator.execute(try Self.plan(for: [denied, allowed], action: .delete, tier: .safe))

        let deniedResult = try XCTUnwrap(report.results.first { $0.item.url == denied })
        XCTAssertEqual(deniedResult.outcome, .skipped)
        XCTAssertEqual(deniedResult.failureReason, .policyDenied)
        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertEqual(executor.deleted, [allowed], "only the allowed item reaches the executor")
        XCTAssertTrue(FileManager.default.fileExists(atPath: denied.path))

        let records = try await journal.records()
        let skipped = try XCTUnwrap(records.first { $0.outcome == .skipped })
        XCTAssertEqual(skipped.failureReason, .policyDenied, "the refusal is journaled, not silent")
    }

    func testSweepPolicyProtectedAreaIsRefusedEvenWhenTheProducerAsksForIt() async throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let documents = home.appending(path: "Documents/sweep-should-never-touch-this.txt")
        XCTAssertTrue(SweepPolicy.isDeniedLexically(documents), "precondition: ~/Documents is protected")

        // Fixture confinement refuses it first; the denylist is the second line of defense,
        // checked independently below.
        let fixture = try TempTree("del-policy")
        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(mode: .fixtureOnly(root: fixture.root), journal: journal)
        let plan = DeletionPlan(items: [
            DeletionItem(
                url: documents,
                identity: FileIdentity(
                    deviceID: 1,
                    inode: 1,
                    volume: VolumeIdentity(deviceID: 1, uuid: nil),
                    kind: .file,
                    linkCount: 1,
                    modification: FileTimestamp(seconds: 0, nanoseconds: 0)
                ),
                action: .trash,
                tier: .safe,
                allocatedSize: 0
            ),
        ])

        await XCTAssertThrowsErrorAsync(try await coordinator.execute(plan))
    }

    func testDirectDeleteOutsideSafeTierIsRefused() async throws {
        let fixture = try TempTree("del-tier")
        let file = try fixture.write("caches/expert.bin", bytes: 64)
        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(mode: .fixtureOnly(root: fixture.root), journal: journal)
        let plan = try Self.plan(for: [file], action: .delete, tier: .expert)

        do {
            _ = try await coordinator.execute(plan)
            XCTFail("expected a tier violation")
        } catch let error as DeletionError {
            guard case .tierViolation = error else { return XCTFail("unexpected \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testUnsupportedPlanVersionIsRefused() async throws {
        let fixture = try TempTree("del-version")
        let file = try fixture.write("caches/x.bin", bytes: 16)
        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(mode: .fixtureOnly(root: fixture.root), journal: journal)
        let items = try Self.plan(for: [file], action: .delete, tier: .safe).items
        let plan = DeletionPlan(version: 99, items: items)

        do {
            _ = try await coordinator.execute(plan)
            XCTFail("expected an unsupported plan version")
        } catch let error as DeletionError {
            guard case .unsupportedPlanVersion(let version) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(version, 99)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testEmptyPlanIsRefused() async throws {
        let fixture = try TempTree("del-empty")
        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(mode: .fixtureOnly(root: fixture.root), journal: journal)
        await XCTAssertThrowsErrorAsync(try await coordinator.execute(DeletionPlan(items: [])))
    }

    // MARK: - Journal failure aborts

    func testUnwritableJournalAbortsBeforeAnyMutation() async throws {
        let fixture = try TempTree("del-journal-abort")
        let file = try fixture.write("caches/x.bin", bytes: 64)
        let executor = RecordingExecutor()

        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        await journal.close()

        let coordinator = DeletionCoordinator(
            mode: .fixtureOnly(root: fixture.root),
            journal: journal,
            additionalDenials: .none,
            executor: executor
        )

        do {
            _ = try await coordinator.execute(try Self.plan(for: [file], action: .delete, tier: .safe))
            XCTFail("expected the operation to abort on journal failure")
        } catch let error as DeletionError {
            guard case .journalUnavailable = error else { return XCTFail("unexpected \(error)") }
        }

        XCTAssertTrue(executor.deleted.isEmpty, "nothing is mutated when the log cannot be written")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
    }

    func testExecutorFailureIsReportedNotThrown() async throws {
        let fixture = try TempTree("del-executor-error")
        let file = try fixture.write("caches/locked.bin", bytes: 64)
        let executor = RecordingExecutor(errorToThrow: NSError(
            domain: NSCocoaErrorDomain,
            code: NSFileWriteNoPermissionError
        ))

        let journal = try WALJournal(url: fixture.url("journal.jsonl"))
        let coordinator = DeletionCoordinator(
            mode: .fixtureOnly(root: fixture.root),
            journal: journal,
            additionalDenials: .none,
            executor: executor
        )

        let report = try await coordinator.execute(try Self.plan(for: [file], action: .delete, tier: .safe))
        XCTAssertEqual(report.failedCount, 1)
        XCTAssertEqual(report.results.first?.failureReason, .permissionDenied)
        XCTAssertTrue(report.committed, "a per-item failure still closes the operation cleanly")
    }

    // MARK: - Helpers

    static func plan(
        for urls: [URL],
        action: DeletionAction,
        tier: Tier,
        operationID: UUID = UUID()
    ) throws -> DeletionPlan {
        let items = try urls.map { url in
            DeletionItem(
                url: url,
                identity: try FileIdentity.read(at: url),
                action: action,
                tier: tier,
                allocatedSize: Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0),
                ruleID: "test.rule"
            )
        }
        return DeletionPlan(operationID: operationID, items: items)
    }
}

/// XCTAssertThrowsError has no async overload in this toolchain.
func XCTAssertThrowsErrorAsync(
    _ expression: @autoclosure () async throws -> some Any,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("expected an error", file: file, line: line)
    } catch {
        // expected
    }
}
