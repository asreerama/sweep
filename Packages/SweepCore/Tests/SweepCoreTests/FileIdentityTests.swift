import Darwin
import XCTest
@testable import SweepCore

/// Review finding #5: device + inode + type + nlink + mtime was not enough to prove a file is
/// unchanged, and the parent identity the scan captured was thrown away when the plan was built.
final class FileIdentityTests: XCTestCase {

    func testCaptureIncludesStatusChangeSizeAndFlags() throws {
        let tree = try TempTree("identity-capture")
        let file = try tree.write("payload.bin", bytes: 321)

        let identity = try FileIdentity.read(at: file)
        XCTAssertEqual(identity.size, 321)
        XCTAssertGreaterThan(identity.statusChange.seconds, 0)
        XCTAssertEqual(identity.flags, 0)
        XCTAssertEqual(identity.kind, .file)
    }

    func testUnchangedRejectsEachIndependentDifference() throws {
        let base = Self.identity()
        XCTAssertTrue(base.isUnchanged(from: base))

        XCTAssertFalse(base.isUnchanged(from: Self.identity(statusChange: FileTimestamp(seconds: 2, nanoseconds: 0))))
        XCTAssertFalse(base.isUnchanged(from: Self.identity(size: 999)))
        XCTAssertFalse(base.isUnchanged(from: Self.identity(flags: UInt32(UF_IMMUTABLE))))
        XCTAssertFalse(base.isUnchanged(from: Self.identity(linkCount: 2)))
        XCTAssertFalse(base.isUnchanged(from: Self.identity(modification: FileTimestamp(seconds: 5, nanoseconds: 0))))

        // Same object throughout: `isSameFile` stays true where `isUnchanged` does not.
        XCTAssertTrue(base.isSameFile(as: Self.identity(size: 999)))
    }

    func testChangingImmutableFlagsIsDetected() throws {
        let tree = try TempTree("identity-flags")
        let file = try tree.write("locked.bin", bytes: 16)
        let before = try FileIdentity.read(at: file)

        guard file.path.withCString({ chflags($0, UInt32(UF_HIDDEN)) }) == 0 else {
            throw XCTSkip("chflags unavailable on this volume")
        }
        defer { _ = file.path.withCString { chflags($0, 0) } }

        let after = try FileIdentity.read(at: file)
        XCTAssertTrue(after.isSameFile(as: before))
        XCTAssertFalse(after.isUnchanged(from: before), "st_flags is part of the identity")
    }

    /// A journal written before the three new fields existed must still replay: the record is
    /// versioned, and a per-field default is cheaper than bumping the whole format.
    func testDecodingAJournalWrittenWithoutTheNewFieldsStillWorks() throws {
        let json = """
        {"deviceID":16777233,"inode":42,"kind":"file","linkCount":1,\
        "modification":{"nanoseconds":7,"seconds":1700000000},\
        "volume":{"deviceID":16777233}}
        """
        let identity = try JSONDecoder().decode(FileIdentity.self, from: Data(json.utf8))

        XCTAssertEqual(identity.inode, 42)
        XCTAssertEqual(identity.statusChange, .zero)
        XCTAssertEqual(identity.size, 0)
        XCTAssertEqual(identity.flags, 0)
    }

    func testRoundTripPreservesTheNewFields() throws {
        let identity = Self.identity(statusChange: FileTimestamp(seconds: 9, nanoseconds: 8), size: 77, flags: 2)
        let data = try JSONEncoder().encode(identity)
        XCTAssertEqual(try JSONDecoder().decode(FileIdentity.self, from: data), identity)
    }

    /// The scan captured a parent identity and `DeletionItem(candidate:...)` used to drop it on
    /// the floor. It is now carried into the plan, into the journal, and into the descent.
    func testPlanItemKeepsTheScannedParentIdentity() throws {
        let parent = Self.identity(inode: 7)
        let candidate = ScanCandidate(
            url: URL(fileURLWithPath: "/fixture/caches/blob.bin"),
            identity: Self.identity(inode: 8),
            parentIdentity: parent,
            allocatedSize: 4096,
            ruleID: "user.caches.app"
        )

        let item = DeletionItem(candidate: candidate, action: .delete, tier: .safe)
        XCTAssertEqual(item.parentIdentity, parent)
        XCTAssertEqual(item.journalItem.parentIdentity, parent, "and it reaches the log, for recovery")
    }

    static func identity(
        inode: UInt64 = 1,
        kind: FileKind = .file,
        linkCount: Int = 1,
        modification: FileTimestamp = FileTimestamp(seconds: 1, nanoseconds: 0),
        statusChange: FileTimestamp = FileTimestamp(seconds: 1, nanoseconds: 0),
        size: Int64 = 100,
        flags: UInt32 = 0
    ) -> FileIdentity {
        FileIdentity(
            deviceID: 16_777_233,
            inode: inode,
            volume: VolumeIdentity(deviceID: 16_777_233, uuid: nil),
            kind: kind,
            linkCount: linkCount,
            modification: modification,
            statusChange: statusChange,
            size: size,
            flags: flags
        )
    }
}
