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
        // A REAL move, not an unlink-plus-fabricated-URL: the post-trash Trash-entry identity
        // verification (Codex Gate-U re-review #3) checks that the object at the reported URL is
        // the reviewed device+inode, so the simulated Trash must behave like the real one — same
        // object, new location.
        let simulatedTrash = fixture.root.appending(path: "simulated-trash-real.bin")

        let result = try TrashStaging.trash(
            request: request, anchoredAt: root, operationQuarantine: operationDirectory,
            performTrashItem: { url in
                try FileManager.default.moveItem(at: url, to: simulatedTrash)
                return simulatedTrash
            }
        )

        XCTAssertEqual(result, simulatedTrash)
    }

    /// Codex Gate-U re-review blocker #3: `trashItem` "succeeding" while the object at the
    /// reported Trash URL is NOT the reviewed one (a substitution in the pathname hop) must be
    /// refused, never reported as success for the reviewed item.
    func testTrashEntryIdentityMismatchIsRefusedNotReportedAsSuccess() throws {
        let fixture = try TempTree("trash-substituted")
        let file = try fixture.write("caches/real.bin", bytes: 32)
        let imposter = try fixture.write("imposter.bin", bytes: 32)
        let root = try OpenDirectory.openRoot(fixture.root)
        let operationDirectory = try Self.makeOperationDirectory(under: root)
        let request = try Self.request(for: file, relativeTo: fixture.root)

        XCTAssertThrowsError(try TrashStaging.trash(
            request: request, anchoredAt: root, operationQuarantine: operationDirectory,
            performTrashItem: { url in
                // The reviewed object leaves the slot (attacker relocates it), and the URL the
                // "Trash" reports back holds a different inode entirely.
                try FileManager.default.removeItem(at: url)
                return imposter
            }
        )) { error in
            guard case FileDescriptorError.trashedObjectMismatch = error else {
                return XCTFail("expected trashedObjectMismatch, got \(error)")
            }
        }
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

// MARK: - Deep staged-tree validation (Codex Gate-U re-review blocker #2)

extension TrashStagingDecoyTests {
    /// A directory whose staged tree contains an inode registered as protected must refuse the
    /// trash and roll the staging back — verified against an injected identity set, so the test
    /// never touches the real user's protected areas.
    func testProtectedInodeInsideStagedTreeIsDetected() throws {
        let fixture = try TempTree("deep-protected")
        _ = try fixture.write("victim/nested/data.bin", bytes: 16)
        let protectedEntry = try fixture.write("victim/nested/protected-marker", bytes: 8)
        let identity = try FileIdentity.read(at: protectedEntry)

        let violation = DeepTreeValidator.firstViolation(
            inTreeAt: fixture.root.appending(path: "victim").path,
            expectedDevice: identity.deviceID,
            protectedIdentities: [identity.deviceID: [identity.inode]]
        )
        XCTAssertNotNil(violation)
        XCTAssertTrue(violation?.contains("protected location") == true, violation ?? "nil")

        // The same tree with no protected registration is clean.
        XCTAssertNil(DeepTreeValidator.firstViolation(
            inTreeAt: fixture.root.appending(path: "victim").path,
            expectedDevice: identity.deviceID,
            protectedIdentities: [:]
        ))
    }
}
