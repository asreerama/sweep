import Foundation

/// Filesystem mutations a plan may request. `RuleAction.commandPreview` has no representation
/// here on purpose: commands run through typed adapters, never through the coordinator.
public enum DeletionAction: String, Sendable, Codable, CaseIterable {
    /// `FileManager.trashItem`, reached only after a descriptor-relative rename into quarantine.
    /// Reversible, and the resulting Trash URL is journaled.
    case trash
    /// Unlink. Only ever valid for `tier == .safe` regenerable caches.
    case delete

    public init?(_ ruleAction: RuleAction) {
        switch ruleAction {
        case .trash: self = .trash
        case .delete: self = .delete
        case .commandPreview: return nil
        }
    }
}

/// One item in a plan, carrying the identity captured at scan time. The coordinator will
/// refuse it unless the disk still matches this exactly.
///
/// The initializers are internal. A caller outside `SweepCore` cannot build one, and the type is
/// deliberately *not* `Codable`, so it cannot be conjured by decoding either: a self-asserted
/// `tier: .safe` on a caller-chosen path was a live-deletion capability (review finding #1).
/// Fixtures go through ``FixtureExecution``; real plans will come from the rule-authorization
/// pipeline in Gate 1.
public struct DeletionItem: Sendable, Equatable, Identifiable {
    public let url: URL
    public let identity: FileIdentity
    /// Scan-time identity of the containing directory, revalidated descriptor-wise during the
    /// descent. Previously captured by the scan and then dropped here (review finding #5).
    public let parentIdentity: FileIdentity?
    public let action: DeletionAction
    public let tier: Tier
    public let allocatedSize: Int64
    public let ruleID: String?

    public var id: String { "\(identity.deviceID):\(identity.inode):\(url.path)" }

    init(
        url: URL,
        identity: FileIdentity,
        parentIdentity: FileIdentity? = nil,
        action: DeletionAction,
        tier: Tier,
        allocatedSize: Int64,
        ruleID: String? = nil
    ) {
        self.url = url
        self.identity = identity
        self.parentIdentity = parentIdentity
        self.action = action
        self.tier = tier
        self.allocatedSize = allocatedSize
        self.ruleID = ruleID
    }

    init(candidate: ScanCandidate, action: DeletionAction, tier: Tier) {
        self.init(
            url: candidate.url,
            identity: candidate.identity,
            parentIdentity: candidate.parentIdentity,
            action: action,
            tier: tier,
            allocatedSize: candidate.allocatedSize,
            ruleID: candidate.ruleID
        )
    }

    var journalItem: JournalItem {
        JournalItem(
            path: url.path,
            identity: identity,
            parentIdentity: parentIdentity,
            action: action,
            tier: tier,
            allocatedSize: allocatedSize,
            ruleID: ruleID
        )
    }
}

/// Immutable, versioned unit of work. Built by read-only producers, executed by exactly one
/// consumer. Nothing mutates the filesystem without one of these.
///
/// - Note: A plan is still only *self-describing*: it carries a tier and an action that the
///   coordinator checks, but nothing in it proves a rule authorized those fields. Closing that
///   is review finding #9 — a validated rule-execution request that resolves the symbolic root,
///   verifies owner UID, type, age and process state, and emits an unforgeable authorized plan.
///   It is deliberately deferred to Gate 1 (PLAN §6); until then the only plans that exist are
///   fixture plans, confined to a disposable root by ``FixtureExecution``.
public struct DeletionPlan: Sendable, Equatable, Identifiable {
    public static let currentVersion = 1

    public let version: Int
    public let operationID: UUID
    public let createdAt: Date
    public let items: [DeletionItem]

    public var id: UUID { operationID }

    init(
        version: Int = DeletionPlan.currentVersion,
        operationID: UUID = UUID(),
        createdAt: Date = Date(),
        items: [DeletionItem]
    ) {
        self.version = version
        self.operationID = operationID
        self.createdAt = createdAt
        self.items = items
    }

    public var totalAllocatedSize: Int64 {
        items.reduce(0) { $0 + $1.allocatedSize }
    }
}

/// Result for one item. `trashURL` is the restore handle for a trashed item.
public struct DeletionItemResult: Sendable, Equatable, Identifiable {
    public let item: DeletionItem
    public let outcome: ItemOutcome
    public let failureReason: ItemFailureReason?
    public let trashURL: URL?
    public let detail: String?

    public var id: String { item.id }

    init(
        item: DeletionItem,
        outcome: ItemOutcome,
        failureReason: ItemFailureReason? = nil,
        trashURL: URL? = nil,
        detail: String? = nil
    ) {
        self.item = item
        self.outcome = outcome
        self.failureReason = failureReason
        self.trashURL = trashURL
        self.detail = detail
    }
}

/// Outcome of one whole operation.
///
/// `plannedBytesRemoved` is the sum of scan-time sizes for succeeded items, not a measurement
/// of freed space. Real "freed" is a post-operation volume-capacity delta (PLAN §2) and is
/// deliberately not claimed here.
public struct DeletionReport: Sendable, Equatable {
    public let operationID: UUID
    public let results: [DeletionItemResult]
    public let committed: Bool

    init(operationID: UUID, results: [DeletionItemResult], committed: Bool) {
        self.operationID = operationID
        self.results = results
        self.committed = committed
    }

    public func results(with outcome: ItemOutcome) -> [DeletionItemResult] {
        results.filter { $0.outcome == outcome }
    }

    public var succeededCount: Int { results(with: .succeeded).count }
    public var failedCount: Int { results(with: .failed).count }
    public var skippedCount: Int { results(with: .skipped).count }
    public var changedCount: Int { results(with: .changed).count }

    public var plannedBytesRemoved: Int64 {
        results.reduce(0) { $0 + ($1.outcome == .succeeded ? $1.item.allocatedSize : 0) }
    }
}
