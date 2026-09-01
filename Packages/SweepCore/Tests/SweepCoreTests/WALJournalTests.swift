import XCTest
@testable import SweepCore

final class WALJournalTests: XCTestCase {

    func testCommittedOperationLeavesNothingToRecover() async throws {
        let tree = try TempTree("wal-committed")
        let url = tree.url("journal/ops.jsonl")
        let operationID = UUID()
        let items = [Self.item(path: "/fixture/a"), Self.item(path: "/fixture/b")]

        let journal = try await WALJournal(url: url)
        try await journal.appendPlanned(operationID: operationID, planVersion: 1, items: items)
        try await journal.appendStarted(operationID: operationID)
        for item in items {
            try await journal.appendItemResult(operationID: operationID, item: item, outcome: .succeeded)
        }
        try await journal.appendCommitted(operationID: operationID)
        await journal.close()

        // Fresh instance = process restart. Recovery runs during init.
        let reopened = try await WALJournal(url: url)
        let interrupted = await reopened.interrupted
        XCTAssertTrue(interrupted.isEmpty)
        let state = try await reopened.state(of: operationID)
        XCTAssertEqual(state, .committed)
    }

    func testCrashBetweenPlannedAndCommittedIsDetectedOnRecovery() async throws {
        let tree = try TempTree("wal-crash")
        let url = tree.url("journal/ops.jsonl")
        let operationID = UUID()
        let items = [Self.item(path: "/fixture/a"), Self.item(path: "/fixture/b")]

        let journal = try await WALJournal(url: url)
        try await journal.appendPlanned(operationID: operationID, planVersion: 1, items: items)
        try await journal.appendStarted(operationID: operationID)
        try await journal.appendItemResult(operationID: operationID, item: items[0], outcome: .succeeded)
        // Process dies here: no committed record is ever written.
        await journal.close()

        let recovered = try await WALJournal(url: url)
        let interrupted = await recovered.interrupted
        XCTAssertEqual(interrupted.count, 1)

        let operation = try XCTUnwrap(interrupted.first)
        XCTAssertEqual(operation.operationID, operationID)
        XCTAssertEqual(operation.state, .started)
        XCTAssertEqual(operation.planVersion, 1)
        XCTAssertEqual(operation.items.count, 2)
        XCTAssertEqual(operation.recordedOutcomes["/fixture/a"], .succeeded)
        XCTAssertEqual(operation.unresolvedItems.map(\.path), ["/fixture/b"])
    }

    func testCrashBeforeStartedIsDetected() async throws {
        let tree = try TempTree("wal-crash-planned")
        let url = tree.url("ops.jsonl")
        let operationID = UUID()

        let journal = try await WALJournal(url: url)
        try await journal.appendPlanned(
            operationID: operationID,
            planVersion: 1,
            items: [Self.item(path: "/fixture/a")]
        )
        await journal.close()

        let recovered = try await WALJournal(url: url)
        let interrupted = await recovered.interrupted
        XCTAssertEqual(interrupted.first?.state, .planned)
        XCTAssertEqual(interrupted.first?.unresolvedItems.count, 1)
    }

    func testInterruptedOperationSurvivesLaterCleanOperations() async throws {
        let tree = try TempTree("wal-mixed")
        let url = tree.url("ops.jsonl")
        let dead = UUID()
        let live = UUID()

        let journal = try await WALJournal(url: url)
        try await journal.appendPlanned(operationID: dead, planVersion: 1, items: [Self.item(path: "/fixture/a")])
        try await journal.appendStarted(operationID: dead)
        try await journal.appendPlanned(operationID: live, planVersion: 1, items: [Self.item(path: "/fixture/b")])
        try await journal.appendStarted(operationID: live)
        try await journal.appendCommitted(operationID: live)

        let interrupted = try await journal.recover()
        XCTAssertEqual(interrupted.map(\.operationID), [dead])
    }

