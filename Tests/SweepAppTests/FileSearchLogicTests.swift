import XCTest
@testable import SweepApp

/// Pure logic behind `FileSearchScreen` (Toolbox, PLAN backlog promotion): query sanitization,
/// stdout parsing, cloud-path filtering, sort/merge/stability, and row-cap math. None of this
/// spawns `mdfind` or touches real Spotlight.
final class FileSearchLogicTests: XCTestCase {

    private func entry(_ name: String, bytes: Int64?, path: String = "/Users/tester/x") -> FileSearchEntry {
        FileSearchEntry(id: "\(path)/\(name)", name: name, parentPath: path, bytes: bytes)
    }

    // MARK: - Query sanitization / predicate

    func testSanitizeStripsQuotesAndBackslashes() {
        XCTAssertEqual(FileSearchLogic.sanitizeQuery("a\"b\\c"), "abc")
    }

    func testSanitizeLeavesOrdinaryCharactersAlone() {
        XCTAssertEqual(FileSearchLogic.sanitizeQuery("Invoice 2024.pdf"), "Invoice 2024.pdf")
    }

    func testPredicateRefusesEmptyQuery() {
        XCTAssertNil(FileSearchLogic.mdfindPredicate(forQuery: ""))
    }

    func testPredicateRefusesOneCharacterQuery() {
        XCTAssertNil(FileSearchLogic.mdfindPredicate(forQuery: "a"))
    }

    func testPredicateRefusesWhitespaceOnlyQuery() {
        XCTAssertNil(FileSearchLogic.mdfindPredicate(forQuery: "   "))
    }

    func testPredicateRefusesAQueryThatSanitizesBelowTheFloor() {
        // A quote-heavy query collapses to a single character once sanitized.
        XCTAssertNil(FileSearchLogic.mdfindPredicate(forQuery: "\"a\""))
    }

    func testPredicateWrapsTheQueryInTheFSNamePredicate() {
        XCTAssertEqual(FileSearchLogic.mdfindPredicate(forQuery: "invoice"), "kMDItemFSName == \"*invoice*\"c")
    }

    func testPredicateStripsQuotesAndBackslashesBeforeWrapping() {
        XCTAssertEqual(FileSearchLogic.mdfindPredicate(forQuery: "in\"vo\\ice"), "kMDItemFSName == \"*invoice*\"c")
    }

    func testPredicateTrimsSurroundingWhitespace() {
        XCTAssertEqual(FileSearchLogic.mdfindPredicate(forQuery: "  report  "), "kMDItemFSName == \"*report*\"c")
    }

    // MARK: - stdout parsing

    func testParsePathsSplitsOnNewlinesAndDropsEmptyLines() {
        let stdout = "/Users/a/one.txt\n/Users/a/two.txt\n\n"
        XCTAssertEqual(FileSearchLogic.parsePaths(stdout), ["/Users/a/one.txt", "/Users/a/two.txt"])
    }

    func testParsePathsOnEmptyStdoutIsEmpty() {
        XCTAssertTrue(FileSearchLogic.parsePaths("").isEmpty)
    }

    // MARK: - Hit cap

    func testCappedLimitsToMaxHits() {
        let paths = (0..<3000).map { "/Users/a/\($0)" }
        XCTAssertEqual(FileSearchLogic.capped(paths).count, FileSearchLogic.maxHits)
    }

    func testCappedLeavesAShorterListUntouched() {
        let paths = ["/a", "/b"]
        XCTAssertEqual(FileSearchLogic.capped(paths), paths)
    }

    // MARK: - Cloud-path filtering

    private let fakeHome = URL(fileURLWithPath: "/Users/tester")

    func testProtectedPrefixesCoverCloudStorageAndICloudDrive() {
        let prefixes = FileSearchLogic.protectedPrefixes(home: fakeHome)
        XCTAssertTrue(prefixes.contains("/Users/tester/Library/CloudStorage"))
        XCTAssertTrue(prefixes.contains("/Users/tester/Library/Mobile Documents"))
    }

    func testIsProtectedPathMatchesCloudDescendants() {
        let prefixes = FileSearchLogic.protectedPrefixes(home: fakeHome)
        XCTAssertTrue(FileSearchLogic.isProtectedPath(
            "/Users/tester/Library/CloudStorage/Dropbox/file.pdf", protectedPrefixes: prefixes
        ))
        XCTAssertTrue(FileSearchLogic.isProtectedPath(
            "/Users/tester/Library/Mobile Documents/com~apple~CloudDocs/x.txt", protectedPrefixes: prefixes
        ))
    }

    func testIsProtectedPathLeavesOrdinaryHomePathsAlone() {
        let prefixes = FileSearchLogic.protectedPrefixes(home: fakeHome)
        XCTAssertFalse(FileSearchLogic.isProtectedPath("/Users/tester/Downloads/movie.mp4", protectedPrefixes: prefixes))
        // File Search deliberately searches Documents/Desktop/Pictures (see FileSearchLogic's
        // `protectedPrefixes` doc comment) — only the two cloud-placeholder areas are excluded.
        XCTAssertFalse(FileSearchLogic.isProtectedPath("/Users/tester/Documents/resume.pdf", protectedPrefixes: prefixes))
    }

    func testIsProtectedPathDoesNotMatchAPrefixLikeSiblingName() {
        // "CloudStorageBackup" must not be caught by a naive (non-slash) prefix check against
        // ".../CloudStorage".
        let prefixes = FileSearchLogic.protectedPrefixes(home: fakeHome)
        XCTAssertFalse(FileSearchLogic.isProtectedPath(
            "/Users/tester/Library/CloudStorageBackup/x.txt", protectedPrefixes: prefixes
        ))
    }

