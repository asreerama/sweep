import Foundation
import SweepPolicy
import SweepUninstall

/// Everything ``UninstallService/execute(_:)`` needs. Mirrors `CleanRequest`'s own shape and
/// reasoning exactly: a caller names *what* (which app, which of its leftovers, which manual
/// confirmations it collected), never *how* or *where the journal lives* — the two test-only
/// seams (`journalURL`, `home`) are unreachable outside this package for the same reason
/// `CleanRequest`'s are.
public struct UninstallRequest: Sendable {
    /// The app bundle to remove. Nothing about this path is trusted beyond "read it live and
    /// check" — see `AuthorizedUninstallPlan.authorize`.
    public let bundlePath: URL
    /// What the caller's review UI believes this bundle's `CFBundleIdentifier` is. Cross-checked
    /// against a fresh `Bundle(url:)` read of `bundlePath`, never trusted on its own.
    public let expectedBundleIdentifier: String
    /// Leftover paths the caller selected, matched by id (`LeftoverCandidate.id == url.path`)
    /// against a *server-side, independently recomputed* leftover-evidence pass — never against
    /// whatever evidence a caller's own `LeftoverCandidate` values might claim.
    public let selectedLeftoverPaths: Set<String>
    /// Per-item "the user was shown this specific leftover and explicitly confirmed it" flags
    /// (task spec's `userConfirmedManualSelection`, set by the UI per item — never a blanket
    /// confirm-everything). Only consulted for a path whose recomputed evidence is
    /// `MatchConfidence.manualReview`; ignored for anything else, so setting it for a path that
    /// does not need it grants nothing.
    public let manualOverrideConfirmedPaths: Set<String>

    /// Codex Gate-U re-review blocker #1: consent binds to OBJECTS, not path strings. The
    /// device+inode of the bundle as the review UI last showed it; authorization refuses the
    /// whole plan if the live bundle is no longer this exact object. Captured by the caller at
    /// review time (an `lstat` of what it is rendering), so a replacement renamed into the path
    /// between review and confirm is refused rather than adopted.
    public let reviewedBundleIdentity: FileIdentity
    /// Same binding per selected leftover, keyed by `selectedLeftoverPaths` entries. A selected
    /// path with no entry here — or whose live object no longer matches — is refused
    /// individually (`leftoverReviewedIdentityMissing` / `leftoverChangedSinceReview`).
    public let reviewedLeftoverIdentityByPath: [String: FileIdentity]

    let journalURL: URL
    let home: URL
    let applicationsDirectories: [URL]
    let systemLaunchDaemonsDirectory: URL

    public init(
        bundlePath: URL,
        expectedBundleIdentifier: String,
        reviewedBundleIdentity: FileIdentity,
        selectedLeftoverPaths: Set<String> = [],
        reviewedLeftoverIdentityByPath: [String: FileIdentity] = [:],
        manualOverrideConfirmedPaths: Set<String> = []
    ) {
        self.init(
            bundlePath: bundlePath,
            expectedBundleIdentifier: expectedBundleIdentifier,
            reviewedBundleIdentity: reviewedBundleIdentity,
            selectedLeftoverPaths: selectedLeftoverPaths,
            reviewedLeftoverIdentityByPath: reviewedLeftoverIdentityByPath,
            manualOverrideConfirmedPaths: manualOverrideConfirmedPaths,
            journalURL: UninstallRequest.defaultJournalURL(),
            home: FileManager.default.homeDirectoryForCurrentUser,
            applicationsDirectories: AppInventory.defaultApplicationsDirectories(),
            systemLaunchDaemonsDirectory: URL(fileURLWithPath: "/Library/LaunchDaemons")
        )
    }

