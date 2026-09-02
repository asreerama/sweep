import Foundation
import Observation
import SweepCore
import SweepUI

enum DeveloperScanPhase: Equatable {
    case idle
    case scanning
    case results
    case failed(String)

    var ringState: ScanRingState {
        switch self {
        case .idle, .failed: .idle
        case .scanning: .scanning
        case .results: .complete
        }
    }
}

/// Screen state for the Developer module (PLAN §3 module 10).
///
/// Deliberately its own scan, not a read of the shared `ScanModel` System Junk/Smart Scan share:
/// the Toolbox contract is "never appear in Smart Scan" (PLAN §3), and the surest way to honor
/// that is for this module to never write into the object Smart Scan reads from at all. It scopes
/// a real `ScanService.run` (the exact rule-catalog walk System Junk uses) to the catalog's
/// `developer` group only, then hands the per-rule results to `DeveloperEnvironmentCatalog` for
/// the per-environment "different lens" grouping — "same rules engine underneath as System Junk"
/// is true by construction, not by parallel reimplementation.
@MainActor
@Observable
final class DeveloperScanModel {
    private(set) var phase: DeveloperScanPhase = .idle
    private(set) var claimedBytes: Int64 = 0
    private(set) var claimedFiles = 0
    private(set) var filesExamined = 0
    private(set) var currentPath: String?
    private(set) var environmentGroups: [InventoryGroup] = []
    private(set) var skipped: [SkippedLocation] = []
    private(set) var wasCancelled = false

    /// Retained only so a Clean request can be authorized against the exact catalog subset that
    /// produced the selection — same reasoning as `ScanModel.catalog`.
    private var catalog: RuleCatalog?
    private var ruleIDByItemID: [String: String] = [:]
    private var reviewedIdentityByItemID: [String: FileIdentity] = [:]

    /// Toolbox contract (PLAN §3 IA: "Toolbox modules NEVER auto-select anything... expose
    /// maximum control"): unlike `ScanModel.selection`, this never seeds itself with safe-tier
    /// defaults. Every item here starts unchecked, on every scan and every rescan.
    var selection = InventorySelection()

    private var task: Task<Void, Never>?
    private var lastSequence = 0
    private var lastCounterUpdate = ContinuousClock.now

    var isScanning: Bool { phase == .scanning }

    var skippedSummary: String? {
        guard !skipped.isEmpty else { return nil }
        let noun = skipped.count == 1 ? "location" : "locations"
        var reasons: [String: Int] = [:]
        for entry in skipped { reasons[entry.reason.summary, default: 0] += 1 }
        let detail = reasons
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
        return "\(skipped.count) \(noun) skipped: \(detail). Sizes below exclude them."
    }

    func start() {
        guard task == nil else { return }
        phase = .scanning
        claimedBytes = 0
        claimedFiles = 0
        filesExamined = 0
        currentPath = nil
        environmentGroups = []
        skipped = []
        wasCancelled = false
        lastSequence = 0
        selection = InventorySelection()
        catalog = nil
        ruleIDByItemID = [:]
        reviewedIdentityByItemID = [:]

        let environment = ScanEnvironment.resolve()
        task = Task { [weak self] in
            let fullCatalog: RuleCatalog
            do {
                fullCatalog = try ScanService.loadCatalog(at: environment.catalogURL)
            } catch {
                self?.fail(String(describing: error))
                return
            }
            // Scoped to `developer` only: the walk never touches System Junk's `userCaches "*"`
            // catch-all or any other group's roots, so this module's numbers are its own.
            let developerCatalog = RuleCatalog(
                schemaVersion: fullCatalog.schemaVersion,
                rules: fullCatalog.rules.filter { $0.group == .developer }
            )

            let outcome = await ScanService.run(catalog: developerCatalog, home: environment.home) { [weak self] tick in
                guard let model = self else { return }
                Task { @MainActor in model.apply(tick) }
            }
            self?.finish(outcome)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func rescan() {
        cancel()
        task = nil
        start()
    }

    // MARK: - Updates

    private func apply(_ tick: ScanTick) {
        guard phase == .scanning, tick.sequence > lastSequence else { return }
        lastSequence = tick.sequence
        claimedFiles = tick.claimedFiles
        filesExamined = tick.filesExamined
        currentPath = tick.currentPath

        let now = ContinuousClock.now
        if now - lastCounterUpdate >= .seconds(SweepMotion.counterCadence) {
            lastCounterUpdate = now
            claimedBytes = tick.claimedBytes
        }
    }

    private func finish(_ outcome: ScanOutcome) {
        task = nil
        claimedBytes = outcome.claimedBytes
        claimedFiles = outcome.claimedFiles
        filesExamined = outcome.filesExamined
        environmentGroups = DeveloperEnvironmentCatalog.buildGroups(fromRuleGroups: outcome.ruleGroups)
        skipped = outcome.skipped
        wasCancelled = outcome.cancelled
        currentPath = nil
        selection = InventorySelection()
        catalog = outcome.catalog
        reviewedIdentityByItemID = outcome.reviewedIdentityByItemID
        var ruleIDByItemID: [String: String] = [:]
        for group in outcome.ruleGroups {
            for item in group.items { ruleIDByItemID[item.id] = group.id }
        }
        self.ruleIDByItemID = ruleIDByItemID
        phase = .results
    }

    private func fail(_ message: String) {
        task = nil
        currentPath = nil
        phase = .failed(message)
    }

    // MARK: - Derived copy

    var scanningCaption: String {
        "\(SweepFormat.count(filesExamined)) files examined"
    }

    // MARK: - Clean requests (identical shape to `ScanModel`'s — see `CleanAdapter.swift`)

    /// Whatever the user currently has checked. Tier-agnostic like System Junk's own request:
    /// nothing here was ever pre-checked, so every id in `selection` was a deliberate opt-in.
    func developerCleanRequest() -> (summary: CleanRequestSummary, items: [InventoryItem]) {
        let items = environmentGroups.flatMap(\.items).filter { selection.contains($0.id) }
        let summary = CleanRequestSummary(
            itemCount: items.count,
            totalBytes: items.reduce(Int64(0)) { $0 + $1.byteCount },
            volumes: VolumeGrouping.volumes(for: items)
        )
        return (summary, items)
    }

    /// What `CleanAdapter` needs — the same contract `ScanModel.cleanExecutionContext()` builds,
    /// so `DeveloperScreen`'s Clean button runs through the identical
    /// `SweepCore.CleanService`-via-`CleanAdapter` path System Junk uses (Gate 1 contract).
    func cleanExecutionContext() -> CleanExecutionContext? {
        guard let catalog else { return nil }
        return CleanExecutionContext(
            catalog: catalog, ruleIDByItemID: ruleIDByItemID,
            reviewedIdentityByItemID: reviewedIdentityByItemID,
            // The Developer lens is catalog-rule-only; clones belong to System Junk (PLAN §3).
            codeSignClonesByItemID: [:]
        )
    }
}
