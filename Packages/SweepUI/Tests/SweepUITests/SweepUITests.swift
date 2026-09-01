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

final class TierFilteringTests: XCTestCase {
    private func item(_ id: String, bytes: Int64, tier: SweepTier) -> InventoryItem {
        InventoryItem(id: id, title: id, byteCount: bytes, tier: tier)
    }

    func testFilteredByTiersKeepsOnlyRequestedTier() {
        let group = InventoryGroup(id: "g", title: "System Junk", items: [
            item("a", bytes: 100, tier: .safe),
            item("b", bytes: 200, tier: .caution),
            item("c", bytes: 50, tier: .safe),
        ])
        let safe = group.filtered(byTiers: [.safe])
        XCTAssertEqual(safe?.itemCount, 2)
        XCTAssertEqual(safe?.byteCount, 150)
        let caution = group.filtered(byTiers: [.caution])
        XCTAssertEqual(caution?.itemCount, 1)
        XCTAssertEqual(caution?.byteCount, 200)
    }

    func testFilteredByTiersReturnsNilWhenNothingSurvives() {
        let group = InventoryGroup(id: "g", title: "Xcode", items: [item("a", bytes: 1, tier: .expert)])
        XCTAssertNil(group.filtered(byTiers: [.safe]))
    }

    func testFilterByTierAcrossGroupsDropsEmptyGroups() {
        let groups = [
            InventoryGroup(id: "1", title: "One", items: [item("a", bytes: 1, tier: .safe)]),
            InventoryGroup(id: "2", title: "Two", items: [item("b", bytes: 1, tier: .caution)]),
        ]
        let safeOnly = InventoryAggregate.filterByTier(groups, tiers: [.safe])
        XCTAssertEqual(safeOnly.map(\.id), ["1"])
        let cautionOnly = InventoryAggregate.filterByTier(groups, tiers: [.caution])
        XCTAssertEqual(cautionOnly.map(\.id), ["2"])
    }
}

final class InventoryExpansionTests: XCTestCase {
    private func group(_ id: String, count: Int) -> InventoryGroup {
        InventoryGroup(id: id, title: id, items: (0..<count).map {
            InventoryItem(id: "\(id)-\($0)", title: "\(id)-\($0)", byteCount: 1, tier: .safe)
        })
    }

    func testDefaultVisibleCountIsCappedAtInitialRowsPerGroup() {
        let big = group("big", count: 3000)
        let expansion = InventoryExpansion()
        XCTAssertEqual(expansion.visibleCount(for: big), InventoryBudget.initialRowsPerGroup)
        XCTAssertTrue(expansion.hasMore(big))
    }

    func testSmallGroupNeverGetsAShowMoreControl() {
        let small = group("small", count: 12)
        let expansion = InventoryExpansion()
        XCTAssertEqual(expansion.visibleCount(for: small), 12)
        XCTAssertFalse(expansion.hasMore(small))
    }

    func testCollapsedGroupHasNoVisibleRows() {
        let a = group("a", count: 40)
        var expansion = InventoryExpansion()
        expansion.toggleCollapsed(a, in: [a])
        XCTAssertTrue(expansion.isCollapsed(a))
        XCTAssertEqual(expansion.visibleCount(for: a), 0)
        expansion.toggleCollapsed(a, in: [a])
        XCTAssertFalse(expansion.isCollapsed(a))
    }

    func testShowMorePagesInByPageSize() {
        let a = group("a", count: 3000)
        var expansion = InventoryExpansion()
        expansion.showMore(a, in: [a])
        XCTAssertEqual(expansion.visibleCount(for: a), InventoryBudget.initialRowsPerGroup + InventoryBudget.pageSize)
    }

    func testShowMoreNeverOvershootsTheGroupsRealItemCount() {
        let small = group("small", count: 120)
        var expansion = InventoryExpansion()
        for _ in 0..<40 { expansion.showMore(small, in: [small]) }
        XCTAssertEqual(expansion.visibleCount(for: small), 120)
        XCTAssertFalse(expansion.hasMore(small))
    }

    func testShowMoreOnASingleHugeGroupStillCannotExceedTheTotalBudgetAlone() {
        // Even alone on screen — nothing else competing for room — a group of 3,000 items must
        // never page past the whole-list budget. Left uncapped, enough "Show all" taps on one
        // group would eventually reproduce the exact unbounded-height bug PLAN §6b exists to fix.
        let a = group("a", count: 3000)
        var expansion = InventoryExpansion()
        for _ in 0..<40 { expansion.showMore(a, in: [a]) }
        XCTAssertEqual(expansion.visibleCount(for: a), InventoryBudget.maxVisibleRows)
        XCTAssertTrue(expansion.hasMore(a), "capped by the budget, not by running out of items")
    }

    func testInitialAppliesBudgetAcrossManyGroupsBeforeAnyInteraction() {
        // 20 groups x 100 items: at the 50-row default each, the 13th group already has to be
        // rationed for the sum to stay at or under budget with nothing touched yet.
        let groups = (0..<20).map { group("g\($0)", count: 100) }
        let expansion = InventoryExpansion.initial(for: groups)
        let total = groups.reduce(0) { $0 + expansion.visibleCount(for: $1) }
        XCTAssertLessThanOrEqual(total, InventoryBudget.maxVisibleRows)
        XCTAssertFalse(expansion.isCollapsed(groups[0]))
        XCTAssertTrue(expansion.isCollapsed(groups.last!))
    }

    func testInitialLeavesEverythingExpandedWhenWellUnderBudget() {
        let groups = (0..<3).map { group("g\($0)", count: 40) }
        let expansion = InventoryExpansion.initial(for: groups)
        for g in groups {
            XCTAssertFalse(expansion.isCollapsed(g))
            XCTAssertEqual(expansion.visibleCount(for: g), 40)
        }
    }