    /// Test seam, mirroring `CleanRequest`'s second initializer: not reachable from outside the
    /// package.
    init(
        bundlePath: URL,
        expectedBundleIdentifier: String,
        reviewedBundleIdentity: FileIdentity,
        selectedLeftoverPaths: Set<String>,
        reviewedLeftoverIdentityByPath: [String: FileIdentity] = [:],
        manualOverrideConfirmedPaths: Set<String>,
        journalURL: URL,
        home: URL,
        applicationsDirectories: [URL],
        systemLaunchDaemonsDirectory: URL
    ) {
        self.bundlePath = bundlePath
        self.expectedBundleIdentifier = expectedBundleIdentifier
        self.reviewedBundleIdentity = reviewedBundleIdentity
        self.selectedLeftoverPaths = selectedLeftoverPaths
        self.reviewedLeftoverIdentityByPath = reviewedLeftoverIdentityByPath
        self.manualOverrideConfirmedPaths = manualOverrideConfirmedPaths
        self.journalURL = journalURL
        self.home = home
        self.applicationsDirectories = applicationsDirectories
        self.systemLaunchDaemonsDirectory = systemLaunchDaemonsDirectory
    }

    /// Deliberately a *different* file than `CleanRequest.defaultJournalURL()`: an uninstall and
    /// a junk-clean are operationally distinct concerns, and keeping their WALs separate means a
    /// crash-recovery scan for one never has to reason about the other's interrupted operations.
    static func defaultJournalURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Application Support")
        return base.appending(path: "Sweep/uninstall-journal.jsonl")
    }
}

public enum UninstallServiceError: Error, Equatable, CustomStringConvertible {
    /// Gate U (PLAN §6) is closed. ``UninstallService/gateUOpen`` is `true` in this build
    /// (opened 2026-09-01 after Fable + Codex sign-off, like Gate 1 before it), so this is now
    /// reachable only through the runtime kill switch.
    case gateClosed

    public var description: String {
        switch self {
        case .gateClosed: "Gate U has not been opened in this build; live uninstall execution is disabled"
        }
    }
}

/// Gate U's public entry point: mirrors `CleanService` in shape (`isEnabled`, environment
/// kill-switch, `execute(_:) -> AsyncThrowingStream<CleanEvent, Error>`, `runPipeline` as the
/// package-internal seam proven correct while the gate stays shut) and reuses its event/report
/// vocabulary (`CleanEvent`, `CleanItemOutcome`, `CleanReport`) rather than inventing a parallel
/// one, per the task spec's "reusing CleanEvent/report types where they fit."
///
/// `CleanReport.catalogDigest` is the one field with no natural Gate U meaning: Gate U never
/// authorizes against a `RuleCatalog`. ``noCatalogDigestSentinel`` documents that explicitly
/// rather than leaving the field looking like an omitted real value.
public enum UninstallService {
    /// OPEN as of 2026-09-01, per the same governance Gate 1 followed: three adversarial Codex
    /// review rounds (identity-bound consent, per-item confirmation, deep staged-tree
    /// validation, post-trash entry verification, honest interrupted-phase reporting), every
    /// actionable finding fixed and regression-tested, and a final explicit SAFE adjudication
    /// from Codex covering the platform-bounded residuals (Foundation's `trashItem` is
    /// pathname-only, so a same-uid attacker able to win that race could equally delete the
    /// files directly). A source constant, not state — only the runtime kill switch below can
    /// narrow it back at run time.
    static let gateUOpen = true

    /// Same two-factor shape as `CleanService.isEnabled`: the compile-time gate is necessary but
    /// not sufficient, and the runtime switch can only ever narrow it further, never widen a
    /// closed gate open.
    public static var isEnabled: Bool {
        gateUOpen && !isRuntimeDisabled()
    }

