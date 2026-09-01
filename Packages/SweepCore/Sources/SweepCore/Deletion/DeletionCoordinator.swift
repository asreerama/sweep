import Darwin
import Foundation
import SweepPolicy

// Gate 1 (PLAN §6) opens live execution. The token stays internal and undocumented until
// Fable signs that gate off; outside this package `.live` cannot be spelled at all.
struct LiveExecutionToken: Sendable {
    init() {}
}

/// Where the coordinator is allowed to operate.
///
/// Three modes exist:
/// - `fixtureOnly`: every path must sit strictly under one disposable fixture root. Test support
///   only, reached from outside the package solely through ``FixtureExecution``, which owns the
///   root it creates (review finding #1).
/// - `trashOnly`: Gate 1 (PLAN §6). Every path must sit under one of a fixed set of
///   authorization-derived real roots, and only the trash verb is reachable — the executor for
///   this mode, ``TrashOnlyFileDescriptorExecutor``, has no delete method to call at all. The
///   constructor is internal; only ``CleanService`` (also inside this package) builds one, and
///   only from ``AuthorizedCleanPlan``s.
/// - `live`: gate 2, not yet open. `LiveExecutionToken` cannot be named outside the package, so
///   `.live` cannot be spelled by an external caller.
public struct DeletionMode: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case fixtureOnly(URL)
        case trashOnly([TrashOnlyAnchor])
        /// Gate 2 (PLAN §6, not yet open — `CleanService.gate2Open` stays `false`): the mirror
        /// image of `trashOnly`. Every path must sit under one of a fixed set of
        /// authorization-derived real roots, and only the delete verb is reachable — the
        /// executor for this mode, ``DirectDeleteExecutor``, has no trash method at all.
        case directDelete([TrashOnlyAnchor])
        case live
    }

    let kind: Kind

    private init(kind: Kind) {
        self.kind = kind
    }

    /// Confines the coordinator to a disposable fixture tree.
    static func fixtureOnly(root: URL) -> DeletionMode {
        DeletionMode(kind: .fixtureOnly(root.resolvingSymlinksInPath().standardizedFileURL))
    }

    /// Confines the coordinator to the given authorization-derived roots, trash verb only.
    /// `anchors` must already be the product of a successful ``SweepPolicy`` authorization —
    /// this does not re-derive or re-check anything, it only anchors what the caller already
    /// proved (``AuthorizedCleanPlan``).
    static func trashOnly(anchors: [TrashOnlyAnchor]) -> DeletionMode {
        DeletionMode(kind: .trashOnly(anchors))
    }

    /// Gate 2 (PLAN §6, not yet open): confines the coordinator to the given
    /// authorization-derived roots, delete verb only. Mirrors `trashOnly(anchors:)` exactly with
    /// the verb swapped — reached today only from inside this package (``CleanService``'s
    /// gate-2-open branch, and this package's own tests), never from outside it, same as
    /// `trashOnly` itself.
    static func directDelete(anchors: [TrashOnlyAnchor]) -> DeletionMode {
        DeletionMode(kind: .directDelete(anchors))
    }

    static func live(_ token: LiveExecutionToken) -> DeletionMode {
        DeletionMode(kind: .live)
    }

    var fixtureRoot: URL? {
        if case .fixtureOnly(let root) = kind { return root }
        return nil
    }
}

/// Additional deny predicate layered *on top of* ``SweepPolicy``. Injection can only add
/// denials; it can never remove one, so a test double cannot weaken the backstop.
public struct DenyCheck: Sendable {
    private let predicate: @Sendable (URL) -> Bool

    public init(_ predicate: @escaping @Sendable (URL) -> Bool) {
        self.predicate = predicate
    }

    public static let none = DenyCheck { _ in false }

    func isDenied(_ url: URL) -> Bool { predicate(url) }
}

