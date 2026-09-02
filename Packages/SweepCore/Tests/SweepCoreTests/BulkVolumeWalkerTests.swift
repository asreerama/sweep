import Darwin
import Foundation
import XCTest
@testable import SweepCore

/// ``BulkVolumeWalker`` has to be indistinguishable from ``FileManagerVolumeWalker`` from the
/// outside, and the part that matters most is the one with no visible symptom when it breaks: a
/// ``FileIdentity`` that differs by a single nanosecond of ctime is compared against a fresh
/// `lstat` at delete time, fails closed, and quietly refuses to clean the file. So every test
/// here runs both backends over the same tree and compares the emitted entries field by field,
/// rather than checking that the fast one merely "looks right".
final class BulkVolumeWalkerTests: XCTestCase {

    // MARK: - Parity

    func testFullWalkMatchesFileManagerBackend() throws {
        let fixture = try makeFixture("bulk-full")
        try assertParity(fixture, options: try fixture.options())
    }

    func testFilesOnlyWalkMatchesFileManagerBackend() throws {
        let fixture = try makeFixture("bulk-files-only")
        try assertParity(fixture, options: try fixture.options(includesDirectories: false))
    }

    func testDepthLimitedWalkMatchesFileManagerBackend() throws {
        let fixture = try makeFixture("bulk-depth")
        let captures = try assertParity(fixture, options: try fixture.options(maximumDepth: 2))
        XCTAssertTrue(
            captures.bulk.entries.allSatisfy { $0.depth <= 2 },
            "maximumDepth 2 must not emit anything deeper"
        )
        XCTAssertTrue(
            captures.bulk.paths.contains { $0.hasSuffix("/level1/level2") },
            "depth 2 itself is still in scope"
        )
    }

    func testSkipDescendantsMatchesFileManagerBackend() throws {
        let fixture = try makeFixture("bulk-skip")
        let captures = try assertParity(fixture, options: try fixture.options()) { entry, _ in
            entry.url.lastPathComponent == "skippable" ? .skipDescendants : .continue
        }
        XCTAssertTrue(captures.bulk.paths.contains { $0.hasSuffix("/skippable") })
        XCTAssertFalse(
            captures.bulk.paths.contains { $0.contains("/skippable/") },
            "nothing under a skipped directory may be emitted"
        )
    }

    /// `.stop` is the one directive where the two backends legitimately disagree on *which*
    /// entries come out, because sibling order inside a directory is arbitrary in both. What
    /// must match is the count, the stopped flag, and the identity of whatever did come out.
    func testStopEndsBothWalksAtTheSameCount() throws {
        let fixture = try makeFixture("bulk-stop")
        let options = try fixture.options()
        fixture.warmUp(options: options)

        let limit = 5
        let bulk = try capture(BulkVolumeWalker(), fixture.tree.root, options) { _, index in
            index + 1 >= limit ? .stop : .continue
        }
        let reference = try capture(FileManagerVolumeWalker(), fixture.tree.root, options) { _, index in
            index + 1 >= limit ? .stop : .continue
        }

        XCTAssertTrue(bulk.stopped)
        XCTAssertTrue(reference.stopped)
        XCTAssertEqual(bulk.entries.count, limit)
        XCTAssertEqual(reference.entries.count, limit)
        try assertIdentitiesRevalidate(bulk, volume: options.boundary)
    }

    /// The whole reason the identity fields have to be exact: a plan captured at scan time is
    /// re-read at delete time and refused unless every field still matches.
    func testEmittedIdentityEqualsAFreshRead() throws {
        let fixture = try makeFixture("bulk-revalidate")
        let options = try fixture.options()
        fixture.warmUp(options: options)
        let bulk = try capture(BulkVolumeWalker(), fixture.tree.root, options)

        XCTAssertGreaterThan(bulk.entries.count, 15, "the fixture should be substantial")
        try assertIdentitiesRevalidate(bulk, volume: options.boundary)
        for entry in bulk.entries {
            let fresh = try FileIdentity.read(at: entry.url, volume: options.boundary)
            XCTAssertTrue(
                entry.identity.isUnchanged(from: fresh),
                "delete-time revalidation would fail closed for \(entry.url.lastPathComponent)"
            )
        }
    }