    static func isRuntimeDisabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment[runtimeKillSwitchKey] == "1"
    }

    static let runtimeKillSwitchKey = "SWEEP_UNINSTALL_SERVICE_DISABLED"

    /// See `UninstallService`'s own doc comment.
    static let noCatalogDigestSentinel = "gateU:no-rule-catalog"

    /// The pinned entry point. Throws ``UninstallServiceError/gateClosed`` before a single byte of
    /// `request` is even looked at, whenever ``isEnabled`` is `false`.
    public static func execute(_ request: UninstallRequest) -> AsyncThrowingStream<CleanEvent, Error> {
        guard isEnabled else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: UninstallServiceError.gateClosed)
            }
        }
        return runPipeline(request)
    }

    /// The real Gate U pipeline, reachable independent of the gate for the same reason
    /// `CleanService.runPipeline` is: proven correct *before* `gateUOpen` ever flips, not for the
    /// first time after. Package-internal; nothing outside `execute`'s gate check reaches it.
    static func runPipeline(
        _ request: UninstallRequest,
        isRunning: @escaping @Sendable (String) -> Bool = UninstallService.defaultIsRunning,
        now: @escaping @Sendable () -> Date = Date.init,
        quitVerification: QuitVerification? = nil,
        // Test seam: production always uses the real `pkgutil`-backed provider (the same default
        // `AuthorizedUninstallPlan.authorize` itself falls back to). Injectable here purely so a
        // test suite can avoid spawning a real `pkgutil` subprocess per run.
        receipts: PkgutilReceiptsProviding = PkgutilReceiptsProvider()
    ) -> AsyncThrowingStream<CleanEvent, Error> {
        let verification = quitVerification ?? .live(isRunning: isRunning)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await run(
                        request, isRunning: isRunning, now: now, quitVerification: verification,
                        receipts: receipts, into: continuation
                    )
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
        _ request: UninstallRequest,
        isRunning: @escaping @Sendable (String) -> Bool,
        now: @escaping @Sendable () -> Date,
        quitVerification: QuitVerification,
        receipts: PkgutilReceiptsProviding,
        into continuation: AsyncThrowingStream<CleanEvent, Error>.Continuation
    ) async throws {
        let operationID = UUID()

        // Task item 2: "quit-verification preflight (app truly not running after grace)." This
        // is independent of, and runs before, `AuthorizedUninstallPlan`'s own not-running check:
        // the app may have only just been asked to quit (`RunningAppChecker.quit`, PLAN §3 module
        // 5's "quit app... before bundle removal") and needs a moment to actually exit before
        // authorization is worth attempting at all.
        guard await quitVerification.verifyNotRunning(bundleIdentifier: request.expectedBundleIdentifier) else {
            finishSingleOutcome(
                operationID: operationID, path: request.bundlePath, tag: "gateU.bundle",
                reason: .notAuthorized,
                detail: "refused: \(request.expectedBundleIdentifier) is still running after the quit-verification grace window",
                into: continuation
            )
            return
        }

        let plan: AuthorizedUninstallPlan
        do {
            plan = try AuthorizedUninstallPlan.authorize(
                request: request, operationID: operationID, isRunning: isRunning, now: now, receipts: receipts
            )
        } catch let error as UninstallAuthorizationError {
            let (reason, description) = classify(error)
            finishSingleOutcome(
                operationID: operationID, path: request.bundlePath, tag: "gateU.bundle",
                reason: reason, detail: description, into: continuation
            )
            return
        }

        let settled: [CleanItemOutcome] = plan.unresolvedLeftovers.map { unresolved in
            let (reason, description) = classify(unresolved.error)
            return CleanItemOutcome(
                id: unresolved.path, url: URL(fileURLWithPath: unresolved.path), ruleID: nil,
                detectorSource: "gateU.leftover", tier: nil, requestedAction: nil,
                outcome: SweepCore.outcome(for: reason), failureReason: reason, trashURL: nil,
                allocatedSize: 0, detail: description
            )
        }

        let orderedItems = plan.orderedItems
        // Codex Gate-U re-review finding #9: keyed by resolved path, not identity — two
        // hard-linked leftovers share one inode but are distinct reviewed items, and an
        // identity-keyed lookup bridged the second one with the first one's evidence, tier and
        // consent provenance. Identity remains only as a fallback for a coordinator-normalized
        // spelling of the same single item.
        let itemsByPath = Dictionary(orderedItems.map { ($0.resolvedPath.path, $0) }, uniquingKeysWith: { first, _ in first })
        let itemsByIdentity = Dictionary(orderedItems.map { ($0.candidate.identity, $0) }, uniquingKeysWith: { first, _ in first })
        let anchors = plan.anchors
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

        // Codex Gate-U re-review finding #10: the count matches the completion events actually
        // emitted — refused selections (`settled`) get itemCompleted events below too.
        continuation.yield(.started(operationID: operationID, itemCount: orderedItems.count + settled.count))
        for outcome in settled { continuation.yield(.itemCompleted(outcome)) }

        // Codex Gate-U finding #4 (bundle-last transactional safety): leftovers execute first,
        // through the coordinator, in their own `DeletionPlan` — the bundle is deliberately NOT
        // part of it. Before, a single combined plan meant the bundle's own identity check ran
        // only once, moments after authorization, then sat unchecked while every leftover's real
        // rename-and-trash executed; a late bundle problem (relaunched, resigned, deep content
        // tampered) could only ever be discovered *after* leftovers were already gone. Splitting
        // the two phases is what makes a fresh revalidation "immediately before bundle staging"
        // possible at all, and what makes restoring already-trashed leftovers on refusal
        // meaningful: nothing here mutates the bundle until that revalidation passes.
        var leftoverResults: [DeletionItemResult] = []
        var leftoverJournalingDegraded = false
        // Its own operation id, distinct from the outer `operationID` this whole request reports
        // under: kept so a compensating restore below corrects THIS phase's own `itemResult`
        // records (`WALJournal.parse` tracks the latest outcome per path *within one operation
        // id*), rather than filing an orphan correction under an id that has no `planned`/
        // `started` record of its own.
        let leftoverPlanOperationID = UUID()
        if !plan.leftovers.isEmpty {
            let leftoverPlan = DeletionPlan(operationID: leftoverPlanOperationID, items: plan.leftovers.map(\.deletionItem))
            do {
                let leftoverReport = try await coordinator.execute(leftoverPlan)
                leftoverResults = leftoverReport.results
                leftoverJournalingDegraded = leftoverReport.journalingDegraded || !leftoverReport.committed
            } catch {
                // Codex Gate-U re-review (new blocker): a throw here can postdate real
                // mutations (the coordinator mutates, then throws if the WAL append fails), and
                // the per-item truth is not recoverable from the error. Rethrowing let the UI
                // fabricate a tidy zero-byte failure; instead this finishes with an honest,
                // uncommitted, journal-degraded report that says exactly that: some selected
                // items may already be in the Trash, and the journal could not record which.
                await journal.close()
                var outcomes = settled
                let interruption = CleanItemOutcome(
                    id: request.bundlePath.path, url: request.bundlePath, ruleID: nil,
                    detectorSource: "gateU.leftoverPhase", tier: nil, requestedAction: .trash,
                    outcome: .failed, failureReason: .journalUnavailable,
                    trashURL: nil, quarantineLocation: nil, allocatedSize: 0,
                    detail: "the leftover phase was interrupted (\(String(describing: error))); "
                        + "some selected leftovers may already be in the Trash, and the safety "
                        + "journal could not record which — nothing further was attempted, the "
                        + "app bundle was not touched"
                )
                outcomes.append(interruption)
                // Codex Gate-U adjudication: every outcome in the finished report must also have
                // its own itemCompleted event — a consumer that renders from the item stream
                // would otherwise never see this warning at all.
                continuation.yield(.itemCompleted(interruption))
                continuation.yield(.finished(CleanReport(
                    operationID: operationID, outcomes: outcomes, committed: false,
                    catalogDigest: noCatalogDigestSentinel, journalingDegraded: true,
                    freedBytesEstimate: 0
                )))
                return
            }
        }

        var allResults = leftoverResults
        let committed: Bool
        // Codex Gate-U re-review finding #7: the bundle phase's own journal degradation must
        // reach the final report — before, `journalingDegraded` reported only the leftover phase.
        var bundleJournalingDegraded = false

        if leftoverJournalingDegraded {
            // Mirrors the pre-existing single-plan behavior exactly (Codex G1 finding #1): a
            // degraded journal during the leftover phase means the bundle is never attempted at
            // all, and the operation is never reported as committed. The journal itself is what
            // is unreliable here, not the bundle's own safety, so already-settled leftovers are
            // left exactly as they ended up rather than compensated.
            committed = false
        } else if let revalidationError = AuthorizedUninstallPlan.revalidateBundleImmediatelyBeforeStaging(
            plan.bundle, expectedBundleIdentifier: request.expectedBundleIdentifier, isRunning: isRunning
        ) {
            // Pre-mutation refusal of the whole plan, not a per-item settle that still leaves the
            // rest trashed: every leftover that already reached the real Trash during the phase
            // above is restored, and the bundle is never staged at all.
            allResults = await restoreLeftoversAfterBundleRefusal(leftoverResults, journal: journal, operationID: leftoverPlanOperationID)
            let (reason, description) = classify(revalidationError)
            allResults.append(DeletionItemResult(
                item: plan.bundle.deletionItem, outcome: SweepCore.outcome(for: reason), failureReason: reason, detail: description
            ))
            committed = false
        } else {
            let bundlePlan = DeletionPlan(operationID: UUID(), items: [plan.bundle.deletionItem])
            do {
                let bundleReport = try await coordinator.execute(bundlePlan)
                // Codex Gate-U finding B (second re-check loop): `bundleReport.committed` only
                // says the coordinator finished writing its WAL records without a quarantine-
                // lifecycle degradation — it says nothing about whether the one item in this plan
                // actually got trashed. A settled (never-thrown) failure for the bundle item
                // itself — identity changed since authorization, policy denial, a filesystem
                // error — still comes back as `committed == true`, and before this fix that
                // settled failure was appended to the report as-is while every leftover already
                // trashed during the phase above was left gone for good. The single source of
                // truth for "did the bundle actually get removed" is the item's own outcome, not
                // the report-level commit flag.
                let bundleItemSucceeded = bundleReport.results.first?.outcome == .succeeded
                bundleJournalingDegraded = bundleReport.journalingDegraded || !bundleReport.committed
                if bundleItemSucceeded {
                    allResults.append(contentsOf: bundleReport.results)
                    committed = bundleReport.committed
                } else {
                    allResults = await restoreLeftoversAfterBundleRefusal(leftoverResults, journal: journal, operationID: leftoverPlanOperationID)
                    allResults.append(contentsOf: bundleReport.results)
                    committed = false
                }
            } catch {
                // Codex Gate-U finding B: a *thrown* bundle-phase failure is just as much "the
                // bundle did not succeed" as a settled one — the leftovers already trashed during
                // the phase above must be restored before this propagates, exactly like the
                // settled-failure and pre-mutation-revalidation-refusal branches above already do.
                // The restored report is never surfaced (this still throws, unchanged from
                // before), but the real filesystem and WAL correction this performs is not
                // optional.
                _ = await restoreLeftoversAfterBundleRefusal(leftoverResults, journal: journal, operationID: leftoverPlanOperationID)
                await journal.close()
                throw error
            }
        }

        await journal.close()

        let after = VolumeCapacity.sample(volumes: sampleVolumes)
        let freed = VolumeCapacity.freedBytesEstimate(before: before, after: after)

        var allOutcomes = settled
        var bytesSoFar: Int64 = 0
        for result in allResults {
            let outcome = CleanItemOutcome(
                uninstallResult: result,
                item: itemsByPath[result.item.url.path] ?? itemsByIdentity[result.item.identity]
            )
            allOutcomes.append(outcome)
            if result.outcome == .succeeded { bytesSoFar += result.item.allocatedSize }
            continuation.yield(.itemCompleted(outcome))
            continuation.yield(.progress(bytesSoFar: bytesSoFar))
        }

        continuation.yield(.finished(CleanReport(
            operationID: operationID, outcomes: allOutcomes, committed: committed,
            catalogDigest: noCatalogDigestSentinel,
            journalingDegraded: leftoverJournalingDegraded || bundleJournalingDegraded,
            freedBytesEstimate: freed
        )))
    }

    /// Codex Gate-U finding #4's compensating half. `DeletionCoordinator`/`TrashStaging` stage
    /// and trash a `.trash` item in one atomic step — Gate 1's shared, already-audited machinery
    /// has no "stage now, commit later" mode, and this change does not invent one inside it — so
    /// "roll back what is still in quarantine" becomes "move what already reached the real Trash
    /// back to where it came from," verified the same way every other mutation in this codebase
    /// is verified: by re-reading identity after the fact, never by trusting the move call's own
    /// success report alone. A leftover that did NOT actually reach the Trash (skipped, failed,
    /// changed) is passed through untouched — there is nothing to restore.
    private static func restoreLeftoversAfterBundleRefusal(
        _ results: [DeletionItemResult], journal: WALJournal, operationID: UUID
    ) async -> [DeletionItemResult] {
        var restored: [DeletionItemResult] = []
        restored.reserveCapacity(results.count)
        for result in results {
            guard result.outcome == .succeeded else {
                restored.append(result)
                continue
            }
            let (outcome, failureReason, detail) = restoreFromTrash(result)
            restored.append(DeletionItemResult(item: result.item, outcome: outcome, failureReason: failureReason, detail: detail))
            // Best-effort: the in-memory result above is already the source of truth for this
            // run's own report. This corrects the WAL's final recorded outcome for the item too
            // (`WALJournal.parse` keeps only the latest `itemResult` per path), so a crash-
            // recovery scan sees "restored," never a stale "succeeded" that no longer holds.
            try? await journal.appendItemResult(
                operationID: operationID, item: result.item.journalItem, outcome: outcome,
                failureReason: failureReason, trashURL: nil, quarantineURL: nil, detail: detail
            )
        }
        return restored
    }

    /// Moves a trashed leftover back to its original location and verifies it actually landed —
    /// never trusting `FileManager.moveItem`'s own success return alone, the same discipline
    /// every mutation in this codebase already follows.
    ///
    /// Codex Gate-U finding B (second re-check loop): "landed" used to mean only
    /// `FileManager.fileExists(atPath:)` — true for *anything at all* sitting at the original
    /// path, not specifically the object this operation trashed. That accepts a same-named decoy
    /// silently substituted for the real object (most plausibly by something replacing whatever
    /// sits at `trashURL` before this runs, so `moveItem` genuinely, successfully moves the wrong
    /// object into place) as a clean restore. The only proof that matters is the same one every
    /// other mutation in this codebase already requires: re-`lstat` the result and compare
    /// device/inode/type against the identity captured *before* this item was ever trashed
    /// (`result.item.identity`, read by `AuthorizedUninstallPlan.authorizeLeftovers` at
    /// authorization time) — `FileIdentity.isSameFile(as:)`'s own contract.
    private static func restoreFromTrash(_ result: DeletionItemResult) -> (ItemOutcome, ItemFailureReason, String) {
        let originalPath = result.item.url.path
        guard let trashURL = result.trashURL else {
            return (
                .movedRecoveryRequired, .rollbackFailed,
                "bundle authorization was refused after this item reached the Trash, but no restore handle "
                    + "was recorded; manual recovery required at \(originalPath)"
            )
        }
        guard !FileManager.default.fileExists(atPath: originalPath) else {
            return (
                .movedRecoveryRequired, .rollbackFailed,
                "bundle authorization was refused after this item reached the Trash, but \(originalPath) is "
                    + "already occupied; manual recovery required, item left at \(trashURL.path)"
            )
        }
        do {
            try FileManager.default.moveItem(at: trashURL, to: result.item.url)
        } catch {
            return (
                .movedRecoveryRequired, .rollbackFailed,
                "bundle authorization was refused after this item reached the Trash, and restoring it failed "
                    + "(\(error)); manual recovery required, item left at \(trashURL.path)"
            )
        }
        guard let restoredIdentity = try? FileIdentity.read(at: result.item.url) else {
            return (
                .movedRecoveryRequired, .rollbackFailed,
                "restore move reported success but \(originalPath) could not be read back afterward; manual "
                    + "recovery required"
            )
        }
        guard restoredIdentity.isSameFile(as: result.item.identity) else {
            return (
                .movedRecoveryRequired, .rollbackFailed,
                "restore move reported success, but the object now at \(originalPath) (dev \(restoredIdentity.deviceID)/"
                    + "ino \(restoredIdentity.inode)) does not match the object this operation trashed (dev "
                    + "\(result.item.identity.deviceID)/ino \(result.item.identity.inode)); manual recovery required, "
                    + "the genuine trashed object may still be reachable via a Trash lifecycle scan"
            )
        }
        return (
            .skipped, .notAuthorized,
            "restored: bundle authorization was refused immediately before bundle staging, after this leftover "
                + "had already reached the Trash; moved back from \(trashURL.path); restored identity verified "
                + "against the object trashed (dev \(restoredIdentity.deviceID)/ino \(restoredIdentity.inode))"
        )
    }

    private static func finishSingleOutcome(
        operationID: UUID, path: URL, tag: String, reason: ItemFailureReason, detail: String,
        into continuation: AsyncThrowingStream<CleanEvent, Error>.Continuation
    ) {
        let outcome = CleanItemOutcome(
            id: path.path, url: path, ruleID: nil, detectorSource: tag, tier: nil, requestedAction: nil,
            outcome: SweepCore.outcome(for: reason), failureReason: reason, trashURL: nil,
            allocatedSize: 0, detail: detail
        )
        // Codex Gate-U re-review finding #10: one completion event follows, so say so.
        continuation.yield(.started(operationID: operationID, itemCount: 1))
        continuation.yield(.itemCompleted(outcome))
        continuation.yield(.finished(CleanReport(
            operationID: operationID, outcomes: [outcome], committed: true,
            catalogDigest: noCatalogDigestSentinel, journalingDegraded: false, freedBytesEstimate: 0
        )))
    }

    /// `UninstallAuthorizationError` -> the shared `ItemFailureReason` vocabulary, mirroring
    /// `CleanItemOutcome.classify(_:)`'s own split: an actual `SweepPolicy.DenialReason` maps to
    /// `.policyDenied`, everything else (a fact about the bundle/leftover being wrong, not a
    /// policy question) maps to `.notAuthorized`.
    private static func classify(_ error: UninstallAuthorizationError) -> (ItemFailureReason, String) {
        switch error {
        case .lexicallyDenied:
            return (.policyDenied, error.description)
        case .leftoverPolicyDenied(_, let reason):
            return (.policyDenied, reason.description)
        default:
            return (.notAuthorized, error.description)
        }
    }
}

