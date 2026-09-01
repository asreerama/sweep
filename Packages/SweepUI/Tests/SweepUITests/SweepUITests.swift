import XCTest
@testable import SweepUI

final class ByteFormattingTests: XCTestCase {

    func testDecimalUnitsMatchFinder() {
        // Finder counts in decimal. 1 KB is 1000 B, not 1024.
        XCTAssertEqual(SweepFormat.bytes(999), "999 B")
        XCTAssertEqual(SweepFormat.bytes(1_000), "1.00 KB")
        XCTAssertEqual(SweepFormat.bytes(1_024), "1.02 KB")
        XCTAssertEqual(SweepFormat.bytes(1_000_000), "1.00 MB")
        XCTAssertEqual(SweepFormat.bytes(1_000_000_000), "1.00 GB")
        XCTAssertEqual(SweepFormat.bytes(1_000_000_000_000), "1.00 TB")
    }

    func testThreeSignificantDigitsAtEveryMagnitude() {
        // The hero counter must not reflow while it climbs: three significant figures always.
        XCTAssertEqual(SweepFormat.bytes(9_812_345_678), "9.81 GB")
        XCTAssertEqual(SweepFormat.bytes(48_200_000_000), "48.2 GB")
        XCTAssertEqual(SweepFormat.bytes(482_000_000_000), "482 GB")
    }

    func testWholeBytesAreNeverFractional() {
        XCTAssertEqual(SweepFormat.bytes(0), "0 B")
        XCTAssertEqual(SweepFormat.bytes(1), "1 B")
        XCTAssertEqual(SweepFormat.bytes(812), "812 B")
    }

    func testSplitSeparatesValueFromUnit() {
        let parts = SweepFormat.split(9_812_345_678)
        XCTAssertEqual(parts.value, "9.81")
        XCTAssertEqual(parts.unit, "GB")
    }

    func testNegativeBytesKeepTheirSign() {
        // Motion moment two counts a byte total *down*; a transient negative must not read as
        // a giant positive number.
        XCTAssertEqual(SweepFormat.bytes(-1_500_000), "-1.50 MB")
    }

    func testUnitLadderStopsAtPetabytes() {
        XCTAssertEqual(SweepFormat.split(Int64.max).unit, "PB")
    }

    func testItemCountPluralization() {
        XCTAssertEqual(SweepFormat.itemCount(1), "1 item")
        XCTAssertEqual(SweepFormat.itemCount(0), "0 items")
        XCTAssertTrue(SweepFormat.itemCount(48_201).hasSuffix("items"))
    }

    func testHomeAbbreviation() {
        let home = "/Users/tester"
        XCTAssertEqual(SweepFormat.abbreviatingHome("/Users/tester/Library/Caches", home: home), "~/Library/Caches")
        XCTAssertEqual(SweepFormat.abbreviatingHome("/Users/tester", home: home), "~")
        XCTAssertEqual(SweepFormat.abbreviatingHome("/Users/tester2/x", home: home), "/Users/tester2/x")
        XCTAssertEqual(SweepFormat.abbreviatingHome("/var/log", home: home), "/var/log")
        XCTAssertEqual(SweepFormat.abbreviatingHome("/Users/tester/x", home: "/Users/tester/"), "~/x")
    }

    func testMiddleTruncationKeepsBothEnds() {
        let path = "/Users/tester/Library/Caches/com.example.app/Cache_Data/f_00021a"
        let short = SweepFormat.middleTruncated(path, limit: 24)
        XCTAssertEqual(short.count, 24)
        XCTAssertTrue(short.hasPrefix("/Users/tes"))
        XCTAssertTrue(short.hasSuffix("f_00021a"))
        XCTAssertTrue(short.contains("\u{2026}"))
    }

    func testMiddleTruncationLeavesShortStringsAlone() {
        XCTAssertEqual(SweepFormat.middleTruncated("~/Library", limit: 40), "~/Library")
    }
}

final class InventoryAggregationTests: XCTestCase {

    private func item(_ id: String, bytes: Int64, tier: SweepTier = .safe, title: String? = nil) -> InventoryItem {
        InventoryItem(id: id, title: title ?? id, detail: "~/Library/Caches/\(id)", byteCount: bytes, tier: tier)
    }

    func testGroupSumsBytesAndPreformatsOnce() {
        let group = InventoryGroup(id: "g", title: "Caches", items: [
            item("a", bytes: 1_000_000),
            item("b", bytes: 2_500_000),
        ])
        XCTAssertEqual(group.byteCount, 3_500_000)
        XCTAssertEqual(group.sizeText, "3.50 MB")
        XCTAssertEqual(group.itemCount, 2)
    }

    func testGroupTierIsTheWorstItemTier() {
        let group = InventoryGroup(id: "g", title: "Mixed", items: [
            item("a", bytes: 1, tier: .safe),
            item("b", bytes: 1, tier: .expert),
            item("c", bytes: 1, tier: .caution),
        ])
        XCTAssertEqual(group.tier, .expert)
    }

    func testEmptyGroupIsSafeAndZero() {
        let group = InventoryGroup(id: "g", title: "Empty", items: [])
        XCTAssertEqual(group.tier, .safe)
        XCTAssertEqual(group.byteCount, 0)
    }

    func testTierOrdering() {
        XCTAssertLessThan(SweepTier.safe, SweepTier.caution)
        XCTAssertLessThan(SweepTier.caution, SweepTier.expert)
        XCTAssertEqual([SweepTier.caution, .safe, .expert].max(), .expert)
    }

