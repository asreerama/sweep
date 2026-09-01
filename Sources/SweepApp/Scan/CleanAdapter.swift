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
/// though a request were just a catalog and a selection. `SweepCore.CleanRequest` takes neither a
/// caller-supplied catalog (Codex Gate-1 finding #1: `CleanService` loads and hash-pins the
/// bundled catalog itself) nor a raw `SweepCore.ScanResult` (finding #6): it takes
/// `[SweepCore.SelectionReceipt]`, opaque proof — mintable only from a real `ScanEngine` run —
/// about exactly the paths under consideration.
///
/// Earlier, this adapter re-scanned each selected node *as a scan root* and selected every
/// candidate that walk found. Codex's Gate-1 review (finding #6, "release blocker") caught why
/// that is wrong: `FileManagerVolumeWalker` enumerates only a root's children, never the root
/// itself, so scanning the node as its own root either found nothing to select (a file can never
/// be a scan root) or silently reselected the node's *entire subtree* — content the user never
/// individually reviewed — instead of the one node they actually confirmed.
///
/// This adapter instead runs one fresh, narrowly-scoped `ScanEngine.run` per selected node — the
/// node's *parent* directory, at `maximumDepth: 1` — which re-visits the confirmed node itself as
/// a depth-1 child of that walk without ever descending into it, works identically for a file or
/// a directory, and re-validates exactly the node's own on-disk state at clean time rather than
/// trusting the original scan's now-stale candidate. The single receipt for that one node (never
/// its siblings, which the walk also sees but this adapter discards) is what
/// `SweepCore.CleanRequest` receives; `SweepCore.CleanService` then re-verifies that receipt's
/// identity live, including owner UID, before ever authorizing it. One node, one narrow scan, one
/// receipt, one request, one `CleanService.execute` call; a multi-node Clean request is a
/// sequence of these, aggregated into the single `SweepUI.CleanEvent` stream `CleanFlowModel`
/// expects.
struct CleanAdapter: CleanBackend {
    static var isEnabled: Bool { SweepCore.CleanService.isEnabled }

    private let context: CleanExecutionContext
    private let items: [InventoryItem]
    /// Test-only seam (Codex G1 finding #8): defaults to the real, gated public entry point.
    /// `gate1Open` is a hardcoded `false` `static let` in every build, including test builds —
    /// there is no way to flip it, and this adapter must not grow one. What a test *can* do is
    /// substitute SweepCore's own internal `CleanService.runPipeline`, reachable only via
    /// `@testable import SweepCore` from a test target, so a `CleanAdapter`-level test can drive
    /// the real authorization/execution/WAL pipeline end to end against a disposable fixture
    /// without the gate ever being touched in application code.
    private let executePipeline: @Sendable (SweepCore.CleanRequest) -> AsyncThrowingStream<SweepCore.CleanEvent, Error>

    /// - Parameters:
    ///   - context: `ScanModel.cleanExecutionContext()` — the catalog and rule-id-per-item map
    ///     the scan that produced `items` already has.
    ///   - items: Exactly the nodes the confirm sheet showed (`smartScanCleanRequest()` /
    ///     `systemJunkCleanRequest()`'s second return value), so a report row can carry the same
    ///     title and byte count the user already confirmed.
    init(context: CleanExecutionContext, items: [InventoryItem]) {
        self.init(context: context, items: items, executePipeline: SweepCore.CleanService.execute)
    }