    func testTornFinalLineIsToleratedAndEarlierRecordsSurvive() async throws {
        let tree = try TempTree("wal-torn")
        let url = tree.url("ops.jsonl")
        let operationID = UUID()

        let journal = try await WALJournal(url: url)
        try await journal.appendPlanned(operationID: operationID, planVersion: 1, items: [Self.item(path: "/fixture/a")])
        try await journal.appendStarted(operationID: operationID)
        await journal.close()

        // Simulate a crash midway through an append: a partial line, no trailing newline.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"version":1,"kind":"itemRes"#.utf8))
        try handle.close()

        let recovered = try await WALJournal(url: url)
        let tornTail = await recovered.recoveredTornTail
        XCTAssertTrue(tornTail)
        let records = try await recovered.records()
        XCTAssertEqual(records.count, 2)
        let interrupted = await recovered.interrupted
        XCTAssertEqual(interrupted.count, 1)
    }

    func testCorruptionBeforeTheLastLineIsFatal() async throws {
        let tree = try TempTree("wal-corrupt")
        let url = tree.url("ops.jsonl")

        let journal = try await WALJournal(url: url)
        try await journal.appendPlanned(operationID: UUID(), planVersion: 1, items: [Self.item(path: "/fixture/a")])
        await journal.close()

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{ this is not a record }\n".utf8))
        try handle.write(contentsOf: Data(#"{"version":1,"kind":"started","operationID":"\#(UUID().uuidString)","recordedAt":"2026-01-01T00:00:00Z"}"#.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        do {
            _ = try await WALJournal(url: url)
            XCTFail("expected corruptRecord")
        } catch let error as JournalError {
            guard case .corruptRecord(let line, _) = error else {
                return XCTFail("expected corruptRecord, got \(error)")
            }
            XCTAssertEqual(line, 2)
        }
    }

    func testUnsupportedRecordVersionIsRejected() async throws {
        let tree = try TempTree("wal-version")
        let url = tree.url("ops.jsonl")
        try tree.write(
            "ops.jsonl",
            contents: #"{"version":99,"kind":"started","operationID":"\#(UUID().uuidString)","recordedAt":"2026-01-01T00:00:00Z"}"# + "\n"
        )

        do {
            _ = try await WALJournal(url: url)
            XCTFail("expected unsupportedRecordVersion")
        } catch let error as JournalError {
            guard case .unsupportedRecordVersion(_, let version) = error else {
                return XCTFail("expected unsupportedRecordVersion, got \(error)")
            }
            XCTAssertEqual(version, 99)
        }
    }

    func testRecordsPreserveIdentityAndTrashURL() async throws {
        let tree = try TempTree("wal-roundtrip")
        let url = tree.url("ops.jsonl")
        let file = try tree.write("payload.bin", bytes: 128)
        let identity = try FileIdentity.read(at: file)
        let item = JournalItem(
            path: file.path,
            identity: identity,
            action: .trash,
            tier: .safe,
            allocatedSize: 4096,
            ruleID: "user.caches.app"
        )
        let trashURL = URL(fileURLWithPath: "/Users/tester/.Trash/payload.bin")
        let operationID = UUID()

        let journal = try await WALJournal(url: url)
        try await journal.appendPlanned(operationID: operationID, planVersion: 1, items: [item])
        try await journal.appendItemResult(
            operationID: operationID,
            item: item,
            outcome: .succeeded,
            trashURL: trashURL,
            detail: "moved to trash"
        )
        await journal.close()

        let reopened = try await WALJournal(url: url)
        let records = try await reopened.records()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records[0].items?.first?.identity, identity)
        XCTAssertEqual(records[0].items?.first?.ruleID, "user.caches.app")
        XCTAssertEqual(records[1].outcome, .succeeded)
        XCTAssertEqual(records[1].trashURL, trashURL)
    }

