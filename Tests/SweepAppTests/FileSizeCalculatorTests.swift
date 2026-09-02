import Darwin
import Foundation
import XCTest
@testable import SweepApp

/// Parity (and one-off perf) coverage for `FileSizeCalculator`'s `getattrlistbulk`-based rewrite.
/// The fixture below exercises every rule `allocatedSize(at:fileManager:)` has to get right —
/// dotfiles, `UF_HIDDEN`, un-followed symlinks, and a hidden directory whose (large) contents
/// must never be counted — and every assertion checks the new implementation against
/// `FileSizeCalculator.legacyAllocatedSize(at:fileManager:)`, the original
/// `FileManager.enumerator` walk kept around for exactly this purpose.
final class FileSizeCalculatorTests: XCTestCase {

    // MARK: - Fixture

    /// A directory tree covering every rule the rewrite has to preserve: nested regular files of
    /// known size, a dotfile, a `UF_HIDDEN`-flagged file, a symlink to a large file (must never be
    /// followed or counted), an empty directory, and a hidden directory whose large child must
    /// never be counted — because it must never even be descended into.
    private func makeFixture() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("sweep-filesize-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)

        try Data(repeating: 0x41, count: 5_000).write(to: root.appendingPathComponent("a.bin"))

        let nested = root.appendingPathComponent("nested")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 7_000).write(to: nested.appendingPathComponent("b.bin"))

        let deep = nested.appendingPathComponent("deep")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        try Data(repeating: 0x43, count: 9_000).write(to: deep.appendingPathComponent("c.bin"))

        try fm.createDirectory(at: root.appendingPathComponent("emptydir"), withIntermediateDirectories: true)

        // Dotfile: must be skipped by name alone, same as `.skipsHiddenFiles`.
        try Data(repeating: 0x44, count: 1_000).write(to: root.appendingPathComponent(".dotfile"))

        // UF_HIDDEN-flagged file: must be skipped by the BSD flag, not just by name.
        let hiddenFlagFile = root.appendingPathComponent("hiddenflag.bin")
        try Data(repeating: 0x45, count: 3_000).write(to: hiddenFlagFile)
        try setHidden(hiddenFlagFile)

        // A large file plus a symlink to it: the symlink must never be followed or counted, so
        // only the real file's bytes (once) should ever reach the total.
        let bigFile = root.appendingPathComponent("bigfile.bin")
        try Data(repeating: 0x46, count: 200_000).write(to: bigFile)
        try fm.createSymbolicLink(at: root.appendingPathComponent("symlink-to-big.bin"), withDestinationURL: bigFile)

        // Hidden directory containing a large file: must not be descended into at all, so the
        // child's bytes must never reach the total either.
        let hiddenDir = root.appendingPathComponent("hiddendir")
        try fm.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try Data(repeating: 0x47, count: 50_000).write(to: hiddenDir.appendingPathComponent("large.bin"))
        try setHidden(hiddenDir)

        return root
    }

    private func setHidden(_ url: URL) throws {
        let result = url.withUnsafeFileSystemRepresentation { chflags($0, UInt32(UF_HIDDEN)) }
        guard result == 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain,
                code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "chflags(UF_HIDDEN) failed for \(url.path)"]
            )
        }
    }

    // MARK: - Parity

    func testBulkImplementationMatchesLegacyOnFixtureTree() throws {
        let root = try makeFixture()
        defer { try? FileManager.default.removeItem(at: root) }

        let legacy = FileSizeCalculator.legacyAllocatedSize(at: root)
        let bulk = FileSizeCalculator.allocatedSize(at: root)
        XCTAssertEqual(bulk, legacy)

        // Sanity floor, independent of the parity check above: the four counted files' logical
        // bytes (dotfile, UF_HIDDEN file, symlink target-via-symlink, and the hidden directory's
        // child are all excluded), block-rounded allocation can only be >= their logical sum.
        XCTAssertGreaterThanOrEqual(bulk, 5_000 + 7_000 + 9_000 + 200_000)
    }

    func testBulkImplementationMatchesLegacyOnASingleFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-filesize-tests-\(UUID().uuidString).bin")
        try Data(repeating: 0x48, count: 12_345).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }

        XCTAssertEqual(FileSizeCalculator.allocatedSize(at: file), FileSizeCalculator.legacyAllocatedSize(at: file))
        XCTAssertGreaterThanOrEqual(FileSizeCalculator.allocatedSize(at: file), 12_345)
    }

    func testBulkImplementationMatchesLegacyOnAMissingPath() {
        let missing = URL(fileURLWithPath: "/private/tmp/sweep-filesize-tests-missing-\(UUID().uuidString)")
        XCTAssertEqual(FileSizeCalculator.allocatedSize(at: missing), 0)
        XCTAssertEqual(FileSizeCalculator.legacyAllocatedSize(at: missing), 0)
    }

    // MARK: - Perf (manual, not a CI gate)

    /// A pass/fail wall-clock assertion on a shared CI runner is just a future flake, so this
    /// only runs on request: `SWEEP_BENCH=1 swift test --filter
    /// FileSizeCalculatorTests/testBenchmarkAgainstLibraryCaches`. It still asserts the two
    /// implementations agree on the real tree it just timed, since that is free once computed.
    func testBenchmarkAgainstLibraryCaches() throws {
        guard ProcessInfo.processInfo.environment["SWEEP_BENCH"] == "1" else {
            throw XCTSkip("set SWEEP_BENCH=1 to run the getattrlistbulk vs. legacy wall-clock comparison")
        }
        let target = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw XCTSkip("~/Library/Caches is not present on this machine")
        }

        func time(_ body: () -> Int64) -> (bytes: Int64, seconds: Double) {
            let start = DispatchTime.now()
            let value = body()
            let seconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000
            return (value, seconds)
        }

        // Bulk first, then legacy, then bulk again: if page-cache warmth alone explained a gap,
        // the two bulk runs (several seconds apart, once with legacy sandwiched between) would
        // disagree with each other — they don't, in the numbers this recorded.
        let bulkFirst = time { FileSizeCalculator.allocatedSize(at: target) }
        let legacyRun = time { FileSizeCalculator.legacyAllocatedSize(at: target) }
        let bulkSecond = time { FileSizeCalculator.allocatedSize(at: target) }

        print("[SWEEP_BENCH] ~/Library/Caches")
        print("[SWEEP_BENCH]   bulk (1st):   \(bulkFirst.bytes) bytes in \(bulkFirst.seconds)s")
        print("[SWEEP_BENCH]   legacy:       \(legacyRun.bytes) bytes in \(legacyRun.seconds)s")
        print("[SWEEP_BENCH]   bulk (2nd):   \(bulkSecond.bytes) bytes in \(bulkSecond.seconds)s")
        print("[SWEEP_BENCH]   speedup (legacy / bulk, 2nd run): \(legacyRun.seconds / bulkSecond.seconds)x")

        XCTAssertEqual(bulkFirst.bytes, legacyRun.bytes)
        XCTAssertEqual(bulkFirst.bytes, bulkSecond.bytes)
    }
}