    /// Test seam. Not called from anywhere in application code — every real call site uses the
    /// initializer above, which always wires up the real, gated `CleanService.execute`. There is
    /// deliberately no test-only *home* override alongside this one: `SweepCore.CleanRequest`'s
    /// `home:`/`journalURL:` parameters are internal to SweepCore for the same reason a real
    /// caller can never reach them — a production adapter that could redirect operation roots
    /// away from the real account home would itself be a policy bypass. A `CleanAdapter`-level
    /// fixture test therefore targets a disposable subdirectory of the tester's own real
    /// `~/Library/Logs`, exactly as `AuthorizedCleanPlanTests` already reasons `.userLogs` is
    /// safe to exercise directly, rather than this adapter gaining a second, parallel code path
    /// the real app never runs.
    init(
        context: CleanExecutionContext,
        items: [InventoryItem],
        executePipeline: @escaping @Sendable (SweepCore.CleanRequest) -> AsyncThrowingStream<SweepCore.CleanEvent, Error>
    ) {
        self.context = context
        self.items = items
        self.executePipeline = executePipeline
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

    /// Re-verifies exactly `item` — never a subtree under or around it — and, if it still
    /// matches, runs a `CleanRequest` carrying only its sealed receipt through `CleanService`.
    /// Adds this node's freed bytes to `freedBytes` on success; never throws: every failure mode
    /// (no rule on record, the node no longer existing, a decoy occupying its path, `CleanService`
    /// reporting a per-item failure) becomes a `.failed` outcome for this one row instead of
    /// aborting the whole request.
    ///
    /// The re-verification scan is scoped to `item`'s *parent* directory at `maximumDepth: 1`:
    /// the confirmed node itself is a depth-1 child of that walk (whether it is a file or a
    /// directory), so it is seen without the walk ever descending into it — no per-node re-scan
    /// machinery, and no risk of silently reselecting an unreviewed subtree (Codex G1 finding #6).
    ///
    /// Codex G1 finding #6 (NOT-CLOSED): the depth-1 candidate at the reviewed path used to be
    /// trusted on pathname alone, so whatever now occupies that path (not necessarily the object
    /// the user reviewed) got a receipt minted for it. `context.reviewedIdentityByItemID` carries
    /// the device+inode `ScanService` captured for `item` at scan time; the candidate this rescan
    /// finds at the same path must match it by identity, not merely by name, or the item is
    /// refused with a distinct "changed since review" outcome.
    private func cleanOne(
        id: String, item: InventoryItem, freedBytes: inout Int64
    ) async -> SweepUI.CleanItemOutcome {
        guard let ruleID = context.ruleIDByItemID[id] else {
            return SweepUI.CleanItemOutcome(
                id: id, title: item.title, byteCount: item.byteCount,
                status: .failed(reason: "No rule on record for this item; re-run the scan and try again.")
            )
        }
        guard let reviewedIdentity = context.reviewedIdentityByItemID[id] else {
            return SweepUI.CleanItemOutcome(
                id: id, title: item.title, byteCount: item.byteCount,
                status: .failed(reason: "No rule on record for this item; re-run the scan and try again.")
            )
        }

        do {
            let nodeURL = URL(fileURLWithPath: id)
            let parentURL = nodeURL.deletingLastPathComponent()
            let verificationScan = try await ScanEngine().run(
                ScanRequest(roots: [parentURL], maximumDepth: 1, ruleID: ruleID)
            )
            let standardizedNodePath = nodeURL.standardizedFileURL.path
            guard let candidateAtPath = verificationScan.candidates.first(where: {
                $0.url.standardizedFileURL.path == standardizedNodePath
            }) else {
                return SweepUI.CleanItemOutcome(
                    id: id, title: item.title, byteCount: item.byteCount,
                    status: .failed(reason: "No longer exists or no longer matches its rule; skipped for safety.")
                )
            }
            // The binding itself: device+inode equality with the identity captured at review
            // time, never pathname alone. A mismatch means a different object now occupies this
            // exact path: refused, distinct from "vanished."
            guard candidateAtPath.identity.isSameFile(as: reviewedIdentity) else {
                return SweepUI.CleanItemOutcome(
                    id: id, title: item.title, byteCount: item.byteCount,
                    status: .failed(reason: "Changed since review: a different item now occupies this location; skipped for safety.")
                )
            }
            guard let receipt = verificationScan.receipt(forCandidateID: candidateAtPath.id) else {
                return SweepUI.CleanItemOutcome(
                    id: id, title: item.title, byteCount: item.byteCount,
                    status: .failed(reason: "No longer exists or no longer matches its rule; skipped for safety.")
                )
            }

            // Codex G1 finding #5: seal exactly this one receipt into a batch embedding the
            // catalog digest `CleanService` will check at execute time and a mint timestamp it
            // will check for freshness. Never a bare receipt handed straight to `CleanRequest`.
            let catalogDigest = try SweepCore.CleanService.currentCatalogDigest()
            let batch = try verificationScan.sealedBatch(selecting: [receipt.id], catalogDigest: catalogDigest)
            let request = SweepCore.CleanRequest(batch: batch, selectedCandidateIDs: [receipt.id])

            var failureReason: String?
            for try await event in executePipeline(request) {
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
        case .rollbackFailed: "Moved to quarantine but could not be recovered."
        case .journalUnavailable: "Could not be safely logged; skipped for safety."
        }
    }
}
