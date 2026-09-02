import XCTest
@testable import SweepCore

/// `EmptyTrashService` against a fixture directory (the internal `trashDirectory:` seam — the
/// public entry points always mean the real `~/.Trash` and are never exercised here).
///
/// The contract under test is PLAN §3 module 1, verbatim: "item identities snapshotted at
/// review, anything added after review skipped" — plus this module's own refusal rule: an entry
/// whose identity changed since review settles per-item, never deletes whatever sits there now.
final class EmptyTrashServiceTests: XCTestCase {

    private func makeTrash(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "empty-trash-tests-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @discardableResult
    private func write(_ url: URL, bytes: Int = 16) throws -> URL {
        try Data(repeating: 0xA5, count: bytes).write(to: url)
        return url
    }

    func testReviewCapturesTopLevelEntriesWithIdentities() throws {
        let trash = try makeTrash("review")
        try write(trash.appending(path: "a.bin"))
        try FileManager.default.createDirectory(at: trash.appending(path: "folder"), withIntermediateDirectories: true)
        try write(trash.appending(path: "folder/inner.bin"), bytes: 64)
        try write(trash.appending(path: ".DS_Store"))

        let review = EmptyTrashService.review(trashDirectory: trash)

        XCTAssertEqual(review.itemCount, 2, ".DS_Store never counts as user content")
        XCTAssertTrue(review.items.allSatisfy { $0.identity.inode != 0 })
        XCTAssertGreaterThan(review.totalBytes, 0)
    }

    func testExecuteDeletesExactlyTheReviewedObjects() throws {
        let trash = try makeTrash("delete")
        let a = try write(trash.appending(path: "a.bin"))
        let b = try write(trash.appending(path: "b.bin"))

        let review = EmptyTrashService.review(trashDirectory: trash)
        let report = EmptyTrashService.execute(review: review, trashDirectory: trash)

        XCTAssertEqual(report.deletedCount, 2)
        XCTAssertEqual(report.refusedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.path))
    }

    func testAdditionAfterReviewIsSkippedAndCounted() throws {
        let trash = try makeTrash("late")
        try write(trash.appending(path: "reviewed.bin"))
        let review = EmptyTrashService.review(trashDirectory: trash)

        // Arrives after review — the PLAN's exact "anything added after review skipped".
        let late = try write(trash.appending(path: "late.bin"))

        let report = EmptyTrashService.execute(review: review, trashDirectory: trash)

        XCTAssertEqual(report.deletedCount, 1)
        XCTAssertEqual(report.lateAdditionsSkipped, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: late.path), "a late addition must never be touched")
    }

    func testIdentitySwapAfterReviewIsRefusedPerItem() throws {
        let trash = try makeTrash("swap")
        let victim = try write(trash.appending(path: "victim.bin"))
        let review = EmptyTrashService.review(trashDirectory: trash)

        // Same name, different object: the reviewed inode is gone, an imposter wears its name.
        try FileManager.default.removeItem(at: victim)
        try write(victim, bytes: 128)

        let report = EmptyTrashService.execute(review: review, trashDirectory: trash)

        XCTAssertEqual(report.deletedCount, 0)
        XCTAssertEqual(report.outcomes.first?.result, .changedSinceReview)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: victim.path),
            "the imposter must survive — execute deletes reviewed objects, never name-alikes"
        )
    }

    func testVanishedItemSettlesWithoutFailingTheRun() throws {
        let trash = try makeTrash("vanish")
        let gone = try write(trash.appending(path: "gone.bin"))
        let stays = try write(trash.appending(path: "stays.bin"))
        let review = EmptyTrashService.review(trashDirectory: trash)

        try FileManager.default.removeItem(at: gone)

        let report = EmptyTrashService.execute(review: review, trashDirectory: trash)

        XCTAssertEqual(report.deletedCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stays.path))
        XCTAssertTrue(report.outcomes.contains { $0.result == .vanishedSinceReview })
    }

    func testSymlinkedTrashDirectoryReviewsEmpty() throws {
        let real = try makeTrash("symlink-target")
        try write(real.appending(path: "bait.bin"))
        let container = try makeTrash("symlink-container")
        let link = container.appending(path: "linked-trash")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        let review = EmptyTrashService.review(trashDirectory: link)

        XCTAssertTrue(review.isEmpty, "a symlinked Trash is refused wholesale, never followed")
    }
}
