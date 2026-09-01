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
    /// A `pkgutil` receipt identifier relationship exists only as a component-prefix in one
    /// direction or the other (`com.vendor` vs `com.vendor.product`), never as an exact id match
    /// or `pkgutil --files` proof the receipt installed this exact app bundle. A real but weak
    /// relationship — never enough on its own to promote past manual review. See finding #12 in
    /// the adversarial review.
    public static let receiptPrefixMatch = OwnershipEvidence(rawValue: 1 << 6)
    /// Another installed app could plausibly also own/depend on this item: it shares the
    /// candidate's or target's second-level reverse-DNS vendor prefix (`com.vendor.*`) with at
    /// least one other installed app, shares a code-signing team identifier with one, or the
    /// candidate's own name independently matches a different installed app's bundle id/prefix.
    /// A vendor's shared "Common Files"-style folder can look like an exact match for one
    /// specific product while a sibling product still depends on it. See finding #11 in the
    /// adversarial review.
    public static let ambiguousOwner = OwnershipEvidence(rawValue: 1 << 7)
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
    /// `receiptListed` may ever be auto-selectable — and even then, an item is capped at
    /// `manualReview` whenever it also lives in a Group Container or a LaunchDaemons directory
    /// (neither is ever exclusively owned by one app regardless of how strong the name/id match
    /// looks), or carries `ambiguousOwner` (another installed app could plausibly also own it —
    /// finding #11). `receiptPrefixMatch` alone (finding #12) is likewise never promoted: it
    /// falls through to the final `manualReview` below since it is neither `exactBundleID` nor
    /// `receiptListed`.
    public static func derive(from evidence: OwnershipEvidence) -> MatchConfidence {
        guard !evidence.isEmpty else { return .orphan }
        if evidence.contains(.sharedGroupContainer) || evidence.contains(.launchDaemon) || evidence.contains(.ambiguousOwner) {
            return .manualReview
        }
        if evidence.contains(.exactBundleID) || evidence.contains(.receiptListed) {
            return .autoSelectable
        }
        return .manualReview
    }
}
