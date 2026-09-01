import CryptoKit
import XCTest
@testable import SweepCore

/// Codex G1 finding #2 (CRITICAL): `loadPinnedBundledCatalog()` used to pin only a mutable
/// directory URL, read `catalog.json` twice per call (once for the digest, once to decode), and
/// re-read it fresh from disk on every call. None of that is "pinned" in any sense that survives
/// a symlink swap or a rewrite between calls.
final class BundledCatalogSourceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CleanService.resetBundledCatalogDirectoryForTesting()
    }

    override func tearDown() {
        CleanService.resetBundledCatalogDirectoryForTesting()
        super.tearDown()
    }

    /// `Data(contentsOf:)` (the old implementation) follows a symlink transparently. The fixed
    /// implementation opens `catalog.json` with `openat(..., O_NOFOLLOW)` relative to a directory
    /// descriptor, so a symlink planted at that name must be refused, never followed.
    func testLoadRefusesASymlinkedCatalogFile() throws {
        let tree = try TempTree("bundled-catalog-symlink")
        let directory = try tree.makeDirectory("rules")
        try Data("{}".utf8).write(to: directory.appending(path: "schema.json"))

        let realCatalog = tree.url("real-catalog.json")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.symlink.catalog", tier: .safe)
        try JSONEncoder().encode(RuleCatalog(rules: [rule])).write(to: realCatalog)
        try FileManager.default.createSymbolicLink(
            at: directory.appending(path: "catalog.json"), withDestinationURL: realCatalog
        )

        CleanService.configureBundledCatalogDirectory(directory)

        XCTAssertThrowsError(try CleanService.loadPinnedBundledCatalog()) { error in
            guard case .unreadable = error as? RuleCatalogError else {
                return XCTFail("expected RuleCatalogError.unreadable for a symlinked catalog.json, got \(error)")
            }
        }
    }

    /// The core of the fix: once a load succeeds, the catalog and its digest are cached for the
    /// life of the process. A later on-disk rewrite of `catalog.json` must never change what a
    /// second call returns, proving the pin is real, not merely a re-read of the same pathname
    /// that happens to not have changed yet.
    func testLoadPinsTheCatalogSoALaterOnDiskRewriteIsNeverObserved() throws {
        let tree = try TempTree("bundled-catalog-pin")
        let directory = try tree.makeDirectory("rules")
        try Data("{}".utf8).write(to: directory.appending(path: "schema.json"))

        let firstRule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.pin.first", tier: .safe)
        try JSONEncoder().encode(RuleCatalog(rules: [firstRule])).write(to: directory.appending(path: "catalog.json"))
        CleanService.configureBundledCatalogDirectory(directory)

        let firstLoad = try CleanService.loadPinnedBundledCatalog()
        XCTAssertNotNil(firstLoad.catalog[id: firstRule.id])

        // Rewrite catalog.json in place, in the exact same file, with materially different bytes
        // and a different rule id.
        let secondRule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.pin.second", tier: .safe)
        try JSONEncoder().encode(RuleCatalog(rules: [secondRule])).write(to: directory.appending(path: "catalog.json"))

        let secondLoad = try CleanService.loadPinnedBundledCatalog()
        XCTAssertEqual(secondLoad.sha256Hex, firstLoad.sha256Hex, "the digest must never change within a process lifetime")
        XCTAssertNotNil(secondLoad.catalog[id: firstRule.id], "the cached catalog must still be the first one decoded")
        XCTAssertNil(secondLoad.catalog[id: secondRule.id], "the on-disk rewrite must never be observed once pinned")
    }

    /// The digest must describe exactly the bytes that were decoded: the two-read gap the old
    /// implementation had (one read for the digest, a separate one for the decode).
    func testDigestMatchesTheExactBytesDecoded() throws {
        let tree = try TempTree("bundled-catalog-digest")
        let directory = try tree.makeDirectory("rules")
        try Data("{}".utf8).write(to: directory.appending(path: "schema.json"))
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.digest.match", tier: .safe)
        let bytes = try JSONEncoder().encode(RuleCatalog(rules: [rule]))
        try bytes.write(to: directory.appending(path: "catalog.json"))
        CleanService.configureBundledCatalogDirectory(directory)

        let pinned = try CleanService.loadPinnedBundledCatalog()
        let expectedDigest = SHA256Hex(bytes)
        XCTAssertEqual(pinned.sha256Hex, expectedDigest)
    }
}

private func SHA256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}
