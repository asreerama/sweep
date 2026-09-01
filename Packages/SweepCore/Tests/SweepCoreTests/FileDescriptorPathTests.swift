import Darwin
import XCTest
@testable import SweepCore

/// Review finding #2: containment, revalidation and mutation used to be three pathname
/// operations with exploitable windows between them. These exercise the descriptor walk that
/// replaced them.
final class FileDescriptorPathTests: XCTestCase {

    func testDescentRefusesASymlinkedParent() throws {
        let tree = try TempTree("fd-symlink")
        try tree.write("real/file.bin", bytes: 16)
        try FileManager.default.createSymbolicLink(
            at: tree.url("link"),
            withDestinationURL: tree.url("real")
        )
        let root = try OpenDirectory.openRoot(tree.root)

        // The pathname `<root>/link/file.bin` names the same file as `<root>/real/file.bin`.
        // `O_NOFOLLOW` makes the difference visible instead of transparent.
        XCTAssertThrowsError(
            try FileDescriptorPath.descend(from: root, components: ["link", "file.bin"], expectedParent: nil)
        ) { error in
            XCTAssertEqual(error as? FileDescriptorError, .symlinkComponent(component: "link"))
        }

        let (parent, leaf) = try FileDescriptorPath.descend(
            from: root,
            components: ["real", "file.bin"],
            expectedParent: nil
        )
        XCTAssertEqual(leaf, "file.bin")
        XCTAssertEqual(try parent.identity().kind, .directory)
    }

    func testDescentRefusesAParentThatWasSwappedForAnotherDirectory() throws {
        let tree = try TempTree("fd-parent-swap")
        try tree.write("caches/file.bin", bytes: 16)
        let expectedParent = try FileIdentity.read(at: tree.url("caches"))

        // Same name, new inode: the directory the plan was built against is gone.
        try FileManager.default.removeItem(at: tree.url("caches"))
        try tree.write("caches/file.bin", bytes: 16)
        XCTAssertNotEqual(try FileIdentity.read(at: tree.url("caches")).inode, expectedParent.inode)

        let root = try OpenDirectory.openRoot(tree.root)
        XCTAssertThrowsError(
            try FileDescriptorPath.descend(
                from: root,
                components: ["caches", "file.bin"],
                expectedParent: expectedParent
            )
        ) { error in
            guard case .componentIdentityChanged = error as? FileDescriptorError else {
                return XCTFail("expected componentIdentityChanged, got \(error)")
            }
        }
    }

    func testRelativeComponentsRefuseEscapesAndTheRootItself() throws {
        let tree = try TempTree("fd-relative")
        let root = tree.root
        XCTAssertEqual(FileDescriptorPath.relativeComponents(of: root.appending(path: "a/b"), under: root), ["a", "b"])
        XCTAssertNil(FileDescriptorPath.relativeComponents(of: root, under: root))
        XCTAssertNil(FileDescriptorPath.relativeComponents(
            of: root.deletingLastPathComponent().appending(path: "sibling"),
            under: root
        ))
    }

    func testComponentValidationRejectsTraversalAndSeparators() {
        for bad in ["", ".", "..", "a/b"] {
            XCTAssertThrowsError(try OpenDirectory.validate(component: bad), "accepted \(bad)")
        }
        XCTAssertNoThrow(try OpenDirectory.validate(component: "ordinary.bin"))
    }

    /// The descriptor names an inode. Renaming the root out from under the executor cannot
    /// redirect anything, which is the whole point of anchoring it once.
    func testMutationFollowsTheAnchoredDescriptorNotThePathname() async throws {
        let parentTree = try TempTree("fd-anchor")
        let root = try parentTree.makeDirectory("root")
        let file = try parentTree.write("root/victim.bin", bytes: 64)
        let identity = try FileIdentity.read(at: file)
        let parentIdentity = try FileIdentity.read(at: root)

        let anchor = try OpenDirectory.openRoot(root)
        let executor = FileDescriptorExecutor(root: anchor, queue: BlockingIOQueue(label: "test.anchor"))

        // Move the root aside and put a decoy with the same name and the same layout in place.
        let moved = parentTree.url("moved")
        try FileManager.default.moveItem(at: root, to: moved)
        try parentTree.write("root/victim.bin", bytes: 64)
        let decoy = parentTree.url("root/victim.bin")

        try await executor.delete(MutationRequest(
            url: file,
            relativeComponents: ["victim.bin"],
            expected: identity,
            expectedParent: parentIdentity
        ))

        XCTAssertFalse(
            FileManager.default.fileExists(atPath: moved.appending(path: "victim.bin").path),
            "the anchored inode is what got unlinked"
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: decoy.path), "the decoy at the old pathname is untouched")
    }

    /// Review finding #3: directories are removed with `AT_REMOVEDIR`, which the kernel refuses
    /// on a non-empty directory. That is what makes "bottom-up" a guarantee and not a hope.
    func testRemoveChildDirectoryRefusesANonEmptyDirectory() throws {
        let tree = try TempTree("fd-rmdir")
        try tree.write("dir/occupied.bin", bytes: 8)
        let root = try OpenDirectory.openRoot(tree.root)

        XCTAssertThrowsError(try root.removeChildDirectory("dir")) { error in
            XCTAssertEqual((error as? FileDescriptorError)?.code, ENOTEMPTY)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: tree.url("dir").path))

        // Empty it the way the executor does, and only then does the directory go.
        let directory = try root.openChildDirectory("dir")
        try directory.unlinkChild("occupied.bin")
        XCTAssertNoThrow(try root.removeChildDirectory("dir"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: tree.url("dir").path))
    }

    func testChildNamesSkipsDotEntries() throws {
        let tree = try TempTree("fd-readdir")
        try tree.write("a.bin", bytes: 1)
        try tree.write("b.bin", bytes: 1)
        try tree.makeDirectory("c")
        let root = try OpenDirectory.openRoot(tree.root)

        XCTAssertEqual(Set(try root.childNames()), ["a.bin", "b.bin", "c"])
    }

    /// Review finding #16: mutation syscalls run on a dedicated serial queue, never on the
    /// cooperative pool.
    func testBlockingWorkRunsOnItsOwnQueue() async throws {
        let queue = BlockingIOQueue(label: "com.sweep.tests.blocking")
        let label = try await queue.run { String(cString: __dispatch_queue_get_label(nil)) }
        XCTAssertEqual(label, "com.sweep.tests.blocking")
    }
}