    /// `ATTR_FILE_TOTALSIZE` counts the resource fork and `st_size` does not, so a file carrying
    /// one is the regression guard for having picked the right size attribute.
    func testResourceForkedFileReportsDataForkSize() throws {
        let fixture = try makeFixture("bulk-fork")
        let options = try fixture.options()
        fixture.warmUp(options: options)
        let bulk = try capture(BulkVolumeWalker(), fixture.tree.root, options)

        let forked = try XCTUnwrap(bulk.entries.first { $0.url.lastPathComponent == "forked.bin" })
        let status = try FileIdentity.lstatPath(forked.url)
        XCTAssertEqual(forked.identity.size, Int64(status.st_size))
        XCTAssertEqual(forked.identity.size, 100, "the data fork, not data plus resource fork")
        XCTAssertGreaterThan(
            forked.allocatedSize,
            0,
            "allocated size still covers both forks, matching totalFileAllocatedSizeKey"
        )
    }

    func testSymlinkedDirectoryIsNeverDescended() throws {
        let fixture = try makeFixture("bulk-symlink")
        let options = try fixture.options()
        fixture.warmUp(options: options)
        let bulk = try capture(BulkVolumeWalker(), fixture.tree.root, options)

        let link = try XCTUnwrap(bulk.entries.first { $0.url.lastPathComponent == "link-to-dir" })
        XCTAssertEqual(link.identity.kind, .symbolicLink)
        XCTAssertFalse(
            bulk.paths.contains { $0.contains("/link-to-dir/") },
            "a symlink to a directory must not be walked through"
        )
        XCTAssertEqual(
            bulk.entries.filter { $0.url.lastPathComponent == "l2.bin" }.count,
            1,
            "the linked directory's contents must appear exactly once, under their real path"
        )
    }

    func testHardLinkedPairSharesOneInode() throws {
        let fixture = try makeFixture("bulk-hardlink")
        let options = try fixture.options()
        fixture.warmUp(options: options)
        let bulk = try capture(BulkVolumeWalker(), fixture.tree.root, options)

        let linked = bulk.entries.filter { $0.identity.isHardLinked }
        XCTAssertEqual(linked.count, 2)
        XCTAssertEqual(Set(linked.map(\.identity.inode)).count, 1)
        XCTAssertTrue(linked.allSatisfy { $0.identity.linkCount == 2 })
    }

    // MARK: - Root gates

    func testRootMustBeADirectory() throws {
        let tree = try TempTree("bulk-root-file")
        let file = try tree.write("payload.bin", bytes: 8)
        let volume = try VolumeIdentity.read(at: file)
        XCTAssertThrowsError(
            try BulkVolumeWalker().walk(root: file, options: WalkOptions(boundary: volume)) { _ in .continue }
        ) { error in
            XCTAssertEqual(error as? WalkError, .rootNotADirectory(file))
        }
    }

    func testRootOnAnotherVolumeIsRefused() throws {
        let tree = try TempTree("bulk-root-volume")
        let real = try VolumeIdentity.read(at: tree.root)
        let foreign = VolumeIdentity(deviceID: real.deviceID &+ 1, uuid: nil)
        XCTAssertThrowsError(
            try BulkVolumeWalker().walk(root: tree.root, options: WalkOptions(boundary: foreign)) { _ in .continue }
        ) { error in
            XCTAssertEqual(error as? WalkError, .rootOnDifferentVolume(tree.root))
        }
    }

    /// Both backends treat a refused directory as an issue and keep going, including when it is
    /// the root itself; losing an entire scan to one unreadable folder is never acceptable.
    func testUnreadableRootIsRecordedNotThrown() throws {
        let tree = try TempTree("bulk-root-locked")
        try tree.write("inside.bin", bytes: 4)
        let volume = try VolumeIdentity.read(at: tree.root)
        XCTAssertEqual(chmod(tree.root.path, 0o000), 0)
        addTeardownBlock { _ = chmod(tree.root.path, 0o755) }

        let options = WalkOptions(boundary: volume)
        let bulk = try capture(BulkVolumeWalker(), tree.root, options)
        let reference = try capture(FileManagerVolumeWalker(), tree.root, options)

        XCTAssertTrue(bulk.entries.isEmpty)
        XCTAssertTrue(reference.entries.isEmpty)
        XCTAssertEqual(bulk.issueTags, reference.issueTags)
        XCTAssertEqual(bulk.issueTags.first?.kind, "unreadable")
    }

    // MARK: - Engine wiring

