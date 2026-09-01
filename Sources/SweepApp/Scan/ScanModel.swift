import Foundation
import Observation
import SweepCore
import SweepUI

enum ScanPhase: Equatable {
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

/// Screen state for one read-only scan, shared by Smart Scan and System Junk.
///
/// The walk itself runs on the cooperative pool inside `ScanService`; this object only receives
/// throttled ticks and the final outcome. Ticks carry a sequence number because they arrive as
/// independent hops onto the main actor, and a counter that went backwards for one frame would
/// be visible.
@MainActor
@Observable
final class ScanModel {
    private(set) var phase: ScanPhase = .idle
    private(set) var claimedBytes: Int64 = 0
    private(set) var claimedFiles = 0
    private(set) var filesExamined = 0
    private(set) var currentPath: String?
    private(set) var summaryGroups: [InventoryGroup] = []
    private(set) var ruleGroups: [InventoryGroup] = []
    private(set) var skipped: [SkippedLocation] = []
    private(set) var duration: TimeInterval = 0
    private(set) var wasCancelled = false

    // Retained only so a Clean request can be authorized against the exact catalog that produced
    // the selection, never a catalog re-read from disk. `CleanAdapter.swift` is the only other
    // file that reads this — see `cleanExecutionContext()`.
    private var catalog: RuleCatalog?
    /// Codex G1 finding #6 (NOT-CLOSED): the identity `ScanService` captured for each reviewed
    /// node's own path (never a descendant's), keyed by `InventoryItem.id`. Threaded into
    /// `CleanExecutionContext` so `CleanAdapter` can bind its depth-1 rescan candidate to the
    /// reviewed object by device+inode, not by pathname alone.
    private var reviewedIdentityByItemID: [String: FileIdentity] = [:]

    /// System Junk selection. Tier-`safe` rows come pre-selected; `caution` and `expert` never
    /// do — the user opts into those, and in this build every path terminates at the Gate 1
    /// notice anyway.
    var selection = InventorySelection()

    private let environment: ScanEnvironment
    private var task: Task<Void, Never>?
    private var lastSequence = 0
    private var lastCounterUpdate = ContinuousClock.now

    init(environment: ScanEnvironment) {
        self.environment = environment
    }

    var hasResults: Bool { phase == .results && !summaryGroups.isEmpty }
    var isScanning: Bool { phase == .scanning }

    // MARK: - Smart Scan safe-tier scope (PLAN §6b)
    //
    // `summaryGroups` are per rule-*category* (System Junk, Developer, ...) and mix every tier
    // a rule in that category matched. Smart Scan's clean scope is safe-tier only: caution items
    // are real findings worth showing, but they never count toward the number Smart Scan cleans.
    // Both views below are cheap, derived reads over the same `summaryGroups` — no second scan,
    // no separately-maintained group set that could drift from the one System Junk shows.

    /// What Smart Scan's Clean button would act on: safe-tier items only, one row per category.
    var safeSummaryGroups: [InventoryGroup] {
        InventoryAggregate.filterByTier(summaryGroups, tiers: [.safe])
    }

    /// Caution-tier findings, surfaced but never auto-selected or counted. Expert tier is hidden
    /// from Smart Scan entirely (PLAN §3: "expert (hidden by default)"), so it never reaches
    /// either view.
    var needsReviewGroups: [InventoryGroup] {
        InventoryAggregate.filterByTier(summaryGroups, tiers: [.caution])
    }

    /// The hero number Smart Scan shows and the number its Clean button would use — safe-tier
    /// bytes only, never the raw scan total.
    var safeBytes: Int64 { InventoryAggregate.totalBytes(safeSummaryGroups) }
    var safeItemCount: Int { InventoryAggregate.totalItems(safeSummaryGroups) }

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
        summaryGroups = []
        ruleGroups = []
        skipped = []
        duration = 0
        wasCancelled = false
        lastSequence = 0
        selection = InventorySelection()
        catalog = nil
        reviewedIdentityByItemID = [:]

