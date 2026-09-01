import Foundation

/// Per-item state vocabulary shared by the journal, the deletion report and the UI.
/// `changed` and `skipped` are distinct on purpose: one means the disk moved under us, the
/// other means we refused on policy.
public enum ItemOutcome: String, Sendable, Codable, CaseIterable {
    case planned
    case succeeded
    case failed
    case skipped
    case changed
    /// Review finding #5: the item was renamed into its quarantine slot (a real mutation
    /// happened — it is no longer at its original location) but neither reaching the real Trash
    /// nor rolling back to the original location succeeded. Distinct from `.failed` (no mutation
    /// ever happened) on purpose: a plain "failed" reads as "nothing changed," which is false
    /// here and would send an operator looking in the wrong place. See
    /// `CleanItemOutcome.quarantineLocation` / `DeletionItemResult.quarantineLocation` for where
    /// it actually is.
    case movedRecoveryRequired
}

/// Why an item did not succeed. Permission denial, policy refusal, disappearance and
/// filesystem error must never collapse into one bucket (PLAN §2, result semantics).
public enum ItemFailureReason: String, Sendable, Codable, CaseIterable {
    case permissionDenied
    case policyDenied
    case outsideFixtureRoot
    case identityChanged
    case vanished
    case tierViolation
    case filesystemError
    case notAttempted
    /// Gate 1's trash-only mode (PLAN §6): the item was not under any of the mode's authorized
    /// roots. Distinct from ``outsideFixtureRoot``, which is fixture-mode's version of the same
    /// idea, so the journal and UI can tell which mode refused an item.
    case outsideAuthorizedRoot
    /// The rule's action was not `trash` (it was `delete` or `commandPreview`), or the concrete
    /// executor for this mode structurally has no delete verb at all. Gate 1 skips these with a
    /// reported outcome rather than executing them (deliverable #2's hard filter).
    case actionNotPermitted
    /// ``AuthorizedCleanPlan`` construction failed for a reason other than a ``SweepPolicy``
    /// denial: an unknown rule id, a candidate whose path did not actually match the rule it
    /// claimed, an owner-uid mismatch, a too-young item, or a running app the rule requires be
    /// quit first. Distinct from ``policyDenied`` so the two trust boundaries are never conflated
    /// in the journal or the UI.
    case notAuthorized
    /// The item reached its quarantine slot but could neither be trashed nor rolled back to its
    /// original location; goes with ``ItemOutcome/movedRecoveryRequired`` (review finding #5).
    case rollbackFailed
    /// Codex G1 finding #1 (CONTROLLING): the pre-mutation `stagePlanned` quarantine-lifecycle
    /// record could not be journaled. The item is refused fail-closed, before the executor is
    /// ever called: no staging, no rename, nothing touched. A mutation must never proceed
    /// without a durable slot record already on disk to recover it by.
    case journalUnavailable
}

/// One item as recorded in the log: the identity is the record, the path is a label.
public struct JournalItem: Sendable, Equatable, Codable {
    public let path: String
    public let identity: FileIdentity
    /// Scan-time identity of the containing directory. Recorded so recovery can tell "the file
    /// we planned" from "a file with that name in a directory that has since been replaced".
    /// Optional, so a journal written before this field existed still replays.
    public let parentIdentity: FileIdentity?
    public let action: DeletionAction
    public let tier: Tier
    public let allocatedSize: Int64
    public let ruleID: String?
    /// Codex Gate-U finding #2: durable manual-consent provenance, present only for a Gate U
    /// leftover admitted after an explicit per-item manual-review confirmation. `nil` for every
    /// other item, and for any journal written before this field existed (`decodeIfPresent`
    /// semantics via the compiler-synthesized `Decodable` conformance below).
    public let manualConsentProvenance: ManualConsentProvenance?