    func testJournalIsOneJSONObjectPerLine() async throws {
        let tree = try TempTree("wal-format")
        let url = tree.url("ops.jsonl")
        let operationID = UUID()

        let journal = try await WALJournal(url: url)
        try await journal.appendPlanned(operationID: operationID, planVersion: 1, items: [Self.item(path: "/fixture/a")])
        try await journal.appendCommitted(operationID: operationID)
        await journal.close()

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(text.hasSuffix("\n"))
        for line in lines {
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(line.utf8)))
        }
    }

    func testWritingToAClosedJournalThrows() async throws {
        let tree = try TempTree("wal-closed")
        let journal = try await WALJournal(url: tree.url("ops.jsonl"))
        await journal.close()

        do {
            try await journal.appendStarted(operationID: UUID())
            XCTFail("expected a journal failure")
        } catch let error as JournalError {
            guard case .closed = error else { return XCTFail("unexpected \(error)") }
        }
    }

    // MARK: - Review finding #6: a torn tail is removed, not merely skipped

    func testTornTailIsTruncatedSoTheNextAppendIsReadable() async throws {
        let tree = try TempTree("wal-torn-repair")
        let url = tree.url("ops.jsonl")
        let first = UUID()
        let second = UUID()

        let journal = try await WALJournal(url: url)
        try await journal.appendPlanned(operationID: first, planVersion: 1, items: [Self.item(path: "/fixture/a")])
        try await journal.appendStarted(operationID: first)
        await journal.close()

        // Crash mid-append: a partial line with no trailing newline.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"version":1,"kind":"itemRes"#.utf8))
        try handle.close()
        let tornLength = try Data(contentsOf: url).count

        let recovered = try await WALJournal(url: url)
        let sawTornTail = await recovered.recoveredTornTail
        XCTAssertTrue(sawTornTail)
        let repairedLength = try Data(contentsOf: url).count
        XCTAssertLessThan(repairedLength, tornLength, "the fragment is cut off the file, not just ignored")

        // Without the truncation the next record is concatenated onto the fragment and becomes
        // fatal mid-file corruption on the following open.
        try await recovered.appendPlanned(operationID: second, planVersion: 1, items: [Self.item(path: "/fixture/b")])
        try await recovered.appendCommitted(operationID: second)
        await recovered.close()

        let reopened = try await WALJournal(url: url)
        let records = try await reopened.records()
        XCTAssertEqual(records.count, 4)
        let stillTorn = await reopened.recoveredTornTail
        XCTAssertFalse(stillTorn, "the repair is durable, so the tail is clean now")
        let interrupted = await reopened.interrupted
        XCTAssertEqual(interrupted.map(\.operationID), [first])
    }

    // MARK: - Review finding #7: exactly one owner at a time

    func testASecondJournalOnTheSameFileIsRefused() async throws {
        let tree = try TempTree("wal-lock")
        let url = tree.url("ops.jsonl")
        let first = try await WALJournal(url: url)

        do {
            _ = try await WALJournal(url: url)
            XCTFail("two owners can interleave records and lose them")
        } catch let error as JournalError {
            guard case .locked = error else { return XCTFail("expected locked, got \(error)") }
        }

        // The lock is released with the descriptor, so a clean handover still works.
        await first.close()
        let second = try await WALJournal(url: url)
        try await second.appendStarted(operationID: UUID())
        await second.close()
    }

    // MARK: - Review finding #8: the journal's directory entry is durable before any mutation

    func testCreatingTheJournalSyncsItsDirectoryAndEveryCreatedAncestor() async throws {
        let tree = try TempTree("wal-durable")
        let url = tree.url("a/b/c/ops.jsonl")

        let journal = try await WALJournal(url: url)
        let synced = await journal.syncedDirectories

        XCTAssertTrue(synced.contains(url.deletingLastPathComponent().path), "the containing directory is synced")
        for ancestor in ["a/b/c", "a/b", "a"] {
            XCTAssertTrue(
                synced.contains(tree.url(ancestor).path),
                "\(ancestor) was created by this open and must be synced too"
            )
        }
        XCTAssertEqual(
            synced.first,
            url.deletingLastPathComponent().path,
            "deepest first: an entry is only durable once the directory holding it is"
        )
        await journal.close()
    }

    func testReopeningAnExistingJournalStillSyncsItsDirectory() async throws {
        let tree = try TempTree("wal-durable-reopen")
        let url = tree.url("ops.jsonl")
        let first = try await WALJournal(url: url)
        await first.close()

        let second = try await WALJournal(url: url)
        let synced = await second.syncedDirectories
        XCTAssertEqual(synced, [url.deletingLastPathComponent().path])
        await second.close()
    }

    // MARK: - Review finding #2: symlink redirect and pathname re-reads

    /// A pre-planted symlink at the journal's own pathname must be refused outright, never
    /// followed and never appended through.
    func testPrePlantedSymlinkAtTheJournalPathIsRefused() async throws {
        let tree = try TempTree("wal-symlink-redirect")
        let victim = tree.url("victim.txt")
        try Data("do not touch".utf8).write(to: victim)
        let journalPath = tree.url("clean-journal.jsonl")
        try FileManager.default.createSymbolicLink(at: journalPath, withDestinationURL: victim)

        do {
            _ = try await WALJournal(url: journalPath)
            XCTFail("expected the journal open to refuse a symlinked path")
        } catch let error as JournalError {
            guard case .cannotCreate = error else { return XCTFail("expected cannotCreate, got \(error)") }
        }

        XCTAssertEqual(
            try String(contentsOf: victim, encoding: .utf8), "do not touch",
            "the symlink's target must never receive WAL bytes"
        )
    }

    /// A pre-existing, non-symlink node at the journal's path that is writable by group or other
    /// is refused too — `O_NOFOLLOW` alone would not catch this, since it is not a symlink.
    func testPreExistingGroupWritableJournalFileIsRefused() async throws {
        let tree = try TempTree("wal-mode-check")
        let url = tree.url("ops.jsonl")
        try Data().write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: url.path)

        do {
            _ = try await WALJournal(url: url)
            XCTFail("expected the journal open to refuse a group/other-writable pre-existing file")
        } catch let error as JournalError {
            guard case .cannotCreate = error else { return XCTFail("expected cannotCreate, got \(error)") }
        }
    }

    /// Recovery/replay reads through the same locked descriptor every append uses, never the
    /// pathname again: swapping the pathname out from under an already-open journal must not
    /// change what a subsequent read sees.
    func testReadsUseTheLockedDescriptorNotAPathnameSwappedAfterOpen() async throws {
        let tree = try TempTree("wal-pread-anchor")
        let url = tree.url("ops.jsonl")
        let operationID = UUID()
        let journal = try await WALJournal(url: url)
        try await journal.appendPlanned(operationID: operationID, planVersion: 1, items: [Self.item(path: "/fixture/a")])

        // Swap the pathname out from under the open, locked descriptor: unlink the real file and
        // put an unrelated one with the same name in its place.
        try FileManager.default.removeItem(at: url)
        try Data("{\"not\":\"a real record\"}\n".utf8).write(to: url)

        let records = try await journal.records()
        XCTAssertEqual(
            records.count, 1,
            "must read the file the descriptor still holds open, not whatever now sits at the pathname"
        )
        XCTAssertEqual(records.first?.kind, .planned)
        await journal.close()
    }

    static func item(path: String) -> JournalItem {
        JournalItem(
            path: path,
            identity: FileIdentity(
                deviceID: 16_777_234,
                inode: 4_242,
                volume: VolumeIdentity(deviceID: 16_777_234, uuid: nil),
                kind: .file,
                linkCount: 1,
                modification: FileTimestamp(seconds: 1_800_000_000, nanoseconds: 123)
            ),
            action: .trash,
            tier: .safe,
            allocatedSize: 4096
        )
    }
}