        let environment = self.environment
        task = Task { [weak self] in
            let catalog: RuleCatalog
            do {
                catalog = try ScanService.loadCatalog(at: environment.catalogURL)
            } catch {
                self?.fail(String(describing: error))
                return
            }

            // Ticks arrive off the main actor; each one hops back on its own. `weak` unwrapped
            // into a local so the escaping tick closure never captures the mutable weak binding.
            let outcome = await ScanService.run(catalog: catalog, home: environment.home) { [weak self] tick in
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

        // The path ticker and the file count are plain text and can move at the tick rate. The
        // hero number cannot: its digit roll is an animation, and re-setting the value before
        // the roll lands restarts it, so the number never resolves. Hold it to one roll's worth.
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
        summaryGroups = outcome.summaryGroups
        ruleGroups = outcome.ruleGroups
        skipped = outcome.skipped
        duration = outcome.duration
        wasCancelled = outcome.cancelled
        currentPath = nil
        selection = .safeDefaults(in: outcome.ruleGroups)
        catalog = outcome.catalog
        reviewedIdentityByItemID = outcome.reviewedIdentityByItemID
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

    var resultsCaption: String {
        let locations = summaryGroups.reduce(0) { $0 + $1.itemCount }
        return "\(SweepFormat.count(claimedFiles)) files in \(SweepFormat.count(locations)) locations"
    }

    /// Caption under the safe-tier hero number: locations only, since `claimedFiles` is a
    /// scan-wide total that was never split by tier and would overstate the clean scope.
    var safeResultsCaption: String {
        SweepFormat.itemCount(safeItemCount)
    }

    // MARK: - Clean requests
    //
    // None of this touches `CleanService` or its pinned types: it only turns what is already on
    // screen into the `CleanRequestSummary`, item list and scan-side authorization context
    // `CleanAdapter` needs, so the one SweepCore *clean-service* touchpoint stays isolated to
    // `CleanAdapter.swift`. `catalog`/`candidates`/`candidateIDsByNodeID` are scan-side types
    // this file already depends on for the read-only scan itself.

    /// Smart Scan's clean request: safe-tier items only, regardless of anything selected
    /// elsewhere — Smart Scan does not expose per-item selection at all (PLAN §6b).
    func smartScanCleanRequest() -> (summary: CleanRequestSummary, items: [InventoryItem]) {
        request(for: safeSummaryGroups.flatMap(\.items))
    }

    /// System Junk's clean request: whatever the user currently has checked, tier-agnostic —
    /// safe rows are preselected, caution rows only appear here if the user opted in.
    func systemJunkCleanRequest() -> (summary: CleanRequestSummary, items: [InventoryItem]) {
        request(for: ruleGroups.flatMap(\.items).filter { selection.contains($0.id) })
    }

    private func request(for items: [InventoryItem]) -> (summary: CleanRequestSummary, items: [InventoryItem]) {
        let summary = CleanRequestSummary(
            itemCount: items.count,
            totalBytes: items.reduce(Int64(0)) { $0 + $1.byteCount },
            volumes: VolumeGrouping.volumes(for: items)
        )
        return (summary, items)
    }

    /// What `CleanAdapter` needs to turn `items` (the return above) into real
    /// `SweepCore.CleanRequest`s: the catalog to authorize against, and which rule claimed each
    /// item so the adapter can scope one fresh `ScanEngine` re-scan (`SweepCore.ScanRequest`
    /// stamps a whole walk with exactly one `ruleID`) per selected node.
    ///
    /// `ruleGroups` — not `summaryGroups` — is the source: it is already sectioned one-rule-
    /// per-group (`InventoryGroup.id == Rule.id`), so every item that has ever been shown
    /// anywhere in this build, safe or caution, has a rule on record here. `nil` only if a Clean
    /// button somehow fired with no scan behind it — a state every call site already prevents by
    /// disabling Clean whenever `ruleGroups`/`safeSummaryGroups` is empty.
    func cleanExecutionContext() -> CleanExecutionContext? {
        guard let catalog else { return nil }
        var ruleIDByItemID: [String: String] = [:]
        for group in ruleGroups {
            for item in group.items { ruleIDByItemID[item.id] = group.id }
        }
        return CleanExecutionContext(
            catalog: catalog, ruleIDByItemID: ruleIDByItemID, reviewedIdentityByItemID: reviewedIdentityByItemID
        )
    }
}

/// Scan-side authorization context a Clean request needs, threaded from `ScanModel` to
/// `CleanAdapter.swift` — the one file that turns it into a `SweepCore.CleanRequest`.
struct CleanExecutionContext {
    let catalog: RuleCatalog
    /// `InventoryItem.id` (a claimed node's absolute path) → the id of the rule that claimed it.
    let ruleIDByItemID: [String: String]
    /// `InventoryItem.id` → the identity `ScanService` captured for that exact node at scan time
    /// (Codex G1 finding #6, NOT-CLOSED). `CleanAdapter` binds its depth-1 rescan candidate to
    /// this by device+inode, never by pathname alone, so a decoy occupying the reviewed path can
    /// never be laundered through as if it were the reviewed item.
    let reviewedIdentityByItemID: [String: FileIdentity]
}
