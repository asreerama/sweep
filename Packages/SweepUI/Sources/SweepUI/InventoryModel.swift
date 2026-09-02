import Foundation

/// Case- and diacritic-folding for search, done ONCE per string at construction time — never per
/// keystroke. The previous filter ran ICU substring search (`range(of:options:)`) over every
/// item's title and detail on every keystroke in `body`; folding each side once and comparing
/// with plain `String.contains` does the same match orders of magnitude cheaper, which is what
/// keeps a filter over a 10,000-row inventory keystroke-instant.
public enum SearchFold {
    public static func fold(_ string: String) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// One key covering several fields, so a row matches on any of them with a single `contains`.
    public static func key(_ fields: String?...) -> String {
        fold(fields.compactMap(\.self).joined(separator: "\n"))
    }
}

/// Safety tier, as the UI speaks it.
///
/// Deliberately not `SweepCore.Tier`: SweepUI depends on nothing, so every component here is
/// previewable and testable without a scan engine. The app maps core tiers onto these at the
/// one place data crosses the boundary.
public enum SweepTier: String, Sendable, Hashable, CaseIterable, Comparable, Codable {
    case safe
    case caution
    case expert

    var rank: Int {
        switch self {
        case .safe: 0
        case .caution: 1
        case .expert: 2
        }
    }

    public static func < (lhs: SweepTier, rhs: SweepTier) -> Bool { lhs.rank < rhs.rank }

    public var label: String {
        switch self {
        case .safe: "Safe"
        case .caution: "Caution"
        case .expert: "Expert"
        }
    }
}

/// One row in an inventory view.
///
/// `sizeText` is pre-formatted on purpose. An inventory can hold tens of thousands of these and
/// row bodies are re-evaluated on every scroll tick; formatting a byte count inside `body` puts
/// a `String(format:)` on the render path 10,000 times. Format once, at aggregation time.
public struct InventoryItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    /// Secondary line — a path, usually. Rendered in SF Mono, middle-truncated.
    public let detail: String?
    public let symbol: String
    public let byteCount: Int64
    public let sizeText: String
    /// Split apart so the column can right-align the digits and left-align the unit: with one
    /// string, `2.83 GB` and `838 MB` right-align to different decimal positions and the
    /// column reads ragged.
    public let sizeValue: String
    public let sizeUnit: String
    public let tier: SweepTier
    /// Folded title+detail, computed here for the same reason `sizeText` is: search runs per
    /// keystroke over every row, so the folding cost belongs at aggregation time, not in `body`.
    public let searchKey: String

    public init(
        id: String,
        title: String,
        detail: String? = nil,
        symbol: String = "doc",
        byteCount: Int64,
        tier: SweepTier
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.byteCount = byteCount
        let parts = SweepFormat.split(byteCount)
        self.sizeValue = parts.value
        self.sizeUnit = parts.unit
        self.sizeText = "\(parts.value) \(parts.unit)"
        self.tier = tier
        self.searchKey = SearchFold.key(title, detail)
    }
}

