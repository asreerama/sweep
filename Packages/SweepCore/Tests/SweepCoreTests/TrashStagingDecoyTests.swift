import XCTest
@testable import SweepCore

/// Codex G1 finding #3 (CRITICAL): `FileManager.trashItem` returning without throwing was treated
/// as proof the leaf left the quarantine slot. `OpenDirectory.path` is only a cached spelling,
/// never authoritative for a mutation, so a decoy success (the API reports success while the
/// object never actually left the slot this process holds open by descriptor) used to be reported
/// as a clean trash. `TrashStaging.trash`'s `performTrashItem:` parameter is a test-only seam that
/// lets these tests substitute a stand-in for the real Trash API, so the decoy can be proven
/// deterministically instead of depending on ever coaxing the real API into that behavior.
final class TrashStagingDecoyTests: XCTestCase {

    func testDecoySuccessIsDetectedAndReportedAsStrandedNeverAsAPlainSuccess() throws {
        let fixture = try TempTree("trash-decoy")
        let file = try fixture.write("caches/decoy.bin", bytes: 32)
        let root = try OpenDirectory.openRoot(fixture.root)
        let operationDirectory = try Self.makeOperationDirectory(under: root)
        let request = try Self.request(for: file, relativeTo: fixture.root)

        // Reports success (throws nothing, hands back a plausible restore URL) without actually
        // removing the leaf from the slot: the exact decoy this finding is about. The real
        // `FileManager.trashItem` is never called in this test.
        XCTAssertThrowsError(
            try TrashStaging.trash(
                request: request, anchoredAt: root, operationQuarantine: operationDirectory,
                performTrashItem: { url in URL(fileURLWithPath: "/Users/tester/.Trash/\(url.lastPathComponent)") }
            )
        ) { error in
            guard let descriptorError = error as? FileDescriptorError,
                  case .strandedInQuarantine(let quarantinePath, let underlyingReason, let rollbackReason) = descriptorError
            else {
                return XCTFail("expected strandedInQuarantine for a decoy success, got \(error)")
            }
            XCTAssertTrue(underlyingReason.contains("still"), underlyingReason)
            XCTAssertTrue(rollbackReason.contains("deliberately not attempted"), rollbackReason)
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: quarantinePath),
                "the leaf must still be physically present at the reported slot location, never silently lost track of"
            )
        }
    }

    /// A well-behaved trash stand-in (one that actually removes the leaf, mirroring what
    /// `FileManager.trashItem` really does) must still be reported as a normal success. The fix
    /// must not turn every trash into a false stranding.
    func testGenuineTrashSuccessIsReportedNormally() throws {
        let fixture = try TempTree("trash-genuine")
        let file = try fixture.write("caches/real.bin", bytes: 32)
        let root = try OpenDirectory.openRoot(fixture.root)
        let operationDirectory = try Self.makeOperationDirectory(under: root)
        let request = try Self.request(for: file, relativeTo: fixture.root)
        let fakeTrashURL = URL(fileURLWithPath: "/Users/tester/.Trash/real.bin")

        let result = try TrashStaging.trash(
            request: request, anchoredAt: root, operationQuarantine: operationDirectory,
            performTrashItem: { url in
                try FileManager.default.removeItem(at: url)
                return fakeTrashURL
            }
        )

        XCTAssertEqual(result, fakeTrashURL)
    }

    // MARK: - Helpers

    private static func makeOperationDirectory(under root: OpenDirectory) throws -> OpenDirectory {
        try root.makeChildDirectory(FileDescriptorExecutor.quarantineDirectoryName)
        let quarantine = try root.openChildDirectory(FileDescriptorExecutor.quarantineDirectoryName)
        let name = UUID().uuidString
        try quarantine.makeChildDirectoryExclusive(name)
        return try quarantine.openChildDirectory(name)
    }

    private static func request(for file: URL, relativeTo root: URL) throws -> MutationRequest {
        let identity = try FileIdentity.read(at: file)
        guard let components = FileDescriptorPath.relativeComponents(of: file, under: root) else {
            throw XCTSkip("could not compute relative components for the fixture file")
        }
        return MutationRequest(url: file, relativeComponents: components, expected: identity, expectedParent: nil)
    }
}

extension TrashStagingDecoyTests {
    /// Codex G1 verdict 3: a *different* occupant at the slot leaf after a claimed success used
    /// to slip through (`try?` + isSameFile treated "present but different" as absence). Any
    /// occupant is indeterminate and must be reported as stranded, never success.
    func testDifferentOccupantAfterTrashIsNeverReportedAsSuccess() throws {
        let fixture = try TempTree("trash-decoy-swap")
        let file = try fixture.write("caches/original.bin", bytes: 32)
        let root = try OpenDirectory.openRoot(fixture.root)
        let operationDirectory = try Self.makeOperationDirectory(under: root)
        let request = try Self.request(for: file, relativeTo: fixture.root)

        XCTAssertThrowsError(
            try TrashStaging.trash(
                request: request, anchoredAt: root, operationQuarantine: operationDirectory,
                performTrashItem: { url in
                    // "Trash" the object, then plant a decoy at the same slot path before the
                    // executor's post-trash verification runs.
                    try FileManager.default.removeItem(at: url)
                    try Data(repeating: 0xAB, count: 16).write(to: url)
                    return URL(fileURLWithPath: "/Users/tester/.Trash/\(url.lastPathComponent)")
                }
            )
        ) { error in
            guard let descriptorError = error as? FileDescriptorError,
                  case .strandedInQuarantine = descriptorError
            else {
                return XCTFail("expected strandedInQuarantine for a swapped occupant, got \(error)")
            }
        }
    }
}