    func testPartitioningProtectedSplitsKeptFromSkipped() {
        let prefixes = FileSearchLogic.protectedPrefixes(home: fakeHome)
        let paths = [
            "/Users/tester/Downloads/a.zip",
            "/Users/tester/Library/CloudStorage/Dropbox/b.zip",
            "/Users/tester/Movies/c.mp4",
        ]
        let result = FileSearchLogic.partitioningProtected(paths, protectedPrefixes: prefixes)
        XCTAssertEqual(result.kept, ["/Users/tester/Downloads/a.zip", "/Users/tester/Movies/c.mp4"])
        XCTAssertEqual(result.skipped, 1)
    }

    // MARK: - Kind glyph

    func testSymbolMapsKindToGlyph() {
        XCTAssertEqual(FileSearchLogic.symbol(for: .file), "doc")
        XCTAssertEqual(FileSearchLogic.symbol(for: .directory), "folder")
        XCTAssertEqual(FileSearchLogic.symbol(for: .symbolicLink), "arrow.triangle.turn.up.right.circle")
        XCTAssertEqual(FileSearchLogic.symbol(for: nil), "doc")
    }

    // MARK: - Sort

    func testSortBySizePutsKnownSizesFirstDescending() {
        let entries = [entry("a", bytes: 100), entry("b", bytes: nil), entry("c", bytes: 900)]
        let sorted = FileSearchLogic.sort(entries, order: .size)
        XCTAssertEqual(sorted.map(\.name), ["c", "a", "b"])
    }

    func testSortBySizeBreaksTiesAlphabetically() {
        let entries = [entry("banana", bytes: 100), entry("apple", bytes: 100)]
        let sorted = FileSearchLogic.sort(entries, order: .size)
        XCTAssertEqual(sorted.map(\.name), ["apple", "banana"])
    }

    func testSortByNameIsCaseInsensitiveAlphabetical() {
        let entries = [entry("banana", bytes: nil), entry("Apple", bytes: nil), entry("cherry", bytes: nil)]
        let sorted = FileSearchLogic.sort(entries, order: .name)
        XCTAssertEqual(sorted.map(\.name), ["Apple", "banana", "cherry"])
    }

    // MARK: - Streaming stability (sizing streams in; order must not jitter mid-stream)

    func testDisplayOrderKeepsArrivalOrderWhileSizing() {
        let entries = [entry("c", bytes: 900), entry("a", bytes: nil), entry("b", bytes: 100)]
        let shown = FileSearchLogic.displayOrder(entries, sortOrder: .size, isSizing: true)
        XCTAssertEqual(shown.map(\.name), ["c", "a", "b"])
    }

    func testDisplayOrderSortsOnceSizingCompletes() {
        let entries = [entry("c", bytes: 900), entry("a", bytes: 1000), entry("b", bytes: 100)]
        let shown = FileSearchLogic.displayOrder(entries, sortOrder: .size, isSizing: false)
        XCTAssertEqual(shown.map(\.name), ["a", "c", "b"])
    }

    func testDisplayOrderRespectsNameSortOnceSettled() {
        let entries = [entry("c", bytes: nil), entry("a", bytes: nil), entry("b", bytes: nil)]
        let shown = FileSearchLogic.displayOrder(entries, sortOrder: .name, isSizing: false)
        XCTAssertEqual(shown.map(\.name), ["a", "b", "c"])
    }

    // MARK: - Merge (placeholder rows keep position; only resolved ones change)

    func testMergingReplacesResolvedEntriesByIDPreservingArrayOrder() {
        let placeholders = [entry("a", bytes: nil), entry("b", bytes: nil), entry("c", bytes: nil)]
        let resolvedB = FileSearchEntry(id: placeholders[1].id, name: "b", parentPath: placeholders[1].parentPath, bytes: 500)
        let merged = FileSearchLogic.merging([resolvedB.id: resolvedB], into: placeholders)
        XCTAssertEqual(merged.map(\.name), ["a", "b", "c"])
        XCTAssertNil(merged[0].bytes)
        XCTAssertEqual(merged[1].bytes, 500)
        XCTAssertNil(merged[2].bytes)
    }

    func testMergingWithEmptyTickLeavesEntriesUnchanged() {
        let placeholders = [entry("a", bytes: nil), entry("b", bytes: nil)]
        let merged = FileSearchLogic.merging([:], into: placeholders)
        XCTAssertEqual(merged, placeholders)
    }

    // MARK: - Row-cap math

    func testVisibleRowsUnderCapReturnsEverythingWithNoOverflow() {
        let entries = (0..<10).map { entry("f\($0)", bytes: nil) }
        let result = FileSearchLogic.visibleRows(entries)
        XCTAssertEqual(result.shown.count, 10)
        XCTAssertEqual(result.overflow, 0)
    }

    func testVisibleRowsAtExactlyTheCapHasNoOverflow() {
        let entries = (0..<FileSearchLogic.visibleRowCap).map { entry("f\($0)", bytes: nil) }
        let result = FileSearchLogic.visibleRows(entries)
        XCTAssertEqual(result.shown.count, FileSearchLogic.visibleRowCap)
        XCTAssertEqual(result.overflow, 0)
    }

    func testVisibleRowsOverCapTruncatesAndReportsOverflow() {
        let entries = (0..<(FileSearchLogic.visibleRowCap + 120)).map { entry("f\($0)", bytes: nil) }
        let result = FileSearchLogic.visibleRows(entries)
        XCTAssertEqual(result.shown.count, FileSearchLogic.visibleRowCap)
        XCTAssertEqual(result.overflow, 120)
    }
}
