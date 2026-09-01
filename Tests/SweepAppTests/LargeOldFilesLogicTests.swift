import XCTest
@testable import SweepApp

/// Pure logic behind `LargeOldFilesScreen` (module 4, PLAN §3): size-threshold filtering, age
/// sort, and grouping. None of this touches the filesystem or `SweepCore.ScanEngine`.
///
/// NOTE for wiring: this target is not yet registered in the root `Package.swift`. Add
/// `.testTarget(name: "SweepAppTests", dependencies: ["SweepApp"], path: "Tests/SweepAppTests")`
/// to its `targets` array to run this under `swift test`.
final class LargeOldFilesLogicTests: XCTestCase {

    private func entry(_ name: String, bytes: Int64, path: String = "~/Downloads/x", daysOld: Double = 0) -> LargeFileEntry {
        LargeFileEntry(
            id: "/Users/tester/\(name)",
            name: name,
            path: path,
            bytes: bytes,
            modified: Date(timeIntervalSinceNow: -daysOld * 86_400)
        )
    }

    // MARK: - Size thresholds

    func testThresholdByteValuesAreDecimal() {
        XCTAssertEqual(LargeFileSizeThreshold.mb50.bytes, 50_000_000)
        XCTAssertEqual(LargeFileSizeThreshold.mb100.bytes, 100_000_000)
        XCTAssertEqual(LargeFileSizeThreshold.mb500.bytes, 500_000_000)
        XCTAssertEqual(LargeFileSizeThreshold.gb1.bytes, 1_000_000_000)
    }

    func testSmallestThresholdIsTheFloor() {
        XCTAssertEqual(LargeFileSizeThreshold.smallest, .mb50)
        XCTAssertEqual(LargeFileSizeThreshold.allCases.map(\.bytes).min(), LargeFileSizeThreshold.smallest.bytes)
    }

    // MARK: - Filter + sort

    func testFilterDropsEverythingBelowThreshold() {
        let entries = [entry("a", bytes: 40_000_000), entry("b", bytes: 60_000_000), entry("c", bytes: 120_000_000)]
        let result = LargeFilesLogic.filterAndSort(entries, threshold: .mb50, sortOrder: .largestFirst)
        XCTAssertEqual(result.map(\.name), ["c", "b"])
    }

    func testHigherThresholdFiltersMoreAggressively() {
        let entries = [entry("a", bytes: 60_000_000), entry("b", bytes: 600_000_000), entry("c", bytes: 2_000_000_000)]
        let result = LargeFilesLogic.filterAndSort(entries, threshold: .gb1, sortOrder: .largestFirst)
        XCTAssertEqual(result.map(\.name), ["c"])
    }

    func testLargestFirstSortsDescendingBySize() {
        let entries = [entry("a", bytes: 60_000_000), entry("b", bytes: 900_000_000), entry("c", bytes: 300_000_000)]
        let result = LargeFilesLogic.filterAndSort(entries, threshold: .mb50, sortOrder: .largestFirst)
        XCTAssertEqual(result.map(\.name), ["b", "c", "a"])
    }

    func testOldestFirstSortsAscendingByModificationDate() {
        let entries = [
            entry("new", bytes: 60_000_000, daysOld: 1),
            entry("old", bytes: 60_000_000, daysOld: 400),
            entry("mid", bytes: 60_000_000, daysOld: 30),
        ]
        let result = LargeFilesLogic.filterAndSort(entries, threshold: .mb50, sortOrder: .oldestFirst)
        XCTAssertEqual(result.map(\.name), ["old", "mid", "new"])
    }

    // MARK: - Bucketing

    func testTopLevelBucketReadsTheFirstPathComponentUnderHome() {
        XCTAssertEqual(LargeFilesLogic.topLevelBucket(forDisplayPath: "~/Downloads/movie.mp4"), "Downloads")
        XCTAssertEqual(LargeFilesLogic.topLevelBucket(forDisplayPath: "~/Movies/Show/ep1.mp4"), "Movies")
    }

    func testTopLevelBucketHandlesHomeRootAndForeignVolumes() {
        XCTAssertEqual(LargeFilesLogic.topLevelBucket(forDisplayPath: "~"), "Home")
        XCTAssertEqual(LargeFilesLogic.topLevelBucket(forDisplayPath: "/Volumes/External/big.iso"), "Other locations")
    }

    // MARK: - Grouping

    func testBuildGroupsBucketsAndSortsByTotalSizeDescending() {
        let entries = [
            entry("a", bytes: 100_000_000, path: "~/Downloads/a"),
            entry("b", bytes: 200_000_000, path: "~/Downloads/b"),
            entry("c", bytes: 900_000_000, path: "~/Movies/c"),
        ]
        let groups = LargeFilesLogic.buildGroups(from: entries)
        XCTAssertEqual(groups.map(\.title), ["Movies", "Downloads"])
        XCTAssertEqual(groups.first?.byteCount, 900_000_000)
        XCTAssertEqual(groups.last?.itemCount, 2)
    }

    func testEveryGroupIsCautionTierNeverSafe() {
        let groups = LargeFilesLogic.buildGroups(from: [entry("a", bytes: 100_000_000)])
        XCTAssertEqual(groups.first?.tier, .caution)
    }

    func testBuildGroupsOnEmptyInputIsEmpty() {
        XCTAssertTrue(LargeFilesLogic.buildGroups(from: []).isEmpty)
    }
}