/// A group of inventory rows: one rule group, one app, one dev environment.
///
/// Totals are computed once at construction. `tier` is the *worst* tier in the group, because a
/// group badge that claimed "Safe" while holding one `expert` item would be a lie.
public struct InventoryGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let symbol: String
    public let items: [InventoryItem]
    public let byteCount: Int64
    public let sizeText: String
    public let sizeValue: String
    public let sizeUnit: String
    public let tier: SweepTier

    /// Folded group title, same construction-time discipline as `InventoryItem.searchKey`.
    public let searchKey: String

    public init(id: String, title: String, symbol: String = "folder", items: [InventoryItem]) {
        self.id = id
        self.title = title
        self.symbol = symbol
        self.items = items
        let total = items.reduce(Int64(0)) { $0 + $1.byteCount }
        self.byteCount = total
        let parts = SweepFormat.split(total)
        self.sizeValue = parts.value
        self.sizeUnit = parts.unit
        self.sizeText = "\(parts.value) \(parts.unit)"
        self.tier = items.map(\.tier).max() ?? .safe
        self.searchKey = SearchFold.fold(title)
    }

    public var itemCount: Int { items.count }

    /// Case- and diacritic-insensitive filter over title and detail. Returns `nil` when nothing
    /// in the group survives, so callers can drop the section header too.
    public func filtered(by query: String) -> InventoryGroup? {
        let folded = SearchFold.fold(query.trimmingCharacters(in: .whitespaces))
        guard !folded.isEmpty else { return self }
        if searchKey.contains(folded) { return self }
        // Pre-folded keys + plain `contains`: the whole per-keystroke cost is one substring scan
        // per row, no ICU, no allocation — see `SearchFold`'s doc for why this matters at scale.
        let matches = items.filter { $0.searchKey.contains(folded) }
        guard !matches.isEmpty else { return nil }
        return InventoryGroup(id: id, title: title, symbol: symbol, items: matches)
    }

    /// Narrows a group to only the given tiers, recomputing its totals from what survives.
    ///
    /// Smart Scan's clean scope is safe-tier only (PLAN §6b): a category group built by
    /// `ScanService` mixes tiers freely, so the safe total and the "needs review" total are two
    /// different views of the same group rather than two different groups. Returns `nil` when
    /// nothing in the requested tiers survives, same contract as ``filtered(by:)``.
    public func filtered(byTiers tiers: Set<SweepTier>) -> InventoryGroup? {
        let matches = items.filter { tiers.contains($0.tier) }
        guard !matches.isEmpty else { return nil }
        return InventoryGroup(id: id, title: title, symbol: symbol, items: matches)
    }
}

public enum InventoryAggregate {
    public static func totalBytes(_ groups: [InventoryGroup]) -> Int64 {
        groups.reduce(Int64(0)) { $0 + $1.byteCount }
    }

    public static func totalItems(_ groups: [InventoryGroup]) -> Int {
        groups.reduce(0) { $0 + $1.itemCount }
    }

    /// Groups with nothing in them are noise; a scan that found no Xcode junk should not print
    /// an empty "Xcode" heading.
    public static func nonEmpty(_ groups: [InventoryGroup]) -> [InventoryGroup] {
        groups.filter { $0.itemCount > 0 }
    }

    public static func filter(_ groups: [InventoryGroup], query: String) -> [InventoryGroup] {
        groups.compactMap { $0.filtered(by: query) }
    }

    /// Every group narrowed to `tiers`, dropping any that end up empty. Used to split one set of
    /// category groups into a safe-tier "clean scope" view and a caution-tier "needs review"
    /// view (PLAN §6b), without the scan engine ever computing two separate group sets.
    public static func filterByTier(_ groups: [InventoryGroup], tiers: Set<SweepTier>) -> [InventoryGroup] {
        groups.compactMap { $0.filtered(byTiers: tiers) }
    }
}

/// Tri-state of a group's select-all control.
public enum SelectionState: Sendable, Hashable {
    case none
    case partial
    case all
}

/// Which inventory rows are selected, and what that adds up to.
///
/// Kept as a value type over a `Set<String>` rather than a flag on each item: selection changes
/// on every click and copying 10,000 item structs to flip one boolean is how a list starts
/// stuttering.
public struct InventorySelection: Sendable, Hashable {
    public private(set) var ids: Set<String>

    public init(ids: Set<String> = []) { self.ids = ids }

    /// Tier-`safe` items in every group, pre-selected. Anything `caution` or `expert` is
    /// surfaced unselected — the user opts in, never out.
    public static func safeDefaults(in groups: [InventoryGroup]) -> InventorySelection {
        var ids = Set<String>()
        for group in groups {
            for item in group.items where item.tier == .safe {
                ids.insert(item.id)
            }
        }
        return InventorySelection(ids: ids)
    }

    public func contains(_ id: String) -> Bool { ids.contains(id) }

    public mutating func set(_ id: String, selected: Bool) {
        if selected { ids.insert(id) } else { ids.remove(id) }
    }

    public mutating func toggle(_ id: String) {
        set(id, selected: !contains(id))
    }

    public func state(of group: InventoryGroup) -> SelectionState {
        guard !group.items.isEmpty else { return .none }
        var selected = 0
        for item in group.items where ids.contains(item.id) { selected += 1 }
        if selected == 0 { return .none }
        return selected == group.items.count ? .all : .partial
    }

