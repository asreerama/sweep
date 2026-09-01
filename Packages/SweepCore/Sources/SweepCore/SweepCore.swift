import Foundation

/// SweepCore: rules engine, scan engine, write-ahead journal, deletion coordinator.
///
/// The package is split by trust level. Everything except ``DeletionCoordinator`` is a
/// read-only producer of ``ScanCandidate`` values; the coordinator is the single point where
/// the filesystem is mutated, it takes an immutable ``DeletionPlan``, and in this build it
/// refuses any path outside an injected fixture root.
public enum SweepCoreInfo {
    public static let name = "SweepCore"
    /// Rule catalog schema this build reads (rules/schema.json, frozen v1).
    public static let ruleSchemaVersion = RuleCatalog.supportedSchemaVersion
    /// Deletion plan version this build executes.
    public static let planVersion = DeletionPlan.currentVersion
    /// Journal record version this build writes.
    public static let journalVersion = JournalRecord.currentVersion
}
