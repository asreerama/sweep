import Foundation

/// Every reason a filesystem item might be attributed to an app. A candidate can carry more
/// than one bit at once (e.g. a LaunchAgent that is both an exact-bundle-id match and,
/// incidentally, name-matched too), which is why this is an `OptionSet` rather than a single
/// enum case.
public struct OwnershipEvidence: OptionSet, Sendable, Hashable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    /// The item's name is exactly the app's bundle identifier (component-for-component).
    public static let exactBundleID = OwnershipEvidence(rawValue: 1 << 0)
    /// A `pkgutil` receipt (package id or its file listing) ties this item to the app.
    public static let receiptListed = OwnershipEvidence(rawValue: 1 << 1)
    /// The item's name extends the bundle id by trailing components (`.helper`, `.agent`, …).
    public static let prefixMatch = OwnershipEvidence(rawValue: 1 << 2)
    /// The item's name matches the app's display name / bundle stem (or a curated alias from
    /// the Conditions table), not its bundle id.
    public static let nameMatch = OwnershipEvidence(rawValue: 1 << 3)
    /// The item lives in `~/Library/Group Containers` — shared by every app in the app group,
    /// so ownership is never exclusive even when the name match is strong.
    public static let sharedGroupContainer = OwnershipEvidence(rawValue: 1 << 4)
    /// The item is a `/Library/LaunchDaemons` entry — root-owned, requires privileged
    /// `launchctl bootout` handling, never a plain delete.
    public static let launchDaemon = OwnershipEvidence(rawValue: 1 << 5)
}

/// The only judgment this package makes about a match: which tier of human review it needs
/// before `SweepCore`'s `DeletionCoordinator` may ever act on it. This package never deletes
/// anything itself — `MatchConfidence` only labels candidates for that later consumer.
public enum MatchConfidence: String, Sendable, Hashable, CaseIterable {
    /// May be offered pre-selected later. Reserved for the strongest, least ambiguous
    /// evidence only.
    case autoSelectable
    /// Surfaced, but never pre-selected: name-only matches, shared Group Containers,
    /// LaunchDaemons.
    case manualReview
    /// No installed app claims this item at all (orphan-mode result).
    case orphan

    /// Derives confidence from evidence. Per PLAN.md §3 module 5: only `exactBundleID` or
    /// `receiptListed` may ever be auto-selectable — and even then, an item that also lives in
    /// a Group Container or a LaunchDaemons directory is capped at `manualReview`, because
    /// those two locations are never exclusively owned by one app regardless of how strong the
    /// name/id match looks.
    public static func derive(from evidence: OwnershipEvidence) -> MatchConfidence {
        guard !evidence.isEmpty else { return .orphan }
        if evidence.contains(.sharedGroupContainer) || evidence.contains(.launchDaemon) {
            return .manualReview
        }
        if evidence.contains(.exactBundleID) || evidence.contains(.receiptListed) {
            return .autoSelectable
        }
        return .manualReview
    }
}
