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
}