    func testDefaultWalkerIsBulkUnlessTheEscapeHatchIsSet() {
        XCTAssertTrue(ScanEngine.defaultWalker(environment: [:]) is BulkVolumeWalker)
        XCTAssertTrue(ScanEngine.defaultWalker(environment: ["SWEEP_WALKER": "filemanager"]) is FileManagerVolumeWalker)
        XCTAssertTrue(ScanEngine.defaultWalker(environment: ["SWEEP_WALKER": "FileManager"]) is FileManagerVolumeWalker)
        XCTAssertTrue(ScanEngine.defaultWalker(environment: ["SWEEP_WALKER": "bulk"]) is BulkVolumeWalker)
    }

    // MARK: - Comparison

    @discardableResult
    private func assertParity(
        _ fixture: Fixture,
        options: WalkOptions,
        decide: (WalkEntry, Int) -> WalkDirective = { _, _ in .continue },
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> (bulk: Capture, reference: Capture) {
        // Reading a directory advances its atime once, after which APFS leaves it alone. One
        // throwaway pass settles every directory in the tree so the two measured walks observe
        // the same `contentAccessDate`.
        fixture.warmUp(options: options)

        let bulk = try capture(BulkVolumeWalker(), fixture.tree.root, options, decide: decide)
        let reference = try capture(FileManagerVolumeWalker(), fixture.tree.root, options, decide: decide)

        // Guards the per-path comparison below against passing vacuously on an empty walk.
        XCTAssertGreaterThan(reference.entries.count, 5, "the fixture walk produced almost nothing", file: file, line: line)
        XCTAssertFalse(reference.issues.isEmpty, "the locked directory should always raise an issue", file: file, line: line)

        XCTAssertEqual(bulk.stopped, reference.stopped, "stopped flag", file: file, line: line)
        XCTAssertEqual(bulk.paths, reference.paths, "emitted path sets differ", file: file, line: line)
        XCTAssertEqual(bulk.issueTags, reference.issueTags, "issue sets differ", file: file, line: line)

        for (path, expected) in reference.byPath {
            guard let actual = bulk.byPath[path] else { continue }
            let name = (path as NSString).lastPathComponent
            XCTAssertEqual(actual.identity, expected.identity, "identity: \(name)", file: file, line: line)
            XCTAssertEqual(actual.allocatedSize, expected.allocatedSize, "allocatedSize: \(name)", file: file, line: line)
            XCTAssertEqual(actual.depth, expected.depth, "depth: \(name)", file: file, line: line)
            XCTAssertEqual(actual.parentIdentity, expected.parentIdentity, "parentIdentity: \(name)", file: file, line: line)
            XCTAssertEqual(
                actual.contentAccessDate,
                expected.contentAccessDate,
                "contentAccessDate: \(name)",
                file: file,
                line: line
            )
        }

        assertParentsPrecedeChildren(bulk, label: "bulk", file: file, line: line)
        assertParentsPrecedeChildren(reference, label: "filemanager", file: file, line: line)
        try assertIdentitiesRevalidate(bulk, volume: options.boundary, file: file, line: line)
        return (bulk, reference)
    }

    private func assertParentsPrecedeChildren(
        _ capture: Capture,
        label: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        var position: [String: Int] = [:]
        for (index, entry) in capture.entries.enumerated() { position[entry.url.path] = index }
        for (index, entry) in capture.entries.enumerated() {
            let parent = entry.url.deletingLastPathComponent().path
            guard let parentIndex = position[parent] else { continue }
            XCTAssertLessThan(
                parentIndex,
                index,
                "\(label): \(entry.url.lastPathComponent) was emitted before its parent",
                file: file,
                line: line
            )
        }
    }

    private func assertIdentitiesRevalidate(
        _ capture: Capture,
        volume: VolumeIdentity,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for entry in capture.entries {
            let fresh = try FileIdentity.read(at: entry.url, volume: volume)
            XCTAssertEqual(
                entry.identity,
                fresh,
                "captured identity drifted from a fresh lstat: \(entry.url.lastPathComponent)",
                file: file,
                line: line
            )
        }
    }

    // MARK: - Capture

    struct Capture {
        var entries: [WalkEntry] = []
        var issues: [WalkIssue] = []
        var stopped = false

        var paths: Set<String> { Set(entries.map(\.url.path)) }
        var byPath: [String: WalkEntry] {
            Dictionary(entries.map { ($0.url.path, $0) }, uniquingKeysWith: { first, _ in first })
        }
        /// Issues compared by location and kind. The human-readable reason is a localized
        /// Foundation string on one backend and `strerror` on the other, and never load-bearing.
        var issueTags: Set<Pair> {
            Set(issues.map { Pair($0.url.path, tag(of: $0.reason)) })
        }
    }

    /// `Set` of tuples is not expressible, and a two-field box keeps the diff on a failure
    /// readable.
    struct Pair: Hashable, CustomStringConvertible {
        let path: String
        let kind: String
        init(_ path: String, _ kind: String) {
            self.path = path
            self.kind = kind
        }
        var description: String { "\(kind)@\((path as NSString).lastPathComponent)" }
    }

    private func capture(
        _ walker: some VolumeWalker,
        _ root: URL,
        _ options: WalkOptions,
        decide: (WalkEntry, Int) -> WalkDirective = { _, _ in .continue }
    ) throws -> Capture {
        var result = Capture()
        let summary = try walker.walk(root: root, options: options) { entry in
            let directive = decide(entry, result.entries.count)
            result.entries.append(entry)
            return directive
        }
        result.issues = summary.issues
        result.stopped = summary.stopped
        return result
    }

    // MARK: - Fixture

    struct Fixture {
        let tree: TempTree

        func options(
            maximumDepth: Int? = nil,
            includesDirectories: Bool = true
        ) throws -> WalkOptions {
            WalkOptions(
                boundary: try VolumeIdentity.read(at: tree.root),
                maximumDepth: maximumDepth,
                includesDirectories: includesDirectories
            )
        }

        func warmUp(options: WalkOptions) {
            _ = try? BulkVolumeWalker().walk(root: tree.root, options: options) { _ in .continue }
        }
    }

    /// Everything the two backends could plausibly disagree about, in one tree: five levels of
    /// nesting, an empty directory, both flavours of symlink, a hard-linked pair, a dotfile,
    /// unicode and spaces in names, a zero-byte file, a `chflags`-marked file, a file with a
    /// resource fork, and a directory nobody may read.
    private func makeFixture(_ label: String) throws -> Fixture {
        let tree = try TempTree(label)

        try tree.write("top.bin", bytes: 1000)
        try tree.write("empty.bin", bytes: 0)
        try tree.write(".dotfile", bytes: 12)
        try tree.write("üñí çödé ñâmé.txt", bytes: 77)
        try tree.write("a spaced name.log", contents: "line one\nline two\n")

        let flagged = try tree.write("flagged.bin", bytes: 10)
        XCTAssertEqual(chflags(flagged.path, UInt32(UF_HIDDEN)), 0)

        let forked = try tree.write("forked.bin", bytes: 100)
        try Data(repeating: 0x46, count: 64).write(to: forked.appending(path: "..namedfork/rsrc"))

        try tree.write("hard-a.bin", bytes: 4096)
        try tree.hardLink(from: "hard-a.bin", to: "links/hard-b.bin")

        try tree.makeDirectory("empty-dir")
        try tree.write("level1/l1.bin", bytes: 20)
        try tree.write("level1/level2/l2.bin", bytes: 30)
        try tree.write("level1/level2/level3/l3.bin", bytes: 40)
        try tree.write("level1/level2/level3/level4/l4.bin", bytes: 50)

        try tree.write("skippable/inside-a.bin", bytes: 60)
        try tree.write("skippable/nested/inside-b.bin", bytes: 70)

        try FileManager.default.createSymbolicLink(
            at: tree.url("link-to-file"),
            withDestinationURL: tree.url("top.bin")
        )
        try FileManager.default.createSymbolicLink(
            at: tree.url("link-to-dir"),
            withDestinationURL: tree.url("level1/level2")
        )

        try tree.write("locked/unreachable.bin", bytes: 8)
        XCTAssertEqual(chmod(tree.url("locked").path, 0o000), 0)
        // Restored before `TempTree`'s deinit gets a chance to fail on it: this block holds the
        // last strong reference to the tree, so the chmod always lands first.
        addTeardownBlock {
            _ = chmod(tree.url("locked").path, 0o755)
            _ = chflags(flagged.path, 0)
        }

        return Fixture(tree: tree)
    }
}

private func tag(of reason: WalkIssue.Reason) -> String {
    switch reason {
    case .unreadable: "unreadable"
    case .identityUnavailable: "identityUnavailable"
    case .volumeBoundary: "volumeBoundary"
    case .policyDenied: "policyDenied"
    }
}