    func testTotalsAcrossGroups() {
        let groups = [
            InventoryGroup(id: "1", title: "One", items: [item("a", bytes: 1_000_000_000)]),
            InventoryGroup(id: "2", title: "Two", items: [item("b", bytes: 500_000_000), item("c", bytes: 1)]),
        ]
        XCTAssertEqual(InventoryAggregate.totalBytes(groups), 1_500_000_001)
        XCTAssertEqual(InventoryAggregate.totalItems(groups), 3)
    }

    func testNonEmptyDropsEmptyGroups() {
        let groups = [
            InventoryGroup(id: "1", title: "One", items: [item("a", bytes: 1)]),
            InventoryGroup(id: "2", title: "Two", items: []),
        ]
        XCTAssertEqual(InventoryAggregate.nonEmpty(groups).map(\.id), ["1"])
    }

    func testFilterMatchesItemTitleAndPath() {
        let group = InventoryGroup(id: "g", title: "Caches", items: [
            item("chrome", bytes: 1, title: "Google Chrome"),
            item("firefox", bytes: 1, title: "Firefox"),
        ])
        XCTAssertEqual(group.filtered(by: "chro")?.itemCount, 1)
        XCTAssertEqual(group.filtered(by: "CHROME")?.itemCount, 1)
        XCTAssertEqual(group.filtered(by: "Caches/firefox")?.itemCount, 1)
        XCTAssertNil(group.filtered(by: "safari"))
    }

    func testFilterOnGroupTitleKeepsWholeGroup() {
        let group = InventoryGroup(id: "g", title: "Xcode Device Support", items: [
            item("a", bytes: 1), item("b", bytes: 1),
        ])
        XCTAssertEqual(group.filtered(by: "xcode")?.itemCount, 2)
    }

    func testFilterRecomputesGroupTotals() {
        let group = InventoryGroup(id: "g", title: "Caches", items: [
            item("keepme", bytes: 4_000_000),
            item("other", bytes: 96_000_000),
        ])
        let filtered = group.filtered(by: "keepme")
        XCTAssertEqual(filtered?.byteCount, 4_000_000)
        XCTAssertEqual(filtered?.sizeText, "4.00 MB")
    }

    func testEmptyQueryIsIdentity() {
        let group = InventoryGroup(id: "g", title: "Caches", items: [item("a", bytes: 1)])
        XCTAssertEqual(group.filtered(by: "   ")?.itemCount, 1)
    }
}

final class InventorySelectionTests: XCTestCase {

    private func item(_ id: String, bytes: Int64, tier: SweepTier = .safe) -> InventoryItem {
        InventoryItem(id: id, title: id, byteCount: bytes, tier: tier)
    }

    private var groups: [InventoryGroup] {
        [
            InventoryGroup(id: "safe", title: "Safe", items: [
                item("s1", bytes: 100), item("s2", bytes: 200),
            ]),
            InventoryGroup(id: "risky", title: "Risky", items: [
                item("r1", bytes: 400, tier: .caution), item("r2", bytes: 800, tier: .expert),
            ]),
        ]
    }

    func testSafeDefaultsSelectOnlySafeTier() {
        let selection = InventorySelection.safeDefaults(in: groups)
        XCTAssertEqual(selection.ids, ["s1", "s2"])
        XCTAssertEqual(selection.selectedBytes(in: groups), 300)
        XCTAssertEqual(selection.selectedCount(in: groups), 2)
    }

    func testGroupStateIsTriState() {
        var selection = InventorySelection()
        XCTAssertEqual(selection.state(of: groups[0]), .none)
        selection.set("s1", selected: true)
        XCTAssertEqual(selection.state(of: groups[0]), .partial)
        selection.set("s2", selected: true)
        XCTAssertEqual(selection.state(of: groups[0]), .all)
    }

    func testEmptyGroupReportsNoneNotAll() {
        let selection = InventorySelection()
        XCTAssertEqual(selection.state(of: InventoryGroup(id: "e", title: "Empty", items: [])), .none)
    }

    func testSetAllIsScopedToItsGroup() {
        var selection = InventorySelection.safeDefaults(in: groups)
        selection.setAll(groups[1], selected: true)
        XCTAssertEqual(selection.state(of: groups[1]), .all)
        XCTAssertEqual(selection.state(of: groups[0]), .all)
        selection.setAll(groups[0], selected: false)
        XCTAssertEqual(selection.state(of: groups[0]), .none)
        XCTAssertEqual(selection.state(of: groups[1]), .all)
        XCTAssertEqual(selection.selectedBytes(in: groups), 1_200)
    }

    func testToggleRoundTrips() {
        var selection = InventorySelection()
        selection.toggle("s1")
        XCTAssertTrue(selection.contains("s1"))
        selection.toggle("s1")
        XCTAssertFalse(selection.contains("s1"))
    }

    func testSelectedBytesIgnoresIdsNotInTheseGroups() {
        // A stale id left over from a previous scan must not inflate the total.
        var selection = InventorySelection()
        selection.set("ghost", selected: true)
        XCTAssertEqual(selection.selectedBytes(in: groups), 0)
    }
}

final class PackageSurfaceTests: XCTestCase {
    func testPackageIdentity() { XCTAssertEqual(SweepUIInfo.name, "SweepUI") }
}
