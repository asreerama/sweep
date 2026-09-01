import Foundation
import SweepCore
import SweepUI

/// The one place SweepApp touches SweepCore's `CleanService` (BUILDLOG.md, "Pinned API
/// contract"). Everything else in the Clean flow — the confirm/progress/report views,
/// `CleanFlowModel`, the `CleanBackend` protocol they run against — lives in `SweepUI` and
/// imports nothing from SweepCore (see `CleanFlow.swift`). Every Clean entry point in the app
/// (`SmartScanScreen`, `SystemJunkScreen`) checks `CleanAdapter.isEnabled`, never `SweepCore`
/// directly, so this file is the only one that needs to change if `CleanService` drifts further.
///
/// ## What actually landed vs. the pinned shape
///
/// BUILDLOG.md pinned `execute(_ request: CleanRequest) -> AsyncThrowingStream<CleanEvent>` as
/// though a request were just a catalog and a selection. What SweepCore actually shipped
/// (`Packages/SweepCore/Sources/SweepCore/CleanService.swift`) needs a real `SweepCore.ScanResult`
/// too — and `ScanResult`/`ScanSummary` deliberately have **no public initializer**
/// (confirmed by SweepCore's own `PublicSurfaceCleanServiceTests.swift`: "a real scan is the only
/// way to get one"). An external caller cannot hand `CleanRequest` a hand-built scan; it has to
/// run one.
///
/// This adapter follows that contract literally: for each selected node it runs one fresh,
/// narrowly-scoped `ScanEngine.run(ScanRequest(roots: [nodeURL], ruleID:))` — re-validating the
/// node's on-disk state at clean time, not trusting the original scan's now-stale candidates —
/// then builds one `CleanRequest` selecting everything that scan found, and executes it. One
/// node, one scan, one request, one `CleanService.execute` call; a multi-node Clean request is a
/// sequence of these, aggregated into the single `SweepUI.CleanEvent` stream `CleanFlowModel`
/// expects. This costs one extra directory walk per node versus reusing the original scan's
/// candidates, which is the honest price of a public API that cannot be handed synthesized scan
/// data — and it is a *better* trash-time guarantee, not just a workaround, since a node deleted
/// or changed since the review screen was drawn is caught here rather than acted on stale.
struct CleanAdapter: CleanBackend {
    static var isEnabled: Bool { SweepCore.CleanService.isEnabled }

    private let context: CleanExecutionContext
    private let items: [InventoryItem]

    /// - Parameters:
    ///   - context: `ScanModel.cleanExecutionContext()` — the catalog and rule-id-per-item map
    ///     the scan that produced `items` already has.
    ///   - items: Exactly the nodes the confirm sheet showed (`smartScanCleanRequest()` /
    ///     `systemJunkCleanRequest()`'s second return value), so a report row can carry the same
    ///     title and byte count the user already confirmed.
    init(context: CleanExecutionContext, items: [InventoryItem]) {
        self.context = context
        self.items = items
    }

    func execute(itemIDs: Set<String>) -> AsyncThrowingStream<SweepUI.CleanEvent, Error> {
        let itemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        // Deterministic order: report rows land in the same order across runs, which is what
        // makes a report screenshot or a bug repro reproducible.
        let orderedIDs = itemIDs.sorted()
        let totalBytes = orderedIDs.reduce(Int64(0)) { $0 + (itemsByID[$1]?.byteCount ?? 0) }

        return AsyncThrowingStream { continuation in
            let task = Task {
                var remainingBytes = totalBytes
                var remainingItems = orderedIDs.count
                var outcomes: [SweepUI.CleanItemOutcome] = []
                var freedBytes: Int64 = 0

                for id in orderedIDs {
                    guard let item = itemsByID[id] else { continue }
                    outcomes.append(await cleanOne(id: id, item: item, freedBytes: &freedBytes))

                    remainingBytes = max(0, remainingBytes - item.byteCount)
                    remainingItems = max(0, remainingItems - 1)
                    continuation.yield(.progress(CleanProgressUpdate(
                        remainingBytes: remainingBytes,
                        remainingItems: remainingItems,
                        currentItemCaption: item.title
                    )))

                    if Task.isCancelled { break }
                }

                let succeededCount = outcomes.count { if case .succeeded = $0.status { true } else { false } }
                continuation.yield(.finished(SweepUI.CleanReport(
                    freedBytes: freedBytes, succeededCount: succeededCount, outcomes: outcomes
                )))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - One node

    /// Re-scans exactly `item`'s subtree, builds one `CleanRequest` selecting everything that
    /// scan found, and runs it through `CleanService`. Adds this node's freed bytes to
    /// `freedBytes` on success; never throws — every failure mode (no rule on record, the fresh
    /// scan itself failing, `CleanService` reporting a per-item failure) becomes a `.failed`
    /// outcome for this one row instead of aborting the whole request.
    private func cleanOne(
        id: String, item: InventoryItem, freedBytes: inout Int64
    ) async -> SweepUI.CleanItemOutcome {
        guard let ruleID = context.ruleIDByItemID[id] else {
            return SweepUI.CleanItemOutcome(
                id: id, title: item.title, byteCount: item.byteCount,
                status: .failed(reason: "No rule on record for this item; re-run the scan and try again.")
            )
        }

        do {
            let freshScan = try await ScanEngine().run(
                ScanRequest(roots: [URL(fileURLWithPath: id)], ruleID: ruleID)
            )
            let request = SweepCore.CleanRequest(
                catalog: context.catalog,
                scan: freshScan,
                selectedCandidateIDs: Set(freshScan.candidates.map(\.id))
            )

            var failureReason: String?
            for try await event in SweepCore.CleanService.execute(request) {
                switch event {
                case .started, .progress:
                    break
                case .itemCompleted(let outcome):
                    if outcome.outcome != .succeeded, failureReason == nil {
                        failureReason = Self.describe(outcome)
                    }
                case .finished(let report):
                    // The capacity-delta estimate for *this* node's own scan+clean pass — see
                    // the type doc for why this is N independent estimates summed rather than
                    // one measured across the whole batch.
                    freedBytes += report.freedBytesEstimate
                }
            }

            if let failureReason {
                return SweepUI.CleanItemOutcome(
                    id: id, title: item.title, byteCount: item.byteCount, status: .failed(reason: failureReason)
                )
            }
            return SweepUI.CleanItemOutcome(id: id, title: item.title, byteCount: item.byteCount, status: .succeeded)
        } catch {
            return SweepUI.CleanItemOutcome(
                id: id, title: item.title, byteCount: item.byteCount, status: .failed(reason: String(describing: error))
            )
        }
    }

    // MARK: - Failure descriptions

    private static func describe(_ outcome: SweepCore.CleanItemOutcome) -> String {
        if let reason = outcome.failureReason { return describe(reason) }
        return outcome.detail ?? "Did not complete."
    }

    private static func describe(_ reason: SweepCore.ItemFailureReason) -> String {
        switch reason {
        case .permissionDenied: "Permission denied."
        case .policyDenied: "Protected by policy."
        case .outsideFixtureRoot, .outsideAuthorizedRoot: "Outside the authorized root."
        case .identityChanged: "Changed since scan; skipped for safety."
        case .vanished: "No longer exists."
        case .tierViolation: "Not a safe-tier item."
        case .filesystemError: "Filesystem error."
        case .notAttempted: "Not attempted."
        case .actionNotPermitted: "Action not permitted."
        case .notAuthorized: "Could not be authorized."
        }
    }
}
