import XCTest
@testable import SweepCore

final class WALJournalTests: XCTestCase {

    func testCommittedOperationLeavesNothingToRecover() async throws {
        let tree = try TempTree("wal-committed")
        let url = tree.url("journal/ops.jsonl")
        let operationID = UUID()
        let items = [Self.item(path: "/fixture/a"), Self.item(path: "/fixture/b")]

        let journal = try WALJournal(url: url)
        try await journal.appendPlanned(operationID: operationID, planVersion: 1, items: items)
        try await journal.appendStarted(operationID: operationID)
        for item in items {
            try await journal.appendItemResult(operationID: operationID, item: item, outcome: .succeeded)
        }
        try await journal.appendCommitted(operationID: operationID)
        await journal.close()

        // Fresh instance = process restart. Recovery runs during init.
        let reopened = try WALJournal(url: url)
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

        let journal = try WALJournal(url: url)
        try await journal.appendPlanned(operationID: operationID, planVersion: 1, items: items)
        try await journal.appendStarted(operationID: operationID)
        try await journal.appendItemResult(operationID: operationID, item: items[0], outcome: .succeeded)
        // Process dies here: no committed record is ever written.
        await journal.close()

        let recovered = try WALJournal(url: url)
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

        let journal = try WALJournal(url: url)
        try await journal.appendPlanned(
            operationID: operationID,
            planVersion: 1,
            items: [Self.item(path: "/fixture/a")]
        )
        await journal.close()

        let recovered = try WALJournal(url: url)
        let interrupted = await recovered.interrupted
        XCTAssertEqual(interrupted.first?.state, .planned)
        XCTAssertEqual(interrupted.first?.unresolvedItems.count, 1)
    }

    func testInterruptedOperationSurvivesLaterCleanOperations() async throws {
        let tree = try TempTree("wal-mixed")
        let url = tree.url("ops.jsonl")
        let dead = UUID()
        let live = UUID()

        let journal = try WALJournal(url: url)
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

        let journal = try WALJournal(url: url)
        try await journal.appendPlanned(operationID: operationID, planVersion: 1, items: [Self.item(path: "/fixture/a")])
        try await journal.appendStarted(operationID: operationID)
        await journal.close()

        // Simulate a crash midway through an append: a partial line, no trailing newline.
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(#"{"version":1,"kind":"itemRes"#.utf8))
        try handle.close()

        let recovered = try WALJournal(url: url)
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

        let journal = try WALJournal(url: url)
        try await journal.appendPlanned(operationID: UUID(), planVersion: 1, items: [Self.item(path: "/fixture/a")])
        await journal.close()

        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{ this is not a record }\n".utf8))
        try handle.write(contentsOf: Data(#"{"version":1,"kind":"started","operationID":"\#(UUID().uuidString)","recordedAt":"2026-01-01T00:00:00Z"}"#.utf8))
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        XCTAssertThrowsError(try WALJournal(url: url)) { error in
            guard case .corruptRecord(let line, _) = error as? JournalError else {
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

        XCTAssertThrowsError(try WALJournal(url: url)) { error in
            guard case .unsupportedRecordVersion(_, let version) = error as? JournalError else {
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

        let journal = try WALJournal(url: url)
        try await journal.appendPlanned(operationID: operationID, planVersion: 1, items: [item])
        try await journal.appendItemResult(
            operationID: operationID,
            item: item,
            outcome: .succeeded,
            trashURL: trashURL,
            detail: "moved to trash"
        )
        await journal.close()

        let reopened = try WALJournal(url: url)
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

        let journal = try WALJournal(url: url)
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
        let journal = try WALJournal(url: tree.url("ops.jsonl"))
        await journal.close()

        do {
            try await journal.appendStarted(operationID: UUID())
            XCTFail("expected a journal failure")
        } catch let error as JournalError {
            guard case .closed = error else { return XCTFail("unexpected \(error)") }
        }
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
