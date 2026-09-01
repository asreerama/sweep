import Foundation
import SweepPolicy

// MARK: - Public request/event/report surface (BUILDLOG.md "Pinned API contract")

/// Everything ``CleanService/execute(_:)`` needs, and nothing it can be tricked by.
///
/// Codex Gate-1 finding #1: this used to also carry a caller-supplied `catalog: RuleCatalog`,
/// which let any caller define what a rule id means. There is no `catalog` parameter any more —
/// `CleanService` loads and hash-pins the bundled catalog itself (``CleanService/loadPinnedBundledCatalog()``)
/// and is the only thing inside SweepCore that ever calls `RuleCatalogLoader.loadBundled`.
///
/// Finding #6: `scan`/`selectedCandidateIDs` (a whole `ScanResult` plus a set of ids to pick out
/// of it) is gone too, replaced by ``receipts``: opaque proof, mintable only from a real scan,
/// about exactly the paths under consideration. There is no way to hand this type a tier, an
/// action, or a path that was not already the URL inside a `ScanCandidate` a scan produced —
/// resolving a selection into something executable happens entirely inside `CleanService`,
/// through a live re-verification of each receipt and then ``AuthorizedCleanPlan``.
public struct CleanRequest: Sendable {
    /// Exactly what the review screen showed, as unforgeable receipts from a real scan. Never a
    /// raw `ScanResult`: a caller cannot re-scope what "the reviewed scan" means by handing in a
    /// differently-selected result, because a receipt is fine-grained to one path already.
    public let receipts: [SelectionReceipt]
    /// Code-sign-clone candidates the caller wants considered, from a separate
    /// ``CodeSignCloneDetector`` pass (deliverable #1c's parallel authorized path). Empty by
    /// default: most requests are catalog-rule-only.
    public let codeSignClones: [CodeSignCloneCandidate]
    /// IDs the *caller* selected, matched against `receipts` and `codeSignClones` by
    /// ``SelectionReceipt/id``/``CodeSignCloneCandidate/id``. An id that matches neither is
    /// reported as an unresolvable outcome, never silently ignored and never treated as "select
    /// everything offered".
    public let selectedCandidateIDs: Set<String>

    /// Where the WAL for this run lives. Not part of the public initializer — a caller names
    /// *what* to clean, never *where the journal is kept*; the second initializer below exists
    /// purely so tests can point it at a disposable fixture location.
    let journalURL: URL
    /// The home directory `SweepPolicy` resolves symbolic roots against. Not part of the public
    /// initializer, for the same reason: real callers always mean the real account Sweep is
    /// running as. Test-only override, mirroring `SweepPolicy.authorize`'s own `home:` parameter.
    let home: URL

    public init(
        receipts: [SelectionReceipt],
        codeSignClones: [CodeSignCloneCandidate] = [],
        selectedCandidateIDs: Set<String>
    ) {
        self.init(
            receipts: receipts,
            codeSignClones: codeSignClones,
            selectedCandidateIDs: selectedCandidateIDs,
            journalURL: CleanRequest.defaultJournalURL(),
            home: FileManager.default.homeDirectoryForCurrentUser
        )
    }

    /// Test seam. Not reachable from outside the package: the public initializer above is the
    /// only one an external caller can name.
    init(
        receipts: [SelectionReceipt],
        codeSignClones: [CodeSignCloneCandidate] = [],
        selectedCandidateIDs: Set<String>,
        journalURL: URL,
        home: URL
    ) {
        self.receipts = receipts
        self.codeSignClones = codeSignClones
        self.selectedCandidateIDs = selectedCandidateIDs
        self.journalURL = journalURL
        self.home = home
    }

    static func defaultJournalURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "Sweep/clean-journal.jsonl")
    }
}

/// One item's outcome, whether it was ever attempted or not. `id` matches the id the caller
/// selected it by, so the UI can reconcile every requested id against exactly one outcome.
public struct CleanItemOutcome: Sendable, Equatable, Identifiable {
    public let id: String
    /// `nil` only when `id` did not resolve to anything in the request at all.
    public let url: URL?
    public let ruleID: String?
    public let detectorSource: String?
    /// `nil` only when authorization never got far enough to know the rule's tier.
    public let tier: Tier?
    public let requestedAction: RuleAction?
    public let outcome: ItemOutcome
    public let failureReason: ItemFailureReason?
    /// Restore handle for a trashed item.
    public let trashURL: URL?
    /// Set only when `outcome == .movedRecoveryRequired` (review finding #5): the item left its
    /// original location and landed here, but could be neither trashed nor rolled back.
    public let quarantineLocation: URL?
    public let allocatedSize: Int64
    public let detail: String?

