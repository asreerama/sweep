import Foundation
import SweepUI
import SweepUninstall

/// Every group the leftover panel can render. PLAN §3 module 5: "bundle + leftovers grouped by
/// evidence (exact/receipt = preselected; prefix/name/shared/orphan = unselected manual tiers per
/// `MatchConfidence`)".
///
/// `.possiblyShared` is not named explicitly in that line, but it exists to carry the "ambiguous-
/// owner warnings" the same requirement calls for: `LeftoverMatcher` already flags a candidate
/// that could plausibly belong to more than one installed app (`OwnershipEvidence.ambiguousOwner`)
/// — routing it to its own clearly-labelled group, ahead of whatever else it matched on, is how
/// that warning actually reaches the screen without SweepUI growing a per-row accessory slot this
/// deliverable is not allowed to add.
enum LeftoverGroupKind: String, CaseIterable, Sendable {
    case possiblyShared
    case sharedContainer
    case launchDaemon
    case exactMatch
    case receipt
    case prefixMatch
    case nameMatch
    case orphan

    var title: String {
        switch self {
        case .possiblyShared: "Possibly shared with another app"
        case .sharedContainer: "Shared containers"
        case .launchDaemon: "Launch daemons"
        case .exactMatch: "Exact matches"
        case .receipt: "Installer receipts"
        case .prefixMatch: "Prefix matches"
        case .nameMatch: "Name matches"
        case .orphan: "Orphaned items"
        }
    }

    var symbol: String {
        switch self {
        case .possiblyShared: "exclamationmark.triangle"
        case .sharedContainer: "person.2"
        case .launchDaemon: "bolt.shield"
        case .exactMatch: "checkmark.seal"
        case .receipt: "shippingbox"
        case .prefixMatch: "text.magnifyingglass"
        case .nameMatch: "textformat"
        case .orphan: "questionmark.folder"
        }
    }

    /// Only an exact bundle id or a listed installer receipt may ever be preselected — the same
    /// line PLAN draws for `MatchConfidence.autoSelectable`. Every other tier here, orphan
    /// included, is surfaced unselected; the user opts in.
    var isPreselectedByDefault: Bool {
        self == .exactMatch || self == .receipt
    }
}

enum LeftoverGrouping {
    /// Buckets one candidate's evidence into the single group it displays under.
    ///
    /// Order matters and mirrors `MatchConfidence.derive`'s own precedence exactly: an ambiguous
    /// owner or a shared/root-owned location is flagged ahead of an otherwise-strong bundle-id or
    /// receipt match, so a group's tier badge is never a stronger promise than the confidence
    /// value actually backing the candidates inside it.
    static func bucket(for evidence: OwnershipEvidence) -> LeftoverGroupKind {
        if evidence.contains(.ambiguousOwner) { return .possiblyShared }
        if evidence.contains(.sharedGroupContainer) { return .sharedContainer }
        if evidence.contains(.launchDaemon) { return .launchDaemon }
        if evidence.contains(.exactBundleID) { return .exactMatch }
        if evidence.contains(.receiptListed) { return .receipt }
        if evidence.contains(.prefixMatch) || evidence.contains(.receiptPrefixMatch) { return .prefixMatch }
        return .nameMatch
    }

    /// `sizeByID` is keyed by `LeftoverCandidate.id` (its path) and defaults empty: sizes are
    /// computed lazily in the background (same contract as app sizes), and a group set built
    /// before they land simply shows zero-byte rows until the caller rebuilds groups once sizes
    /// arrive — never a blocking wait on a background stat pass.
    static func groups(for candidates: [LeftoverCandidate], home: URL, sizeByID: [String: Int64] = [:]) -> [InventoryGroup] {
        var byKind: [LeftoverGroupKind: [InventoryItem]] = [:]
        for candidate in candidates {
            let kind = bucket(for: candidate.evidence)
            byKind[kind, default: []].append(item(for: candidate, kind: kind, home: home, sizeByID: sizeByID))
        }
        return LeftoverGroupKind.allCases
            .filter { $0 != .orphan }
            .compactMap { kind in
                guard let items = byKind[kind], !items.isEmpty else { return nil }
                return InventoryGroup(id: kind.rawValue, title: kind.title, symbol: kind.symbol, items: items)
            }
    }

    static func orphanGroup(for candidates: [OrphanCandidate], home: URL, sizeByID: [String: Int64] = [:]) -> InventoryGroup? {
        guard !candidates.isEmpty else { return nil }
        let items = candidates.map { candidate -> InventoryItem in
            let title = candidate.isLikelyHelperTool
                ? "\(candidate.apparentBundleID) (possible helper tool)"
                : candidate.apparentBundleID
            return InventoryItem(
                id: candidate.id,
                title: title,
                detail: SweepFormat.abbreviatingHome(candidate.url.path, home: home.path),
                symbol: "questionmark.folder",
                byteCount: sizeByID[candidate.id] ?? 0,
                tier: .caution
            )
        }
        return InventoryGroup(
            id: LeftoverGroupKind.orphan.rawValue,
            title: LeftoverGroupKind.orphan.title,
            symbol: LeftoverGroupKind.orphan.symbol,
            items: items
        )
    }

    /// Every item in every group whose kind is preselected by default. Tier already reflects the
    /// same rule (see `item(for:kind:home:sizeByID:)`), so this only needs to check the group.
    static func preselectedIDs(in groups: [InventoryGroup]) -> InventorySelection {
        var ids = Set<String>()
        for group in groups where LeftoverGroupKind(rawValue: group.id)?.isPreselectedByDefault == true {
            for item in group.items { ids.insert(item.id) }
        }
        return InventorySelection(ids: ids)
    }

    private static func item(for candidate: LeftoverCandidate, kind: LeftoverGroupKind, home: URL, sizeByID: [String: Int64]) -> InventoryItem {
        InventoryItem(
            id: candidate.id,
            title: candidate.url.lastPathComponent,
            detail: SweepFormat.abbreviatingHome(candidate.url.path, home: home.path),
            symbol: symbol(for: candidate.root),
            byteCount: sizeByID[candidate.id] ?? 0,
            tier: kind.isPreselectedByDefault ? .safe : .caution
        )
    }

    private static func symbol(for root: SearchRoot) -> String {
        switch root {
        case .applicationSupport: "folder"
        case .caches: "shippingbox"
        case .preferences: "gearshape"
        case .containers, .groupContainers: "shippingbox.and.arrow.backward"
        case .savedApplicationState: "clock.arrow.circlepath"
        case .launchAgents, .libraryLaunchDaemons: "bolt.shield"
        case .webKit, .httpStorages: "network"
        case .pkgReceipt: "doc.badge.gearshape"
        }
    }
}