    public init(
        path: String,
        identity: FileIdentity,
        parentIdentity: FileIdentity? = nil,
        action: DeletionAction,
        tier: Tier,
        allocatedSize: Int64,
        ruleID: String? = nil,
        manualConsentProvenance: ManualConsentProvenance? = nil
    ) {
        self.path = path
        self.identity = identity
        self.parentIdentity = parentIdentity
        self.action = action
        self.tier = tier
        self.allocatedSize = allocatedSize
        self.ruleID = ruleID
        self.manualConsentProvenance = manualConsentProvenance
    }
}

/// A write-ahead log line. One JSON object per line, versioned, append-only.
public struct JournalRecord: Sendable, Equatable, Codable {
    public static let currentVersion = 1

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case planned
        case started
        case itemResult
        case committed
        /// Review finding #5: recorded durably for a `trash`-action item *before* the coordinator
        /// ever calls the executor, naming the deterministic slot the item will be renamed into —
        /// so a record identifying the slot exists before the item is ever moved there, closing
        /// "the item is renamed into quarantine before any record identifies its slot."
        case stagePlanned
        /// The rename into the quarantine slot named by the preceding `stagePlanned` record is
        /// known to have succeeded (the executor call that performs it returned successfully or
        /// hit `strandedInQuarantine`, both of which imply staging itself landed).
        case staged
        /// `FileManager.trashItem` succeeded for the staged item; `trashURL` carries the restore
        /// handle. Recorded in addition to (not instead of) the summary `itemResult` record.
        case trashed
        /// Staging succeeded but the subsequent failure could not be rolled back either. Never
        /// suppressed — this is the record that turns a silent `try?` into a durable, surfaced
        /// fact (review finding #5).
        case rollbackFailed
    }

    public let version: Int
    public let kind: Kind
    public let operationID: UUID
    public let recordedAt: Date
    public let planVersion: Int?
    /// SHA-256 of the catalog the operation executes under; set on `planned` records
    /// (optional so pre-digest journals still decode).
    public let catalogDigest: String?
    public let items: [JournalItem]?
    public let item: JournalItem?
    public let outcome: ItemOutcome?
    public let failureReason: ItemFailureReason?
    /// Where `trashItem` actually put it, so restore is possible.
    public let trashURL: URL?
    /// Where a `stagePlanned`/`staged`/`rollbackFailed` record's slot lives (or would live), so
    /// a recovery pass can locate a stranded item without re-deriving the naming scheme.
    public let quarantineURL: URL?
    public let detail: String?

    init(
        kind: Kind,
        operationID: UUID,
        recordedAt: Date = Date(),
        planVersion: Int? = nil,
        catalogDigest: String? = nil,
        items: [JournalItem]? = nil,
        item: JournalItem? = nil,
        outcome: ItemOutcome? = nil,
        failureReason: ItemFailureReason? = nil,
        trashURL: URL? = nil,
        quarantineURL: URL? = nil,
        detail: String? = nil
    ) {
        self.version = Self.currentVersion
        self.kind = kind
        self.operationID = operationID
        self.recordedAt = recordedAt
        self.planVersion = planVersion
        self.catalogDigest = catalogDigest
        self.items = items
        self.item = item
        self.outcome = outcome
        self.failureReason = failureReason
        self.trashURL = trashURL
        self.quarantineURL = quarantineURL
        self.detail = detail
    }
}

/// State of an operation as reconstructed from the log.
public enum OperationState: String, Sendable, Codable {
    case planned
    case started
    case committed
}

/// An operation the log says was never committed: the process died between `planned` and
/// `committed`. Recovery surfaces these; it never replays them automatically.
public struct InterruptedOperation: Sendable, Equatable {
    public let operationID: UUID
    public let planVersion: Int
    public let state: OperationState
    public let plannedAt: Date
    public let items: [JournalItem]
    public let recordedOutcomes: [String: ItemOutcome]

    /// Items with no result line at all: their real on-disk state is unknown and must be
    /// re-stat'd before anything else happens to them.
    public var unresolvedItems: [JournalItem] {
        items.filter { recordedOutcomes[$0.path] == nil }
    }
}