    init(
        id: String,
        url: URL?,
        ruleID: String?,
        detectorSource: String?,
        tier: Tier?,
        requestedAction: RuleAction?,
        outcome: ItemOutcome,
        failureReason: ItemFailureReason?,
        trashURL: URL?,
        quarantineLocation: URL? = nil,
        allocatedSize: Int64,
        detail: String?
    ) {
        self.id = id
        self.url = url
        self.ruleID = ruleID
        self.detectorSource = detectorSource
        self.tier = tier
        self.requestedAction = requestedAction
        self.outcome = outcome
        self.failureReason = failureReason
        self.trashURL = trashURL
        self.quarantineLocation = quarantineLocation
        self.allocatedSize = allocatedSize
        self.detail = detail
    }

    /// A selected id that matched nothing in the request.
    init(unresolvedID id: String) {
        self.init(
            id: id, url: nil, ruleID: nil, detectorSource: nil, tier: nil, requestedAction: nil,
            outcome: .skipped, failureReason: .notAuthorized, trashURL: nil, allocatedSize: 0,
            detail: "no candidate or code-sign-clone with this id was in the request"
        )
    }

    /// ``AuthorizedCleanPlan`` construction failed before a plan ever existed.
    init(candidate: ScanCandidate, ruleID: String?, detectorSource: String?, authorizationError error: any Error) {
        let (reason, description) = CleanItemOutcome.classify(error)
        self.init(
            id: candidate.id, url: candidate.url, ruleID: ruleID, detectorSource: detectorSource,
            tier: nil, requestedAction: nil, outcome: SweepCore.outcome(for: reason), failureReason: reason,
            trashURL: nil, allocatedSize: candidate.allocatedSize, detail: description
        )
    }

    /// A ``SelectionReceipt``'s live re-verification (finding #6) or authorization failed before
    /// a plan ever existed — the receipt-path counterpart of the `candidate:` initializer above,
    /// used when there is no fresh `ScanCandidate` to report from because verification itself is
    /// what failed.
    init(receipt: SelectionReceipt, authorizationError error: any Error) {
        let (reason, description) = CleanItemOutcome.classify(error)
        self.init(
            id: receipt.id, url: receipt.url, ruleID: receipt.ruleID, detectorSource: nil,
            tier: nil, requestedAction: nil, outcome: SweepCore.outcome(for: reason), failureReason: reason,
            trashURL: nil, allocatedSize: receipt.allocatedSize, detail: description
        )
    }

    private static func classify(_ error: any Error) -> (ItemFailureReason, String) {
        guard let authError = error as? AuthorizationError else {
            return (.notAuthorized, String(describing: error))
        }
        let reason: ItemFailureReason
        switch authError {
        case .policyDenied: reason = .policyDenied
        case .identityChangedSinceScan(_, let vanished): reason = vanished ? .vanished : .identityChanged
        default: reason = .notAuthorized
        }
        return (reason, authError.description)
    }

    /// Hard-filtered out after authorization succeeded (tier, action, or denylist re-check).
    init(skipping plan: AuthorizedCleanPlan, reason: ItemFailureReason, detail: String) {
        self.init(
            id: plan.id, url: plan.candidate.url, ruleID: plan.ruleID, detectorSource: plan.detectorSource,
            tier: plan.tier, requestedAction: plan.action, outcome: .skipped, failureReason: reason,
            trashURL: nil, allocatedSize: plan.candidate.allocatedSize, detail: detail
        )
    }

