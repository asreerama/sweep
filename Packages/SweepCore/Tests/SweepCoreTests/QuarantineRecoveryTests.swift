import XCTest
@testable import SweepCore

/// Codex G1 finding #5: "recovery scan surfaces stranded quarantine slots."
final class QuarantineRecoveryTests: XCTestCase {

    func testStrandedSlotWithContentIsSurfaced() throws {
        let tree = try TempTree("quarantine-recovery-stranded")
        let root = tree.root
        let operationID = UUID()
        let slotDirectory = root
            .appending(path: FileDescriptorExecutor.quarantineDirectoryName)
            .appending(path: operationID.uuidString)
            .appending(path: "16777234-4242")
        try FileManager.default.createDirectory(at: slotDirectory, withIntermediateDirectories: true)
        try Data("stuck".utf8).write(to: slotDirectory.appending(path: "stuck.bin"))

        let stranded = QuarantineRecovery.strandedSlots(under: root)

        XCTAssertEqual(stranded.count, 1)
        XCTAssertEqual(stranded.first?.operationID, operationID)
        XCTAssertEqual(stranded.first?.itemURL.lastPathComponent, "stuck.bin")
        XCTAssertEqual(stranded.first?.slotURL.lastPathComponent, "16777234-4242")
    }

    /// An empty slot means a trash or a rollback succeeded and only the final `rmdir` lagged
    /// (or never ran) — it is not stranded content, so it must not be reported as such.
    func testEmptySlotIsNotReportedAsStranded() throws {
        let tree = try TempTree("quarantine-recovery-empty")
        let root = tree.root
        let slotDirectory = root
            .appending(path: FileDescriptorExecutor.quarantineDirectoryName)
            .appending(path: UUID().uuidString)
            .appending(path: "1-1")
        try FileManager.default.createDirectory(at: slotDirectory, withIntermediateDirectories: true)

        XCTAssertTrue(QuarantineRecovery.strandedSlots(under: root).isEmpty)
    }

    func testNoQuarantineDirectoryAtAllYieldsNoStrandedSlots() throws {
        let tree = try TempTree("quarantine-recovery-none")
        XCTAssertTrue(QuarantineRecovery.strandedSlots(under: tree.root).isEmpty)
    }

    /// Codex G1 finding #8: `.skipsHiddenFiles` made a stranded *dotfile* slot look empty, because
    /// the enumerator never reported the one entry actually inside it. A cache item whose own name
    /// starts with `.` is exactly the shape that ends up renamed into a quarantine slot. The
    /// slot's directory name (`<device>-<inode>`) is never hidden, but its content can be.
    func testStrandedSlotHoldingOnlyAHiddenItemIsSurfaced() throws {
        let tree = try TempTree("quarantine-recovery-hidden-item")
        let root = tree.root
        let operationID = UUID()
        let slotDirectory = root
            .appending(path: FileDescriptorExecutor.quarantineDirectoryName)
            .appending(path: operationID.uuidString)
            .appending(path: "16777234-9999")
        try FileManager.default.createDirectory(at: slotDirectory, withIntermediateDirectories: true)
        try Data("stuck".utf8).write(to: slotDirectory.appending(path: ".hidden-cache-item"))

        let stranded = QuarantineRecovery.strandedSlots(under: root)

        XCTAssertEqual(stranded.count, 1, "a hidden stranded item must not be reported as an empty (recovered) slot")
        XCTAssertEqual(stranded.first?.itemURL.lastPathComponent, ".hidden-cache-item")
    }

    /// Codex G1 finding #8 residual: the startup sweep only ever covered the symbolic operation
    /// roots, never the code-sign-clone detector's external `X` root. A real trash operation can
    /// strand a slot there exactly as easily as under `.userCaches`.
    func testAllAnchorsIncludesTheCodeSignCloneRoot() throws {
        let anchors = QuarantineRecovery.allAnchors()
        let cloneRoot = try? CodeSignCloneDetector.resolveCloneDirectory()
        guard let cloneRoot else {
            throw XCTSkip("code-sign-clone root not resolvable in this environment")
        }
        XCTAssertTrue(
            anchors.contains(cloneRoot),
            "allAnchors() must cover the code-sign-clone root, not just the symbolic operation roots"
        )
    }
}
