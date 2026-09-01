import Foundation

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
    }

    public var itemCount: Int { items.count }

    /// Case- and diacritic-insensitive filter over title and detail. Returns `nil` when nothing
    /// in the group survives, so callers can drop the section header too.
    public func filtered(by query: String) -> InventoryGroup? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return self }
        if title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return self
        }
        let matches = items.filter { item in
            item.title.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (item.detail?.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
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
