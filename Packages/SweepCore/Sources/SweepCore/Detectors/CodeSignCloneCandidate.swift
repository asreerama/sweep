import Foundation

/// One stale `.code_sign_clone` directory (PLAN.md §3 System Junk, Appendix A "Code-sign
/// clones"). macOS clones an app bundle into `<DARWIN_USER_TEMP_DIR>/../X` on every launch and
/// leaks the old ones on self-update; Electron / self-updating apps are the worst offenders.
///
/// Not catalog-driven: Appendix A calls this out as "code-driven detector, not glob" because
/// "app not running" and "old enough" are per-item dynamic predicates a declarative
/// ``RuleCatalog`` pattern cannot express. ``CodeSignCloneDetector`` produces these directly,
/// wrapping the plain ``ScanCandidate`` with the extra provenance a rule normally supplies.
public struct CodeSignCloneCandidate: Sendable, Hashable, Codable, Identifiable {

    /// Tag every candidate from this detector carries, distinct from a rule id, so UI can
    /// recognize "this one was never resolved against the catalog" and caption it
    /// ("regenerates on next launch") instead of looking for a rule's rationale.
    public static let detectorSource = "codeSignClone"

    /// The clone directory itself, in the vocabulary every other producer speaks. `ruleID` is
    /// always `nil` here: this candidate was never resolved against ``RuleCatalog``.
    public let candidate: ScanCandidate
    /// Bundle id recovered from the directory name (`<bundle-id>.code_sign_clone`).
    public let bundleIdentifier: String
    /// Always `.systemJunk` (PLAN.md §3).
    public let group: RuleGroup
    /// Always `.safe` (Appendix A): the clone regenerates on next launch and this candidate
    /// already proved the app is not running and the clone is old enough.
    public let tier: Tier
    /// Always `.regenerated`: macOS rebuilds the clone the next time the app launches.
    public let undo: RuleUndo
    /// See ``detectorSource``. Carried per-instance (rather than looked up from the type) so
    /// the value round-trips through ``Codable`` the same way a rule id does.
    public let detectorSource: String
    /// Always `true`. `candidate.allocatedSize` sums `totalFileAllocatedSize` across every
    /// file in the clone; it is not deduplicated against the clone's sibling generations,
    /// which share copy-on-write blocks with it. That makes the number an apparent size, not a
    /// guaranteed reclaim: the real reclaim on deletion is only the clone's unique blocks,
    /// which no user-space API reports. The UI must caption this honestly rather than present
    /// the figure as bytes a delete is guaranteed to free.
    public let sizeIsCoWApparent: Bool

    public var id: String { candidate.id }

    /// Internal (Codex G1 finding #7): the UI reads these from ``CodeSignCloneDetector/scan()``,
    /// it never constructs one. A public initializer would let a caller stamp any owner/age/kind
    /// it likes onto `candidate.identity` and have `AuthorizedCleanPlan.authorize(codeSignClone:)`
    /// treat it as if the detector itself had found it — that authorization now re-reads identity
    /// live from disk rather than trusting this candidate's, but sealing the initializer removes
    /// the forgery surface entirely rather than relying on the live re-read alone.
    init(
        candidate: ScanCandidate,
        bundleIdentifier: String,
        group: RuleGroup = .systemJunk,
        tier: Tier = .safe,
        undo: RuleUndo = .regenerated,
        detectorSource: String = CodeSignCloneCandidate.detectorSource,
        sizeIsCoWApparent: Bool = true
    ) {
        self.candidate = candidate
        self.bundleIdentifier = bundleIdentifier
        self.group = group
        self.tier = tier
        self.undo = undo
        self.detectorSource = detectorSource
        self.sizeIsCoWApparent = sizeIsCoWApparent
    }
}