// MARK: - Quit-verification preflight

/// Task item 2: "quit-verification preflight (app truly not running after grace)." Every part is
/// injectable so a test can prove the grace-window behavior deterministically, in milliseconds,
/// without a real `Task.sleep` — mirroring how `AuthorizedCleanPlan.authorize`'s `isRunning`/`now`
/// closures are already injectable for the exact same reason.
struct QuitVerification: Sendable {
    let isRunning: @Sendable (String) -> Bool
    let now: @Sendable () -> Date
    let sleep: @Sendable (UInt64) async -> Void
    let pollIntervalNanoseconds: UInt64
    let graceDuration: TimeInterval

    /// The default a real caller gets: a real clock, a real (bounded) sleep, and a short grace
    /// window — long enough to absorb an app that was *just* asked to quit
    /// (`RunningAppChecker.quit`) finishing its own teardown, short enough that Gate U never hangs
    /// indefinitely waiting on an app that refuses to exit.
    static func live(isRunning: @escaping @Sendable (String) -> Bool) -> QuitVerification {
        QuitVerification(
            isRunning: isRunning, now: Date.init,
            sleep: { nanoseconds in try? await Task.sleep(nanoseconds: nanoseconds) },
            pollIntervalNanoseconds: 200_000_000, graceDuration: 5
        )
    }