public enum DeletionError: Error, Equatable, CustomStringConvertible {
    case unsupportedPlanVersion(Int)
    case emptyPlan
    case outsideFixtureRoot(path: String, fixtureRoot: String)
    case tierViolation(path: String, tier: Tier)
    case liveModeNotEnabled
    case journalUnavailable(String)
    case fixtureRootUnavailable(String)
    /// Gate 1 plan-level refusal: an item does not sit under any of `trashOnly`'s authorized
    /// roots. The whole plan is refused before anything is journaled — same "fail closed on the
    /// whole plan" discipline `outsideFixtureRoot` already applies to fixture mode.
    case outsideAuthorizedRoots(path: String)
    /// Gate 1 plan-level refusal: an item in a `trashOnly` plan requests an action other than
    /// `trash`. This is the first of two independent gates against a delete slipping into
    /// trash-only mode — the second is that the mode's executor has no delete method at all.
    case actionNotPermittedInTrashOnlyMode(path: String, action: DeletionAction)
    /// `trashOnly`'s authorized root could not be re-opened by descriptor at anchor time (it
    /// vanished, or a component along the way is no longer a directory).
    case anchorUnavailable(String)
    /// `trashOnly`'s authorized root changed identity between the moment ``SweepPolicy``
    /// authorized it and the moment the coordinator opened it by descriptor — the same
    /// time-of-check/time-of-use gap the leaf-level descriptor descent already closes, applied
    /// to the root itself.
    case anchorIdentityChanged(String)
    /// Gate 2 (PLAN §6): the mirror image of `actionNotPermittedInTrashOnlyMode` — a
    /// `directDelete` plan's item requests an action other than `delete`. Structurally backstopped
    /// the same way trash-only mode is: ``DirectDeleteExecutor`` has no trash method at all.
    case actionNotPermittedInDirectDeleteMode(path: String, action: DeletionAction)
    /// Gate 2's requirement beyond Gate 1: a `directDelete` item's rule did not declare
    /// `undo == .regenerated`. Direct deletion is unrecoverable, so this is required and checked
    /// independently of the tier check every mode already applies.
    case undoNotRegeneratedForDirectDelete(path: String)

    public var description: String {
        switch self {
        case .unsupportedPlanVersion(let version):
            "plan version \(version) is not executable; this build runs \(DeletionPlan.currentVersion)"
        case .emptyPlan:
            "plan has no items"
        case .outsideFixtureRoot(let path, let root):
            "refused: \(path) is not under the fixture root \(root)"
        case .tierViolation(let path, let tier):
            "refused: action=delete requires tier=safe, item \(path) is tier=\(tier.rawValue)"
        case .liveModeNotEnabled:
            "live execution is gated (PLAN §6, gate 1) and cannot run in this build"
        case .journalUnavailable(let reason):
            "aborted before touching the filesystem: \(reason)"
        case .fixtureRootUnavailable(let reason):
            "cannot anchor the fixture root: \(reason)"
        case .outsideAuthorizedRoots(let path):
            "refused: \(path) is not under any root this operation authorized"
        case .actionNotPermittedInTrashOnlyMode(let path, let action):
            "refused: \(path) requests action=\(action.rawValue), but trash-only mode never runs anything but trash"
        case .anchorUnavailable(let reason):
            "cannot anchor an authorized root: \(reason)"
        case .anchorIdentityChanged(let reason):
            "an authorized root changed identity before it could be anchored: \(reason)"
        case .actionNotPermittedInDirectDeleteMode(let path, let action):
            "refused: \(path) requests action=\(action.rawValue), but direct-delete mode never runs anything but delete"
        case .undoNotRegeneratedForDirectDelete(let path):
            "refused: \(path)'s rule does not declare undo == regenerated; direct delete requires it"
        }
    }
}