    /// Select-all is a toggle on the group's current state: anything short of "all" selects the
    /// rest, "all" clears it.
    public mutating func setAll(_ group: InventoryGroup, selected: Bool) {
        for item in group.items {
            set(item.id, selected: selected)
        }
    }

    public func selectedBytes(in groups: [InventoryGroup]) -> Int64 {
        var total: Int64 = 0
        for group in groups {
            for item in group.items where ids.contains(item.id) {
                total += item.byteCount
            }
        }
        return total
    }

    public func selectedCount(in groups: [InventoryGroup]) -> Int {
        var total = 0
        for group in groups {
            for item in group.items where ids.contains(item.id) { total += 1 }
        }
        return total
    }
}

// MARK: - Bounded expansion (PLAN §6b)

/// Row-count constants for ``InventoryExpansion``.
///
/// macOS 26 corrupts a window's titlebar once its scroll content passes roughly 32,767 pt (the
/// CG 2^15 limit; reproduced with `LazyVStack` and native `List` alike — PLAN §6b). These numbers
/// keep every `InventoryList` far under that regardless of how many rows a scan finds: at the
/// shipping 34 pt row height, `maxVisibleRows` is ~20,400 pt of rows plus a handful of 32 pt
/// headers, comfortably under half the threshold.
public enum InventoryBudget {
    /// Rows an expanded group shows before its "Show all" control appears.
    public static let initialRowsPerGroup = 50
    /// Rows paged in per "Show all" tap, rather than jumping straight to the full count.
    public static let pageSize = 200
    /// Hard ceiling on rows rendered across every expanded group at once, enforced regardless of
    /// how many groups a scan produced or how large any one of them is.
    public static let maxVisibleRows = 600
}

/// Per-group disclosure and paging state for one ``InventoryList``.
///
/// Two things live here instead of a plain `Set<String>` of collapsed ids: how many rows of an
/// expanded group are actually rendered (bounded, paged in with "Show all"), and the budget that
/// keeps their sum under the macOS 26 titlebar limit no matter how many groups the user opens.
/// The type owns the invariant; a view can only ask for `visibleCount(for:)` and never render more
/// than that, so the titlebar bug is fixed by construction rather than by a call site remembering
/// to check a limit.
public struct InventoryExpansion: Sendable, Hashable {
    private var collapsed: Set<String>
    private var visibleCounts: [String: Int]
    /// Ids in the order they were last expanded or paged, oldest first — the order the budget
    /// evicts from when a new "Show all" tap would push the total over the ceiling.
    private var touchOrder: [String]

    public init(collapsedGroupIDs: Set<String> = []) {
        self.collapsed = collapsedGroupIDs
        self.visibleCounts = [:]
        self.touchOrder = []
    }

    /// Applies the row budget up front, before any user interaction.
    ///
    /// Without this, a fresh `InventoryExpansion()` gives every group its default 50-row cap
    /// with nothing collapsed — fine for the handful of groups Smart Scan shows, but System
    /// Junk's per-*rule* grouping can produce dozens of groups, and a scan's rule catalog is not
    /// bounded by this UI's row budget. 20-plus groups at 50 rows apiece would clear
    /// `maxVisibleRows` on the very first frame, before a single disclosure triangle was
    /// touched. Walking `groups` in order and collapsing whatever falls outside the budget makes
    /// the invariant hold from frame one, the same way `enforceBudget` holds it after every
    /// later interaction.
    public static func initial(for groups: [InventoryGroup]) -> InventoryExpansion {
        var expansion = InventoryExpansion()
        var remaining = InventoryBudget.maxVisibleRows
        for group in groups {
            let want = min(InventoryBudget.initialRowsPerGroup, group.itemCount)
            let allowed = max(0, min(want, remaining))
            if group.itemCount > 0, allowed == 0 {
                expansion.collapsed.insert(group.id)
            } else if allowed < want {
                expansion.visibleCounts[group.id] = allowed
            }
            remaining -= allowed
        }
        return expansion
    }

    public func isCollapsed(_ group: InventoryGroup) -> Bool { collapsed.contains(group.id) }