    /// A real ``DeletionCoordinator`` result. `plan` (looked up by identity, since the
    /// coordinator normalizes `url` and a raw id match can miss) restores the rule id /
    /// detector-source fidelity that a bare `DeletionItem` alone would lose for a
    /// code-sign-clone-sourced item (whose `DeletionItem.ruleID` is `nil` by construction).
    init(result: DeletionItemResult, plan: AuthorizedCleanPlan?) {
        self.init(
            id: result.item.id,
            url: result.item.url,
            ruleID: plan?.ruleID ?? result.item.ruleID,
            detectorSource: plan?.detectorSource,
            tier: plan?.tier ?? result.item.tier,
            requestedAction: plan?.action ?? .trash,
            outcome: result.outcome,
            failureReason: result.failureReason,
            trashURL: result.trashURL,
            quarantineLocation: result.quarantineLocation,
            allocatedSize: result.item.allocatedSize,
            detail: result.detail
        )
    }
}

/// The finished result of one `CleanService.execute` call.
public struct CleanReport: Sendable, Equatable {
    public let operationID: UUID
    public let outcomes: [CleanItemOutcome]
    public let committed: Bool
    /// From a volume-capacity delta (`statfs` before/after), never scan-time sizes — PLAN §2:
    /// "freed" is only ever reported this way, and only ever as an estimate. Zero when nothing
    /// was actually attempted.
    public let freedBytesEstimate: Int64

    public var succeededCount: Int { outcomes.count { $0.outcome == .succeeded } }
    public var failedCount: Int { outcomes.count { $0.outcome == .failed } }
    public var skippedCount: Int { outcomes.count { $0.outcome == .skipped } }
    public var changedCount: Int { outcomes.count { $0.outcome == .changed } }
    /// Restore handles for everything that actually reached the Trash.
    public var trashRestoreURLs: [URL] { outcomes.compactMap(\.trashURL) }
}

public enum CleanEvent: Sendable {
    case started(operationID: UUID, itemCount: Int)
    case itemCompleted(CleanItemOutcome)
    case progress(bytesSoFar: Int64)
    case finished(CleanReport)
}

public enum CleanServiceError: Error, Equatable, CustomStringConvertible {
    /// Gate 1 (PLAN §6) has not been opened in this build.
    case gateClosed

    public var description: String {
        switch self {
        case .gateClosed:
            "Gate 1 has not been opened in this build; live cleaning is disabled"
        }
    }
}

// MARK: - CleanService

/// Gate 1's public entry point (BUILDLOG.md "Pinned API contract"): the only way anything outside
/// this package can ever mutate a real filesystem path.
///
/// `execute` resolves every selected id to an ``AuthorizedCleanPlan`` (rule-authorized per
/// review finding #9), hard-filters to `tier == .safe` and `action == .trash` regardless of what
/// the rule or the caller says elsewhere, re-checks the denylist, and only then runs the survivors
/// through ``DeletionCoordinator`` in its `trashOnly` mode — an executor with no delete method,
/// journaled through the existing WAL.
public enum CleanService {
    /// Flipped by Fable, and only by Fable, after the Gate 1 line review + Codex adversarial
    /// review both sign off (PLAN §6, BUILDLOG.md wave G1). Stays `false` for the whole of this
    /// change. Nothing in this file, or anywhere else in SweepCore, sets it — it is a source
    /// constant, not state.
    static let gate1Open = false

    /// `true` only when the compile-time gate above is open **and** the independent runtime
    /// kill-switch is not set. The two can only ever narrow each other: flipping `gate1Open` to
    /// `true` is necessary but not sufficient, and the runtime switch can disable an
    /// already-opened gate (an operational rollback that needs no rebuild) but can never enable a
    /// closed one. Same "injection can only add a denial" shape as ``DenyCheck``.
    public static var isEnabled: Bool {
        gate1Open && !isRuntimeDisabled()
    }

