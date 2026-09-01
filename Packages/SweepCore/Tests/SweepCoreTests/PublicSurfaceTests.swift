import XCTest
import SweepCore   // deliberately NOT @testable: this file sees exactly what an app sees

/// Review finding #1: the public surface used to hand any caller a live-deletion capability.
///
/// Access control is a compile-time property, so there is nothing to assert at runtime about it —
/// reflection cannot see an initializer's access level, and a test that tried to call an internal
/// initializer would fail to *build*, not to run. What this file does instead is be a real
/// consumer: it imports `SweepCore` without `@testable`, so anything it compiles against is, by
/// construction, reachable from outside the package.
///
/// Each of these does not compile here, and that is the fix:
///
/// ```swift
/// DeletionCoordinator(mode: .fixtureOnly(root: URL(fileURLWithPath: "/")), journal: journal)
/// DeletionMode.fixtureOnly(root: URL(fileURLWithPath: "/"))
/// DeletionPlan(items: [])
/// DeletionItem(url: anywhere, identity: forged, action: .delete, tier: .safe, allocatedSize: 0)
/// try JSONDecoder().decode(DeletionPlan.self, from: handWrittenJSON)   // not Codable either
/// ```
///
/// The only route left is ``FixtureExecution``, which creates and owns its root.
final class PublicSurfaceTests: XCTestCase {

    func testFixtureExecutionIsTheOnlyPublicRouteToADeletion() async throws {
        let session = try FixtureExecution.makeSession(label: "public-surface")
        let file = session.root.appending(path: "caches/blob.bin")
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(repeating: 0x7A, count: 512).write(to: file)

        let journal = try await session.makeJournal()
        let coordinator = try session.makeCoordinator(journal: journal)
        let plan = try session.makePlan(paths: [file], action: .delete, tier: .safe)

        let report = try await coordinator.execute(plan)

        XCTAssertEqual(report.succeededCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        await journal.close()
    }

    func testTheSessionOwnsARootUnderTheTemporaryDirectory() throws {
        let session = try FixtureExecution.makeSession()
        // `URL.resolvingSymlinksInPath` rewrites `/private/var` back to `/var`, so both spellings
        // of the temporary directory are accepted here.
        let temporary = NSTemporaryDirectory()
        let prefixes = [temporary, "/private" + temporary].map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        XCTAssertTrue(
            prefixes.contains { session.root.path.hasPrefix($0) },
            "\(session.root.path) escaped the temporary directory"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.root.path))
    }

    func testAdoptingARootOutsideTheTemporaryDirectoryIsRefused() throws {
        for candidate in [
            FileManager.default.homeDirectoryForCurrentUser,
            URL(fileURLWithPath: "/"),
            URL(fileURLWithPath: "/private/tmp"),
        ] {
            XCTAssertThrowsError(try FixtureExecution.makeSession(adopting: candidate), candidate.path) { error in
                guard case .rootOutsideTemporaryDirectory = error as? FixtureExecutionError else {
                    return XCTFail("expected rootOutsideTemporaryDirectory for \(candidate.path), got \(error)")
                }
            }
        }
    }

    /// A symlink inside the temporary directory pointing somewhere dangerous is judged by where
    /// it resolves, not by where it sits.
    func testAdoptingASymlinkOutOfTheTemporaryDirectoryIsRefused() throws {
        let staging = FixtureExecution.temporaryDirectory
            .appending(path: "SweepSurfaceTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let link = staging.appending(path: "escape")
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: FileManager.default.homeDirectoryForCurrentUser
        )

        XCTAssertThrowsError(try FixtureExecution.makeSession(adopting: link)) { error in
            guard case .rootOutsideTemporaryDirectory = error as? FixtureExecutionError else {
                return XCTFail("expected rootOutsideTemporaryDirectory, got \(error)")
            }
        }
    }

    func testPlanCannotBeBuiltFromAPathOutsideTheSessionRoot() throws {
        let session = try FixtureExecution.makeSession()
        let other = try FixtureExecution.makeSession()
        let victim = other.root.appending(path: "precious.bin")
        try Data(repeating: 1, count: 8).write(to: victim)

        XCTAssertThrowsError(try session.makePlan(paths: [victim], action: .delete, tier: .safe)) { error in
            guard case .pathOutsideFixtureRoot = error as? FixtureExecutionError else {
                return XCTFail("expected pathOutsideFixtureRoot, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: victim.path))
    }

    /// The session reads identity from disk, so a caller cannot describe a file as something it
    /// is not — the other half of the forgeable-plan problem.
    func testPlanIdentityComesFromTheFilesystemNotTheCaller() throws {
        let session = try FixtureExecution.makeSession()
        let file = session.root.appending(path: "blob.bin")
        try Data(repeating: 3, count: 64).write(to: file)

        let plan = try session.makePlan(paths: [file], action: .trash, tier: .caution)
        let item = try XCTUnwrap(plan.items.first)
        XCTAssertGreaterThan(item.identity.inode, 0)
        XCTAssertEqual(item.identity.size, 64)
        XCTAssertNotNil(item.parentIdentity, "the parent chain is carried, not discarded")
    }

    /// Read-only types stay public: a UI can show a report without being able to make a plan.
    func testReportSurfaceRemainsReadable() async throws {
        let session = try FixtureExecution.makeSession()
        let file = session.root.appending(path: "blob.bin")
        try Data(repeating: 9, count: 16).write(to: file)

        let journal = try await session.makeJournal()
        let coordinator = try session.makeCoordinator(journal: journal)
        let report = try await coordinator.execute(
            try session.makePlan(paths: [file], action: .delete, tier: .safe, ruleID: "surface")
        )

        XCTAssertEqual(report.results(with: .succeeded).count, 1)
        XCTAssertEqual(report.results.first?.item.ruleID, "surface")
        XCTAssertEqual(report.results.first?.item.tier, .safe)
        XCTAssertTrue(report.committed)
        XCTAssertEqual(SweepCoreInfo.planVersion, DeletionPlan.currentVersion)
        await journal.close()
    }
}