    /// Rows of `group` actually rendered right now: 0 while collapsed, otherwise the paged-in
    /// count clamped to how many items the group actually has.
    public func visibleCount(for group: InventoryGroup) -> Int {
        guard !isCollapsed(group) else { return 0 }
        let requested = visibleCounts[group.id] ?? InventoryBudget.initialRowsPerGroup
        return min(requested, group.itemCount)
    }

    /// Whether a "Show all N" control belongs under this group's rows.
    public func hasMore(_ group: InventoryGroup) -> Bool {
        visibleCount(for: group) < group.itemCount
    }

    /// Disclosure chevron. Expanding re-applies the budget, in case the group being opened is
    /// large enough on its own to need room made for it.
    public mutating func toggleCollapsed(_ group: InventoryGroup, in groups: [InventoryGroup]) {
        if collapsed.contains(group.id) {
            collapsed.remove(group.id)
            touch(group.id)
            enforceBudget(in: groups, keeping: group.id)
        } else {
            collapsed.insert(group.id)
        }
    }

    /// Pages in up to `InventoryBudget.pageSize` more rows of `group`. If that would push the
    /// total rendered rows over budget, the other groups the user opened longest ago are
    /// collapsed first — never the group whose "Show all" was just pressed, since shrinking the
    /// thing the user just asked to see more of would read as the control not working.
    ///
    /// Clamped to `maxVisibleRows` on its own, independent of `enforceBudget`: one group paged
    /// past the *entire* budget stays a titlebar risk even after every other group is evicted to
    /// zero, so a lone group repeatedly paged cannot itself become the unbounded content PLAN
    /// §6b exists to prevent.
    public mutating func showMore(_ group: InventoryGroup, in groups: [InventoryGroup]) {
        let current = visibleCount(for: group)
        let next = min(group.itemCount, current + InventoryBudget.pageSize, InventoryBudget.maxVisibleRows)
        visibleCounts[group.id] = next
        touch(group.id)
        enforceBudget(in: groups, keeping: group.id)
    }

    /// Collapses back to the default row cap.
    public mutating func showFewer(_ group: InventoryGroup) {
        visibleCounts[group.id] = InventoryBudget.initialRowsPerGroup
        touchOrder.removeAll { $0 == group.id }
    }

    private mutating func touch(_ id: String) {
        touchOrder.removeAll { $0 == id }
        touchOrder.append(id)
    }

    /// Evicts expanded groups until the sum of visible rows fits the budget again. `keptID` is
    /// exempt: it is the group whose disclosure or "Show all" just fired, and shrinking the
    /// thing the user just asked to see more of would read as the control not working.
    ///
    /// Two pools, in eviction order:
    /// 1. Groups still at whatever ``initial(for:)`` gave them — never explicitly touched. These
    ///    go first, from the end of `groups` backward, since that list is conventionally sorted
    ///    by size descending and the tail is already the lowest-priority content on screen.
    /// 2. Groups the user did explicitly expand or page, oldest-touched first — evicted only if
    ///    emptying every untouched group still is not enough, so a deliberate "Show all" survives
    ///    anything short of the user opening enough other groups to need the room back.
    ///
    /// Without pool 1, a group `initial(for:)` auto-collapsed to make budget could never be
    /// re-opened past the budget line: nothing would ever be left to evict for it, because
    /// nothing outside `touchOrder` was ever a candidate.
    private mutating func enforceBudget(in groups: [InventoryGroup], keeping keptID: String) {
        func total() -> Int { groups.reduce(0) { $0 + visibleCount(for: $1) } }
        guard total() > InventoryBudget.maxVisibleRows else { return }

        let untouched = groups
            .filter { $0.id != keptID && !collapsed.contains($0.id) && !touchOrder.contains($0.id) }
            .reversed()
            .map(\.id)
        let touched = touchOrder.filter { $0 != keptID && !collapsed.contains($0) }
        var candidates = Array(untouched) + touched

        while total() > InventoryBudget.maxVisibleRows, !candidates.isEmpty {
            let victim = candidates.removeFirst()
            collapsed.insert(victim)
        }
    }
}