/// The only type in Sweep permitted to mutate the filesystem.
///
/// Every item goes through the same gauntlet, in this order: plan-level validation, fixture
/// containment, policy denylist backstop, a pathname pre-check of identity, then a descriptor
/// walk from the anchored root that re-validates every component and the leaf before issuing the
/// syscall. The write-ahead log is durable before each step that can lose information, and a
/// journal write that fails aborts the operation rather than proceeding unlogged.
///
/// The pathname checks in `perform` are fail-fast only. The authority is the descriptor walk
/// inside ``FileDescriptorExecutor``, because between any two pathname operations a directory
/// can be renamed and replaced.
public actor DeletionCoordinator {
    private let mode: DeletionMode
    private let journal: any JournalWriting
    private let extraDenials: DenyCheck
    /// `nil` only for Gate 2's `directDelete` mode, which has no trash-capable executor at all —
    /// mirrors `directDeleteExecutor` below being `nil` for every other mode.
    private let executor: (any TrashCapable)?
    /// Gate 2 (PLAN §6, not yet open): populated only for `directDelete` mode. Deliberately not
    /// unified with `executor` above — `DirectDeleteCapable` does not conform to `TrashCapable`,
    /// so the two stored properties are the type-level proof that a `directDelete` coordinator
    /// instance is holding something with no trash method to call, the same way `executor` being
    /// a `TrashOnlyFileDescriptorExecutor` in `trashOnly` mode is the proof there is no delete
    /// method to call.
    private let directDeleteExecutor: (any DirectDeleteCapable)?
    /// Descriptor opened once, at init, on the fixture root. Held for the coordinator's life:
    /// every mutation is resolved relative to this inode, not to the pathname it was opened from.
    /// `nil` for `trashOnly` (which holds its descriptors inside `executor` instead, one per
    /// anchor) and for `live` (nothing is ever opened before gate 2).
    private let anchor: OpenDirectory?
    private let queue: BlockingIOQueue
    /// Codex G1 finding #1 (CONTROLLING): set by `perform(_:operationID:)` when a
    /// quarantine-lifecycle append (`staged`/`trashed`/`rollbackFailed`) fails even after a
    /// retry. Read and reset by `execute(_:)` once per item; never persists across `execute`
    /// calls. Actor-isolated state rather than a `perform` return-type change, so every one of
    /// `perform`'s many existing return points stays exactly as it was. Only the one path that
    /// can actually degrade journaling durability sets this.
    private var journalingDegraded = false

    init(mode: DeletionMode, journal: WALJournal, additionalDenials: DenyCheck = .none) throws {
        let queue = BlockingIOQueue(label: "com.sweep.deletion.io")

        switch mode.kind {
        case .fixtureOnly(let root):
            let anchor: OpenDirectory
            do {
                anchor = try OpenDirectory.openRoot(root)
            } catch {
                throw DeletionError.fixtureRootUnavailable(String(describing: error))
            }
            self.init(
                mode: mode,
                journal: journal,
                additionalDenials: additionalDenials,
                executor: FileDescriptorExecutor(root: anchor, queue: queue),
                anchor: anchor,
                queue: queue
            )

        case .trashOnly(let anchors):
            var opened: [TrashAnchorKey: OpenDirectory] = [:]
            for trashAnchor in anchors {
                let directory: OpenDirectory
                do {
                    directory = try OpenDirectory.openRoot(trashAnchor.url)
                } catch {
                    throw DeletionError.anchorUnavailable(String(describing: error))
                }
                // Review finding #2's discipline, applied to the root itself: the identity
                // `SweepPolicy` authorized against is re-checked the instant the descriptor is
                // open, closing the gap between "authorize() proved this" and "we anchored it".
                guard let actual = try? directory.identity(), actual.pathIdentity == trashAnchor.identity else {
                    throw DeletionError.anchorIdentityChanged(trashAnchor.url.path)
                }
                opened[trashAnchor.key] = directory
            }
            self.init(
                mode: mode,
                journal: journal,
                additionalDenials: additionalDenials,
                executor: TrashOnlyFileDescriptorExecutor(anchors: opened, queue: queue),
                anchor: nil,
                queue: queue
            )

        case .directDelete(let anchors):
            // Mirrors the `trashOnly` case above exactly, verb swapped: the same per-root
            // descriptor open plus identity re-check (review finding #2's discipline applied to
            // the root itself), duplicated deliberately rather than shared, so Gate 1's audited
            // anchor-opening loop is never touched by Gate 2's addition.
            var opened: [TrashAnchorKey: OpenDirectory] = [:]
            for directDeleteAnchor in anchors {
                let directory: OpenDirectory
                do {
                    directory = try OpenDirectory.openRoot(directDeleteAnchor.url)
                } catch {
                    throw DeletionError.anchorUnavailable(String(describing: error))
                }
                guard let actual = try? directory.identity(), actual.pathIdentity == directDeleteAnchor.identity else {
                    throw DeletionError.anchorIdentityChanged(directDeleteAnchor.url.path)
                }
                opened[directDeleteAnchor.key] = directory
            }
            self.init(
                mode: mode,
                journal: journal,
                additionalDenials: additionalDenials,
                executor: nil,
                directDeleteExecutor: DirectDeleteExecutor(anchors: opened, queue: queue),
                anchor: nil,
                queue: queue
            )

        case .live:
            self.init(
                mode: mode,
                journal: journal,
                additionalDenials: additionalDenials,
                executor: NoMutation(),
                anchor: nil,
                queue: queue
            )
        }
    }

    /// Test seam (in addition to `executor:`): `journal:` here is `any JournalWriting`, not a
    /// concrete `WALJournal`, precisely so a test can substitute a double that fails specific
    /// append kinds on demand (Codex G1 finding #1). Every real caller still only ever passes a
    /// genuine `WALJournal` (which conforms), through the public initializer above.
    init(
        mode: DeletionMode,
        journal: any JournalWriting,
        additionalDenials: DenyCheck = .none,
        executor: (any TrashCapable)? = nil,
        directDeleteExecutor: (any DirectDeleteCapable)? = nil,
        anchor: OpenDirectory? = nil,
        queue: BlockingIOQueue = BlockingIOQueue(label: "com.sweep.deletion.io")
    ) {
        self.mode = mode
        self.journal = journal
        self.extraDenials = additionalDenials
        self.executor = executor
        self.directDeleteExecutor = directDeleteExecutor
        self.anchor = anchor
        self.queue = queue
    }

    /// Validate and execute. Throws before any mutation when the plan itself is unacceptable;
    /// per-item refusals are reported in the returned ``DeletionReport``, not thrown.
    @discardableResult
    public func execute(_ plan: DeletionPlan) async throws -> DeletionReport {
        try validate(plan)
        journalingDegraded = false

        do {
            try await journal.appendPlanned(
                operationID: plan.operationID,
                planVersion: plan.version,
                items: plan.items.map(\.journalItem),
                catalogDigest: plan.catalogDigest
            )
            try await journal.appendStarted(operationID: plan.operationID)
        } catch {
            throw DeletionError.journalUnavailable(String(describing: error))
        }

        var results: [DeletionItemResult] = []
        results.reserveCapacity(plan.items.count)

        for item in plan.items {
            let result = await perform(item, operationID: plan.operationID)
            do {
                try await journal.appendItemResult(
                    operationID: plan.operationID,
                    item: item.journalItem,
                    outcome: result.outcome,
                    failureReason: result.failureReason,
                    trashURL: result.trashURL,
                    quarantineURL: result.quarantineLocation,
                    detail: result.detail
                )
            } catch {
                // Abort-on-journal-write-failure: stop immediately, leave the operation
                // uncommitted so the next recovery scan surfaces it.
                results.append(result)
                throw DeletionError.journalUnavailable(String(describing: error))
            }
            results.append(result)

            if journalingDegraded {
                // Codex G1 finding #1: a quarantine-lifecycle append survived neither its first
                // attempt nor its retry. `result` above is already durable in the `itemResult`
                // record just appended. The in-flight item finished normally, but the
                // supplementary quarantine-lifecycle trail a stranded-slot recovery pass depends
                // on is not, so the operation stops here rather than mutating anything else
                // against a journal that just proved it cannot keep up. Never reported as a
                // clean commit.
                if let executor { await executor.finishOperation(plan.operationID) }
                return DeletionReport(
                    operationID: plan.operationID, results: results, committed: false, journalingDegraded: true
                )
            }
        }

        do {
            try await journal.appendCommitted(operationID: plan.operationID, detail: nil)
        } catch {
            throw DeletionError.journalUnavailable(String(describing: error))
        }

        // Best-effort hygiene, after the operation is durably committed: an empty per-operation
        // quarantine directory (review finding #3) is removed rather than left to accumulate
        // forever. A directory that still holds a stranded slot is never touched here — that is
        // exactly what `QuarantineRecovery` exists to surface. `directDelete` mode has no
        // quarantine directory at all (nothing was ever staged), so there is nothing to finish.
        if let executor { await executor.finishOperation(plan.operationID) }

        return DeletionReport(operationID: plan.operationID, results: results, committed: true)
    }

    // MARK: - Plan-level validation (fail closed, before anything is written)

    func validate(_ plan: DeletionPlan) throws {
        guard plan.version == DeletionPlan.currentVersion else {
            throw DeletionError.unsupportedPlanVersion(plan.version)
        }
        guard !plan.items.isEmpty else { throw DeletionError.emptyPlan }

        switch mode.kind {
        case .live:
            throw DeletionError.liveModeNotEnabled
        case .fixtureOnly(let root):
            for item in plan.items where !Self.isStrictlyContained(item.url, in: root) {
                throw DeletionError.outsideFixtureRoot(path: item.url.path, fixtureRoot: root.path)
            }
        case .trashOnly(let anchors):
            for item in plan.items {
                guard Self.matchingAnchor(for: item.url, among: anchors) != nil else {
                    throw DeletionError.outsideAuthorizedRoots(path: item.url.path)
                }
                // First of two independent gates against a delete reaching trash-only mode; the
                // second is that `TrashOnlyFileDescriptorExecutor` has no delete method at all
                // (see `perform`, step 5).
                guard item.action == .trash else {
                    throw DeletionError.actionNotPermittedInTrashOnlyMode(path: item.url.path, action: item.action)
                }
            }

        case .directDelete(let anchors):
            // Gate 2 (PLAN §6): the mirror image of `trashOnly` above, verb swapped, plus the
            // extra requirement direct deletion carries beyond Gate 1 (unrecoverable, so the
            // rule must have declared `undo == .regenerated`, re-checked here independently of
            // whatever `CleanService` already decided when it chose this mode for the item).
            for item in plan.items {
                guard Self.matchingAnchor(for: item.url, among: anchors) != nil else {
                    throw DeletionError.outsideAuthorizedRoots(path: item.url.path)
                }
                // First of two independent gates against a trash reaching direct-delete mode;
                // the second is that `DirectDeleteExecutor` has no trash method at all (see
                // `perform`, step 5).
                guard item.action == .delete else {
                    throw DeletionError.actionNotPermittedInDirectDeleteMode(path: item.url.path, action: item.action)
                }
                guard item.undo == .regenerated else {
                    throw DeletionError.undoNotRegeneratedForDirectDelete(path: item.url.path)
                }
            }
        }

        for item in plan.items where item.action == .delete && item.tier != .safe {
            throw DeletionError.tierViolation(path: item.url.path, tier: item.tier)
        }
    }

    /// The first `trashOnly` anchor whose root strictly contains `url`. Mirrors
    /// ``isStrictlyContained(_:in:)``'s symlink-on-parent-only resolution, so an anchor is judged
    /// the same way fixture containment is.
    static func matchingAnchor(for url: URL, among anchors: [TrashOnlyAnchor]) -> TrashOnlyAnchor? {
        anchors.first { isStrictlyContained(url, in: $0.url) }
    }

    /// Resolves symlinks on the *parent* only, so a symlink item is judged where it lives
    /// rather than where it points, and `/var` vs `/private/var` cannot smuggle a path out.
    ///
    /// Lexical and therefore advisory: it runs before the log is written so an obviously bad plan
    /// is refused early. Containment is *proved* by the descriptor descent, which cannot be
    /// raced.
    static func isStrictlyContained(_ url: URL, in root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolved = parent.appending(path: url.lastPathComponent).standardizedFileURL
        guard resolved.path != resolvedRoot.path else { return false }
        return resolved.path.hasPrefix(resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/")
    }

    // MARK: - Per-item execution

    private func perform(_ item: DeletionItem, operationID: UUID) async -> DeletionItemResult {
        // 1. Mode containment, re-checked per item. Plan validation already covers this; the
        //    duplicate is deliberate defense in depth around the only mutating call site.
        let components: [String]
        let anchorRoot: TrashAnchorKey?
        // Best-effort, for the pre-mutation stage journal entry only (review finding #5): the
        // real anchor is whichever `OpenDirectory` the executor itself holds, re-resolved by
        // descriptor inside `TrashStaging`. This is never used to decide anything, only to
        // compose a human/recovery-readable path alongside the deterministic slot name.
        let anchorRootPath: String

        switch mode.kind {
        case .fixtureOnly(let root):
            guard Self.isStrictlyContained(item.url, in: root),
                  let resolved = FileDescriptorPath.relativeComponents(of: item.url, under: root)
            else {
                return DeletionItemResult(
                    item: item,
                    outcome: .skipped,
                    failureReason: .outsideFixtureRoot,
                    detail: "not under fixture root \(root.path)"
                )
            }
            components = resolved
            anchorRoot = nil
            anchorRootPath = root.path

        case .trashOnly(let anchors):
            guard let matched = Self.matchingAnchor(for: item.url, among: anchors),
                  let resolved = FileDescriptorPath.relativeComponents(of: item.url, under: matched.url)
            else {
                return DeletionItemResult(
                    item: item,
                    outcome: .skipped,
                    failureReason: .outsideAuthorizedRoot,
                    detail: "not under any root this operation authorized"
                )
            }
            // Second, independent gate (the first is plan-level `validate`): even if a delete
            // item somehow reached this point, the executor for this mode has no delete method
            // to call it with (see step 5).
            guard item.action == .trash else {
                return DeletionItemResult(
                    item: item,
                    outcome: .skipped,
                    failureReason: .actionNotPermitted,
                    detail: "action \(item.action.rawValue) is not reachable in trash-only mode"
                )
            }
            components = resolved
            anchorRoot = matched.key
            anchorRootPath = matched.url.path

        case .directDelete(let anchors):
            guard let matched = Self.matchingAnchor(for: item.url, among: anchors),
                  let resolved = FileDescriptorPath.relativeComponents(of: item.url, under: matched.url)
            else {
                return DeletionItemResult(
                    item: item,
                    outcome: .skipped,
                    failureReason: .outsideAuthorizedRoot,
                    detail: "not under any root this operation authorized"
                )
            }
            // Second, independent gate (the first is plan-level `validate`): even if a trash
            // item somehow reached this point, the executor for this mode has no trash method
            // to call it with (see step 5).
            guard item.action == .delete else {
                return DeletionItemResult(
                    item: item,
                    outcome: .skipped,
                    failureReason: .actionNotPermitted,
                    detail: "action \(item.action.rawValue) is not reachable in direct-delete mode"
                )
            }
            // Gate 2's requirement beyond Gate 1, re-checked here as well as in plan-level
            // `validate`: direct deletion is unrecoverable, so it is refused unless the rule
            // declared `undo == .regenerated`.
            guard item.undo == .regenerated else {
                return DeletionItemResult(
                    item: item,
                    outcome: .skipped,
                    failureReason: .directDeleteRequirementNotMet,
                    detail: "direct delete requires the rule's undo capability to be regenerated"
                )
            }
            components = resolved
            anchorRoot = matched.key
            anchorRootPath = matched.url.path

        case .live:
            return DeletionItemResult(
                item: item,
                outcome: .skipped,
                failureReason: .notAttempted,
                detail: "live mode is not enabled"
            )
        }

        // 2. Policy backstop. The producer should never have offered a denied path; if it did,
        //    that is a bug, and the bug must not delete anything. The lexical check is the cheap
        //    half; `authorize` is the identity-resolving half and is what actually decides.
        if SweepPolicy.isDeniedLexically(item.url) || extraDenials.isDenied(item.url) {
            return DeletionItemResult(
                item: item,
                outcome: .skipped,
                failureReason: .policyDenied,
                detail: "denied by policy"
            )
        }
        if let denial = await policyDenial(for: item) {
            return DeletionItemResult(
                item: item,
                outcome: .skipped,
                failureReason: .policyDenied,
                detail: denial
            )
        }

        // 3. Tier check at the mutation site as well as in plan validation.
        if item.action == .delete, item.tier != .safe {
            return DeletionItemResult(
                item: item,
                outcome: .skipped,
                failureReason: .tierViolation,
                detail: "delete requires tier=safe"
            )
        }

        // 4. Pathname pre-check of identity. Cheap, and it turns the common "it vanished" and
        //    "someone rewrote it" cases into a refusal before any descriptor is opened. It is
        //    *not* the authority: step 5 re-validates through the anchored descriptor chain.
        do {
            let current = try FileIdentity.read(at: item.url, volume: item.identity.volume)
            guard current.isSameFile(as: item.identity) else {
                return DeletionItemResult(
                    item: item,
                    outcome: .changed,
                    failureReason: .identityChanged,
                    detail: "identity changed: expected dev \(item.identity.deviceID)/ino \(item.identity.inode), "
                        + "found dev \(current.deviceID)/ino \(current.inode)"
                )
            }
            guard current.isUnchanged(from: item.identity) else {
                return DeletionItemResult(
                    item: item,
                    outcome: .changed,
                    failureReason: .identityChanged,
                    detail: "item mutated since scan (mtime, ctime, size, flags or link count differs)"
                )
            }
        } catch let error as FileIdentityError {
            return DeletionItemResult(
                item: item,
                outcome: error.isNotFound ? .skipped : .failed,
                failureReason: error.isNotFound ? .vanished : failureReason(for: error),
                detail: error.description
            )
        } catch {
            return DeletionItemResult(
                item: item,
                outcome: .failed,
                failureReason: .filesystemError,
                detail: String(describing: error)
            )
        }

        // 5. Mutate, through descriptors only.
        let request = MutationRequest(
            url: item.url,
            relativeComponents: components,
            expected: item.identity,
            expectedParent: item.parentIdentity,
            anchorRoot: anchorRoot,
            operationID: operationID
        )
        do {
            switch item.action {
            case .trash:
                // `executor` is `nil` only for Gate 2's `directDelete` mode, which plan-level
                // `validate` (and the step-1 re-check above) already refuse a `.trash` item from
                // ever reaching — this guard is the second, independent gate, and a type fact
                // (there is no trash-capable executor to call) rather than a checked flag. Placed
                // before anything is journaled, so an (unreachable in practice) miss here never
                // writes a stagePlanned record for a slot that will never be used.
                guard let executor else {
                    return DeletionItemResult(
                        item: item,
                        outcome: .skipped,
                        failureReason: .actionNotPermitted,
                        detail: "this mode's executor cannot trash"
                    )
                }
                // Review finding #5: a record identifying the deterministic slot this item is
                // about to be renamed into is made durable *before* the executor ever runs —
                // closing "the item is renamed into quarantine before any record identifies its
                // slot." The name is computed the same way `TrashStaging` computes it, from the
                // object's own device/inode, so the two can never drift.
                let approximateQuarantineURL = URL(fileURLWithPath: anchorRootPath)
                    .appending(path: FileDescriptorExecutor.quarantineDirectoryName)
                    .appending(path: operationID.uuidString)
                    .appending(path: TrashStaging.slotName(for: item.identity))
                    .appending(path: item.url.lastPathComponent)

                do {
                    try await journal.appendStagePlanned(
                        operationID: operationID, item: item.journalItem, quarantineURL: approximateQuarantineURL
                    )
                } catch {
                    // Codex G1 finding #1 (CONTROLLING): this is the only quarantine-lifecycle
                    // record written *before* any mutation. Suppressing its failure (the old
                    // `try?`) let staging proceed with no durable slot record at all. Fail closed
                    // instead: refuse the item outright, before `executor.trash` is ever called.
                    // Nothing here has touched the filesystem yet, so there is nothing to roll
                    // back, only a mutation that must never begin unlogged.
                    return DeletionItemResult(
                        item: item,
                        outcome: .failed,
                        failureReason: .journalUnavailable,
                        detail: "stagePlanned could not be journaled; refused before staging: \(String(describing: error))"
                    )
                }

                do {
                    let trashURL = try await executor.trash(request)
                    // The rename into the slot above is now known to have succeeded (the executor
                    // would have thrown otherwise), and so is the subsequent `trashItem` call.
                    // These two records describe a mutation that already happened. The item
                    // itself is not undone by a journal failure here, so a failure that survives
                    // one retry degrades the whole *operation* instead (`journalingDegraded`,
                    // checked by `execute(_:)`), rather than being suppressed.
                    if await !appendQuarantineRecordDegradingOnFailure({
                        try await self.journal.appendStaged(
                            operationID: operationID, item: item.journalItem, quarantineURL: approximateQuarantineURL
                        )
                    }) {
                        journalingDegraded = true
                    }
                    if await !appendQuarantineRecordDegradingOnFailure({
                        try await self.journal.appendTrashed(
                            operationID: operationID, item: item.journalItem, trashURL: trashURL
                        )
                    }) {
                        journalingDegraded = true
                    }
                    return DeletionItemResult(item: item, outcome: .succeeded, trashURL: trashURL)
                } catch let descriptorError as FileDescriptorError {
                    if case .strandedInQuarantine(let quarantinePath, _, let rollbackReason) = descriptorError {
                        // Staging succeeded — the item really did move — but it could be neither
                        // trashed nor rolled back. This is never suppressed: it is journaled in
                        // its own right, distinct from (and in addition to) the `itemResult`
                        // record `execute(_:)` appends right after this returns.
                        if await !appendQuarantineRecordDegradingOnFailure({
                            try await self.journal.appendStaged(
                                operationID: operationID, item: item.journalItem, quarantineURL: approximateQuarantineURL
                            )
                        }) {
                            journalingDegraded = true
                        }
                        if await !appendQuarantineRecordDegradingOnFailure({
                            try await self.journal.appendRollbackFailed(
                                operationID: operationID, item: item.journalItem,
                                quarantineURL: URL(fileURLWithPath: quarantinePath), reason: rollbackReason
                            )
                        }) {
                            journalingDegraded = true
                        }
                        return DeletionItemResult(
                            item: item,
                            outcome: .movedRecoveryRequired,
                            failureReason: .rollbackFailed,
                            quarantineLocation: URL(fileURLWithPath: quarantinePath),
                            detail: descriptorError.description
                        )
                    }
                    throw descriptorError
                }
            case .delete:
                // Gate 2 (PLAN §6): `directDelete` mode's executor is checked first. It has no
                // trash method at all (`DirectDeleteCapable` does not conform to `TrashCapable`),
                // so this is the only route into it; `directDeleteExecutor` is `nil` for every
                // other mode, so this branch is simply never taken outside `directDelete`.
                if let directDeleteExecutor {
                    try await directDeleteExecutor.delete(request)
                    return DeletionItemResult(item: item, outcome: .succeeded)
                }
                // `executor` is typed `(any TrashCapable)?`; only a `FileMutating` conformer (the
                // fixture-mode executor) can also delete. `TrashOnlyFileDescriptorExecutor`
                // never conforms to `FileMutating` — it has no delete method — so this cast
                // fails for every instance of it, unconditionally. Plan-level `validate` already
                // refuses a delete item in trash-only mode before this line is ever reached; this
                // is the second, independent gate, and it is a type fact, not a checked flag.
                guard let deletingExecutor = executor as? any FileMutating else {
                    return DeletionItemResult(
                        item: item,
                        outcome: .skipped,
                        failureReason: .actionNotPermitted,
                        detail: "this mode's executor cannot delete"
                    )
                }
                try await deletingExecutor.delete(request)
                return DeletionItemResult(item: item, outcome: .succeeded)
            }
        } catch {
            let reason = failureReason(for: error)
            return DeletionItemResult(
                item: item,
                outcome: outcome(for: reason),
                failureReason: reason,
                detail: (error as? FileDescriptorError)?.description ?? (error as NSError).localizedDescription
            )
        }
    }

    /// Appends one post-mutation quarantine-lifecycle record (`staged`/`trashed`/
    /// `rollbackFailed`), retrying exactly once on failure, two attempts total, never more.
    /// Returns `true` once either attempt lands durably, `false` only when both fail, which the
    /// caller treats as "journaling degraded" (finding #1) rather than suppressing.
    private func appendQuarantineRecordDegradingOnFailure(_ operation: () async throws -> Void) async -> Bool {
        for attempt in 0..<2 {
            do {
                try await operation()
                return true
            } catch {
                if attempt == 1 { return false }
            }
        }
        return false
    }

    /// Runs the identity-resolving ``SweepPolicy`` decision for whichever operation root claims
    /// the item's path.
    ///
    /// A fixture path is under no real operation root, so for a fixture this costs one prefix
    /// test and nothing else; a bug that aims a plan at a real cache tree gets the full
    /// resolved-identity gauntlet. Gate 1 turns the direction around: an authorization becomes a
    /// precondition for the item existing, not a check applied to one that already does
    /// (review finding #9).
    private func policyDenial(for item: DeletionItem) async -> String? {
        let spellings = await operationRootSpellings()
        let comparison = NameComparison.forVolume(containing: item.url)
        let path = item.url.standardizedFileURL.path
        guard spellings.contains(where: { comparison.isAtOrUnder(path, ancestor: $0) }) else {
            return nil
        }

        for root in SweepPolicy.OperationRoot.allCases {
            let decision = SweepPolicy.authorize(
                root: root,
                resolvedPath: item.url,
                identity: item.identity.pathIdentity
            )
            switch decision {
            case .allowed:
                return nil
            case .denied(.outsideRequestedRoot), .denied(.rootUnavailable):
                continue        // simply not this root's business
            case .denied(let reason):
                return reason.description
            }
        }
        return nil
    }

    private var cachedRootSpellings: [String]?

    /// Every pathname spelling of every operation root, resolved once per coordinator off the
    /// cooperative pool. Used only as the fast "does any root claim this at all" pre-filter.
    private func operationRootSpellings() async -> [String] {
        if let cachedRootSpellings { return cachedRootSpellings }
        let spellings = (try? await queue.run {
            SweepPolicy.OperationRoot.allCases.flatMap { root in
                SweepPolicy.resolvedRoots(for: root).flatMap { [$0.url.path, $0.requestedURL.path] }
            }
        }) ?? []
        cachedRootSpellings = spellings
        return spellings
    }
}

/// Stand-in for a coordinator with no anchored root: it can never mutate anything, which is the
/// correct behaviour for `.live` before Gate 1.
struct NoMutation: FileMutating {
    func trash(_ request: MutationRequest) async throws -> URL? {
        throw DeletionError.liveModeNotEnabled
    }

    func delete(_ request: MutationRequest) async throws {
        throw DeletionError.liveModeNotEnabled
    }

    func finishOperation(_ operationID: UUID) async {}
}