    /// `true` immediately if the app was never running; otherwise polls until either the app
    /// stops or `graceDuration` elapses, and reports whichever is true at that point.
    func verifyNotRunning(bundleIdentifier: String) async -> Bool {
        guard isRunning(bundleIdentifier) else { return true }
        let deadline = now().addingTimeInterval(graceDuration)
        while now() < deadline {
            await sleep(pollIntervalNanoseconds)
            if !isRunning(bundleIdentifier) { return true }
        }
        return !isRunning(bundleIdentifier)
    }
}

#if canImport(AppKit)
import AppKit

extension UninstallService {
    /// The default a real caller gets for free, mirroring `AuthorizedCleanPlan.defaultIsRunning`.
    static func defaultIsRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
#else
extension UninstallService {
    static func defaultIsRunning(bundleIdentifier: String) -> Bool { false }
}
#endif

// MARK: - CleanItemOutcome bridge

extension CleanItemOutcome {
    /// The uninstall-path counterpart of `CleanItemOutcome.init(result:plan:)`: `item` (looked up
    /// by identity, since the coordinator normalizes `url`) restores Gate U's own provenance — a
    /// code-sign-clone-shaped `detectorSource` tag, a manual-override token's audit trail in
    /// `detail` — that a bare `DeletionItemResult` alone cannot carry, because none of it was ever
    /// written into `DeletionItem`/`JournalItem` (see `AuthorizedUninstallItem.deletionItem`'s doc
    /// comment for why: those types' `ruleID` slot means "a `RuleCatalog` rule claimed this," and
    /// nothing here was ever resolved against one).
    init(uninstallResult result: DeletionItemResult, item: AuthorizedUninstallItem?) {
        let detectorSource: String?
        let detail: String?
        switch item?.role {
        case .bundle:
            detectorSource = "gateU.bundle"
            detail = result.detail
        case .leftover(let evidence, let override):
            if let override {
                detectorSource = "gateU.leftover.manualOverride"
                let mintedAtDescription = ISO8601DateFormatter().string(from: override.mintedAt)
                // Codex Gate-U re-review finding #8: provenance rides WITH the executor's own
                // account of what physically happened, never in place of it — a failed or
                // compensated manual item keeps its real explanation.
                let provenance = "manual override confirmed by caller for \(override.callerPath) "
                    + "(canonical: \(override.canonicalPath), nonce: \(override.nonce.uuidString)); "
                    + "evidence=\(evidence.journalTag); mintedAt=\(mintedAtDescription)"
                detail = result.detail.map { "\($0) | \(provenance)" } ?? provenance
            } else {
                detectorSource = "gateU.leftover.auto"
                detail = result.detail ?? "evidence=\(evidence.journalTag)"
            }
        case nil:
            detectorSource = nil
            detail = result.detail
        }
        self.init(
            id: result.item.id, url: result.item.url, ruleID: result.item.ruleID, detectorSource: detectorSource,
            tier: item?.reportedTier, requestedAction: .trash, outcome: result.outcome, failureReason: result.failureReason,
            trashURL: result.trashURL, quarantineLocation: result.quarantineLocation,
            allocatedSize: result.item.allocatedSize, detail: detail
        )
    }
}