    func testExpandingAnAutoCollapsedGroupEvictsAnUntouchedOneToStayInBudget() {
        // 13 groups of exactly 50: `initial` expands the first 12 (exactly 600) and auto-collapses
        // the 13th. Opening the 13th must not blow the budget — something else has to give, even
        // though nothing has ever been explicitly touched before this.
        let groups = (0..<13).map { group("g\($0)", count: 50) }
        var expansion = InventoryExpansion.initial(for: groups)
        XCTAssertTrue(expansion.isCollapsed(groups[12]))

        expansion.toggleCollapsed(groups[12], in: groups)

        XCTAssertFalse(expansion.isCollapsed(groups[12]), "the group the user just opened must stay open")
        let total = groups.reduce(0) { $0 + expansion.visibleCount(for: $1) }
        XCTAssertLessThanOrEqual(total, InventoryBudget.maxVisibleRows)
        // The tail of the untouched groups is what gave way, not an arbitrary one.
        XCTAssertTrue(expansion.isCollapsed(groups[11]))
        XCTAssertFalse(expansion.isCollapsed(groups[0]))
    }

    func testShowMoreRepeatedlyOnOneGroupNeverExceedsBudgetEvenAloneAndEvictsTheOtherGroup() {
        let a = group("a", count: 3000)
        let b = group("b", count: 3000)
        let groups = [a, b]
        var expansion = InventoryExpansion.initial(for: groups)

        for _ in 0..<20 { expansion.showMore(a, in: groups) }

        let total = groups.reduce(0) { $0 + expansion.visibleCount(for: $1) }
        XCTAssertLessThanOrEqual(total, InventoryBudget.maxVisibleRows)
        // `a` grew well past its 50-row default...
        XCTAssertGreaterThan(expansion.visibleCount(for: a), InventoryBudget.initialRowsPerGroup)
        // ...but even the group the user kept paging cannot alone become the unbounded content
        // PLAN §6b exists to prevent, and `b` — untouched — is what gave way to make room.
        XCTAssertLessThanOrEqual(expansion.visibleCount(for: a), InventoryBudget.maxVisibleRows)
        XCTAssertTrue(expansion.isCollapsed(b))
    }
}

final class CleanFlowModelTests: XCTestCase {
    private struct MockBackend: CleanBackend {
        static let isEnabled = true
        let events: [CleanEvent]
        let error: Error?

        init(events: [CleanEvent], error: Error? = nil) {
            self.events = events
            self.error = error
        }

        func execute(itemIDs: Set<String>) -> AsyncThrowingStream<CleanEvent, Error> {
            let events = self.events
            let error = self.error
            return AsyncThrowingStream { continuation in
                for event in events { continuation.yield(event) }
                if let error { continuation.finish(throwing: error) } else { continuation.finish() }
            }
        }
    }

    private struct DisabledBackend: CleanBackend {
        static let isEnabled = false
        func execute(itemIDs: Set<String>) -> AsyncThrowingStream<CleanEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    private struct MockError: Error, CustomStringConvertible {
        let description = "mock failure"
    }

    private let summary = CleanRequestSummary(
        itemCount: 2, totalBytes: 1_000,
        volumes: [CleanVolume(id: "1", name: "Macintosh HD", itemCount: 2, byteCount: 1_000)]
    )

    @MainActor
    func testStartsInConfirmPhaseWithTheGivenSummary() {
        let model = CleanFlowModel(requestSummary: summary, itemIDs: ["a", "b"], backend: MockBackend(events: []))
        guard case .confirm(let shown) = model.phase else { return XCTFail("expected .confirm") }
        XCTAssertEqual(shown, summary)
    }

    @MainActor
    func testDisabledBackendRefusesToStart() {
        let model = CleanFlowModel(requestSummary: summary, itemIDs: ["a"], backend: DisabledBackend())
        XCTAssertFalse(model.isBackendEnabled)
        model.confirmClean()
        guard case .confirm = model.phase else { return XCTFail("must stay at .confirm when the backend is disabled") }
    }

    @MainActor
    func testConfirmCleanDrivesThroughRunningToReport() async {
        let report = CleanReport(freedBytes: 900, succeededCount: 2, outcomes: [])
        let backend = MockBackend(events: [
            .progress(CleanProgressUpdate(remainingBytes: 500, remainingItems: 1, currentItemCaption: "~/x")),
            .finished(report),
        ])
        let model = CleanFlowModel(requestSummary: summary, itemIDs: ["a", "b"], backend: backend)
        model.confirmClean()

        for _ in 0..<50 {
            if case .report = model.phase { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        guard case .report(let finalReport) = model.phase else { return XCTFail("expected .report, got \(model.phase)") }
        XCTAssertEqual(finalReport, report)
    }

    @MainActor
    func testBackendErrorLandsInFailedPhase() async {
        let backend = MockBackend(events: [], error: MockError())
        let model = CleanFlowModel(requestSummary: summary, itemIDs: ["a"], backend: backend)
        model.confirmClean()

        for _ in 0..<50 {
            if case .failed = model.phase { break }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }

        guard case .failed(let message) = model.phase else { return XCTFail("expected .failed, got \(model.phase)") }
        XCTAssertTrue(message.contains("mock failure"))
    }
}

extension CleanFlowPhase: CustomStringConvertible {
    public var description: String {
        switch self {
        case .confirm: "confirm"
        case .running: "running"
        case .report: "report"
        case .failed(let message): "failed(\(message))"
        }
    }
}

final class PackageSurfaceTests: XCTestCase {
    func testPackageIdentity() { XCTAssertEqual(SweepUIInfo.name, "SweepUI") }
}
