import Foundation

/// Filesystem mutations a plan may request. `RuleAction.commandPreview` has no representation
/// here on purpose: commands run through typed adapters, never through the coordinator.
public enum DeletionAction: String, Sendable, Codable, CaseIterable {
    /// `FileManager.trashItem`. Reversible, and the resulting Trash URL is journaled.
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
public struct DeletionItem: Sendable, Equatable, Codable, Identifiable {
    public let url: URL
    public let identity: FileIdentity
    public let action: DeletionAction
    public let tier: Tier
    public let allocatedSize: Int64
    public let ruleID: String?

    public var id: String { "\(identity.deviceID):\(identity.inode):\(url.path)" }

    public init(
        url: URL,
        identity: FileIdentity,
        action: DeletionAction,
        tier: Tier,
        allocatedSize: Int64,
        ruleID: String? = nil
    ) {
        self.url = url
        self.identity = identity
        self.action = action
        self.tier = tier
        self.allocatedSize = allocatedSize
        self.ruleID = ruleID
    }

    public init(candidate: ScanCandidate, action: DeletionAction, tier: Tier) {
        self.init(
            url: candidate.url,
            identity: candidate.identity,
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
            action: action,
            tier: tier,
            allocatedSize: allocatedSize,
            ruleID: ruleID
        )
    }
}

/// Immutable, versioned unit of work. Built by read-only producers, executed by exactly one
/// consumer. Nothing mutates the filesystem without one of these.
public struct DeletionPlan: Sendable, Equatable, Codable, Identifiable {
    public static let currentVersion = 1

    public let version: Int
    public let operationID: UUID
    public let createdAt: Date
    public let items: [DeletionItem]

    public var id: UUID { operationID }

    public init(
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
public struct DeletionItemResult: Sendable, Equatable, Codable, Identifiable {
    public let item: DeletionItem
    public let outcome: ItemOutcome
    public let failureReason: ItemFailureReason?
    public let trashURL: URL?
    public let detail: String?

    public var id: String { item.id }

    public init(
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

    public init(operationID: UUID, results: [DeletionItemResult], committed: Bool) {
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