    /// Environment-variable kill switch, checked independently of `gate1Open`. Exists so an
    /// operator can disable live cleaning (`SWEEP_CLEAN_SERVICE_DISABLED=1`) without a rebuild —
    /// useful the moment gate 1 is open and something is later found wrong with it. Injectable
    /// for tests; the public surface always uses the real environment.
    static func isRuntimeDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[runtimeKillSwitchKey] == "1"
    }

    static let runtimeKillSwitchKey = "SWEEP_CLEAN_SERVICE_DISABLED"

    /// The pinned entry point. Throws ``CleanServiceError/gateClosed`` immediately, before a
    /// single candidate is even looked at, whenever ``isEnabled`` is `false`.
    public static func execute(_ request: CleanRequest) -> AsyncThrowingStream<CleanEvent, Error> {
        guard isEnabled else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: CleanServiceError.gateClosed)
            }
        }
        return runPipeline(request)
    }

    /// The real Gate 1 pipeline, split out from `execute` so it is testable against fixture trees
    /// on its own — the whole point of building this defensively *before* the gate opens is that
    /// the pipeline is fully proven the moment `gate1Open` flips, not proven for the first time
    /// after. Package-internal only; nothing outside `execute`'s gate check reaches it.
    static func runPipeline(_ request: CleanRequest) -> AsyncThrowingStream<CleanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(request, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Pipeline body

    private static func run(
        _ request: CleanRequest,
        into continuation: AsyncThrowingStream<CleanEvent, Error>.Continuation
    ) async throws {
        // Codex G1 finding #1: the catalog is never the caller's. Loaded, hash-pinned and
        // validated fresh for this run, before a single receipt is even looked at.
        let pinned = try loadPinnedBundledCatalog()
        let catalog = pinned.catalog

        let receiptsByID = Dictionary(request.receipts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let clonesByID = Dictionary(request.codeSignClones.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var authorized: [AuthorizedCleanPlan] = []
        var settled: [CleanItemOutcome] = []

        for id in request.selectedCandidateIDs.sorted() {
            if let receipt = receiptsByID[id] {
                guard let ruleID = receipt.ruleID else {
                    settled.append(CleanItemOutcome(receipt: receipt, authorizationError: AuthorizationError.noRuleID))
                    continue
                }
                do {
                    // Finding #6: re-verify identity live (fresh lstat, full `FileIdentity`
                    // including owner UID) instead of trusting the receipt's scan-time snapshot
                    // or re-scanning the subtree under it. `AuthorizedCleanPlan.authorize` then
                    // runs its usual gauntlet (root/pattern rematch, age, running-app) against
                    // this freshly-verified candidate.
                    let liveCandidate = try Self.liveVerifiedCandidate(for: receipt)
                    authorized.append(try AuthorizedCleanPlan.authorize(
                        ruleID: ruleID, candidate: liveCandidate, catalog: catalog, home: request.home
                    ))
                } catch {
                    settled.append(CleanItemOutcome(receipt: receipt, authorizationError: error))
                }
            } else if let clone = clonesByID[id] {
                do {
                    authorized.append(try AuthorizedCleanPlan.authorize(codeSignClone: clone, home: request.home))
                } catch {
                    settled.append(CleanItemOutcome(
                        candidate: clone.candidate, ruleID: nil, detectorSource: clone.detectorSource,
                        authorizationError: error
                    ))
                }
            } else {
                settled.append(CleanItemOutcome(unresolvedID: id))
            }
        }

        // HARD FILTERS. Independent of anything the rule or the authorization step already
        // decided: even a correctly-authorized plan is only executed here if it clears all three.
        var toExecute: [AuthorizedCleanPlan] = []
        var plansByIdentity: [FileIdentity: AuthorizedCleanPlan] = [:]
        for plan in authorized {
            guard plan.tier == .safe else {
                settled.append(CleanItemOutcome(
                    skipping: plan, reason: .tierViolation,
                    detail: "tier \(plan.tier.rawValue) is not safe; Gate 1 runs safe-tier items only"
                ))
                continue
            }
            guard plan.action == .trash else {
                settled.append(CleanItemOutcome(
                    skipping: plan, reason: .actionNotPermitted,
                    detail: "action \(plan.action.rawValue) is not trash; Gate 1 is trash-only"
                ))
                continue
            }
            guard !SweepPolicy.isDeniedLexically(plan.candidate.url) else {
                settled.append(CleanItemOutcome(skipping: plan, reason: .policyDenied, detail: "denylist re-check"))
                continue
            }
            plansByIdentity[plan.candidate.identity] = plan
            toExecute.append(plan)
        }

        let operationID = UUID()
        continuation.yield(.started(operationID: operationID, itemCount: toExecute.count))
        for outcome in settled {
            continuation.yield(.itemCompleted(outcome))
        }

        guard !toExecute.isEmpty else {
            continuation.yield(.finished(CleanReport(
                operationID: operationID, outcomes: settled, committed: true, freedBytesEstimate: 0
            )))
            return
        }

        var anchorsByKey: [TrashAnchorKey: TrashOnlyAnchor] = [:]
        for plan in toExecute { anchorsByKey[plan.anchor.key] = plan.anchor }
        let anchors = Array(anchorsByKey.values)
        let sampleVolumes = Set(anchors.map(\.url))
        let before = VolumeCapacity.sample(volumes: sampleVolumes)

        let journal = try await WALJournal(url: request.journalURL)
        let coordinator: DeletionCoordinator
        do {
            coordinator = try DeletionCoordinator(mode: .trashOnly(anchors: anchors), journal: journal)
        } catch {
            await journal.close()
            throw error
        }

        // Codex G1 finding #4: the plan must carry the *same* operation id already emitted in
        // `.started` above (and used in the final `.finished` report below) — not a fresh one of
        // its own, which is what let the WAL disagree with the service's own report.
        let plan = DeletionPlan(operationID: operationID, items: toExecute.map { DeletionItem(authorized: $0) })
        let report: DeletionReport
        do {
            report = try await coordinator.execute(plan)
        } catch {
            await journal.close()
            throw error
        }
        await journal.close()

        let after = VolumeCapacity.sample(volumes: sampleVolumes)
        let freed = VolumeCapacity.freedBytesEstimate(before: before, after: after)

        var allOutcomes = settled
        var bytesSoFar: Int64 = 0
        for result in report.results {
            let outcome = CleanItemOutcome(result: result, plan: plansByIdentity[result.item.identity])
            allOutcomes.append(outcome)
            if result.outcome == .succeeded { bytesSoFar += result.item.allocatedSize }
            continuation.yield(.itemCompleted(outcome))
            continuation.yield(.progress(bytesSoFar: bytesSoFar))
        }

        continuation.yield(.finished(CleanReport(
            operationID: operationID, outcomes: allOutcomes, committed: report.committed, freedBytesEstimate: freed
        )))
    }

    /// Codex G1 finding #6: the live re-verification a ``SelectionReceipt`` exists for. Reads
    /// `receipt.url` fresh, right now, and refuses unless it is *fully* identical (device, inode,
    /// kind, mtime, ctime, size, link count, flags **and owner UID**) to what the receipt says
    /// the reviewed scan saw — strictly stronger than the plain identity check the rest of the
    /// pipeline uses elsewhere, because a receipt can be handed to `CleanService` an arbitrary
    /// amount of time after the scan that produced it. The live identity — not the receipt's
    /// stale one — is what gets carried into authorization from here on.
    private static func liveVerifiedCandidate(for receipt: SelectionReceipt) throws -> ScanCandidate {
        let current: FileIdentity
        do {
            current = try FileIdentity.read(at: receipt.url, volume: receipt.scannedIdentity.volume)
        } catch let error as FileIdentityError {
            throw AuthorizationError.identityChangedSinceScan(path: receipt.url.path, vanished: error.isNotFound)
        }
        guard current.isFullyIdentical(to: receipt.scannedIdentity) else {
            throw AuthorizationError.identityChangedSinceScan(path: receipt.url.path, vanished: false)
        }
        return ScanCandidate(
            url: receipt.url,
            identity: current,
            parentIdentity: receipt.scannedParentIdentity,
            allocatedSize: receipt.allocatedSize,
            ruleID: receipt.ruleID
        )
    }
}

// MARK: - Capacity-delta estimate (PLAN §2: "freed" is only ever a post-op capacity delta)

enum VolumeCapacity {
    static func availableCapacity(at url: URL) -> Int64? {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
            .volumeAvailableCapacityForImportantUsage
    }

    static func sample(volumes: Set<URL>) -> [String: Int64] {
        var result: [String: Int64] = [:]
        for volume in volumes {
            if let value = availableCapacity(at: volume) {
                result[volume.path] = value
            }
        }
        return result
    }

    /// Pure function: sums the bytes gained on every volume present in both snapshots. A
    /// per-volume delta can go negative from unrelated activity between the two `statfs` calls;
    /// that is never allowed to offset a gain elsewhere; it is floored at zero instead of summed
    /// signed, so the estimate never claims more than what individually improved.
    static func freedBytesEstimate(before: [String: Int64], after: [String: Int64]) -> Int64 {
        var total: Int64 = 0
        for (volume, beforeValue) in before {
            guard let afterValue = after[volume] else { continue }
            total += max(0, afterValue - beforeValue)
        }
        return total
    }
}
