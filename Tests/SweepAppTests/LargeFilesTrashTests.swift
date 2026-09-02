import XCTest
@testable import SweepApp
import SweepCore
import SweepUI

/// `LargeFilesModel.performTrash` — the identity discipline behind Large & Old Files' live
/// Move to Trash (user-directed wave: actionable results, including mid-scan). Same contract
/// as every other mutation in the app: the thing trashed must be the thing the scan showed.
@MainActor
final class LargeFilesTrashTests: XCTestCase {

    private func makeFixtureDirectory(_ name: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "large-files-trash-\(name)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func item(for url: URL, bytes: Int64) -> InventoryItem {
        InventoryItem(
            id: url.path, title: url.lastPathComponent, detail: url.path,
            symbol: "doc", byteCount: bytes, tier: .caution
        )
    }

    func testIdentityMatchedFileIsTrashedAndReported() throws {
        let dir = try makeFixtureDirectory("success")
        let file = dir.appending(path: "big.bin")
        try Data(repeating: 0x1, count: 64).write(to: file)
        let identity = try FileIdentity.read(at: file)

        let result = LargeFilesModel.performTrash(
            items: [item(for: file, bytes: 64)],
            identityByID: [file.path: identity]
        )

        XCTAssertEqual(result.trashedIDs, [file.path])
        XCTAssertEqual(result.freedBytes, 64)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(result.outcomes.first?.status, .succeeded)
    }

    func testIdentitySwapIsRefusedPerItemAndTouchesNothing() throws {
        let dir = try makeFixtureDirectory("swap")
        let file = dir.appending(path: "victim.bin")
        try Data(repeating: 0x1, count: 32).write(to: file)
        let reviewed = try FileIdentity.read(at: file)

        // A different object now wears the reviewed path's name.
        try FileManager.default.removeItem(at: file)
        try Data(repeating: 0x2, count: 32).write(to: file)

        let result = LargeFilesModel.performTrash(
            items: [item(for: file, bytes: 32)],
            identityByID: [file.path: reviewed]
        )

        XCTAssertTrue(result.trashedIDs.isEmpty)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.path),
            "the imposter must survive — only the reviewed object may be trashed"
        )
        guard case .failed(let reason)? = result.outcomes.first?.status else {
            return XCTFail("expected a per-item refusal")
        }
        XCTAssertTrue(reason.contains("changed or disappeared"), reason)
    }

    func testVanishedFileSettlesAsRefusalNotError() throws {
        let dir = try makeFixtureDirectory("vanish")
        let file = dir.appending(path: "gone.bin")
        try Data(repeating: 0x1, count: 16).write(to: file)
        let reviewed = try FileIdentity.read(at: file)
        try FileManager.default.removeItem(at: file)

        let result = LargeFilesModel.performTrash(
            items: [item(for: file, bytes: 16)],
            identityByID: [file.path: reviewed]
        )

        XCTAssertTrue(result.trashedIDs.isEmpty)
        XCTAssertEqual(result.freedBytes, 0)
        guard case .failed? = result.outcomes.first?.status else {
            return XCTFail("expected a settled per-item failure")
        }
    }
}
