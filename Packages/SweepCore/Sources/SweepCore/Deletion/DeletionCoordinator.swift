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
/// This phase ships `fixtureOnly` only: every path must sit strictly under one disposable
/// fixture root, and anything else is refused before a single byte moves. The constructor is
/// internal — a caller outside the package cannot name a root at all, and reaches fixture
/// execution only through ``FixtureExecution``, which owns the root it creates
/// (review finding #1).
public struct DeletionMode: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case fixtureOnly(URL)
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
    private let journal: WALJournal
    private let extraDenials: DenyCheck
    private let executor: any FileMutating
    /// Descriptor opened once, at init, on the fixture root. Held for the coordinator's life:
    /// every mutation is resolved relative to this inode, not to the pathname it was opened from.
    private let anchor: OpenDirectory?
    private let queue: BlockingIOQueue

    init(mode: DeletionMode, journal: WALJournal, additionalDenials: DenyCheck = .none) throws {
        let queue = BlockingIOQueue(label: "com.sweep.deletion.io")
        let anchor: OpenDirectory?
        if let root = mode.fixtureRoot {
            do {
                anchor = try OpenDirectory.openRoot(root)
            } catch {
                throw DeletionError.fixtureRootUnavailable(String(describing: error))
            }
        } else {
            anchor = nil
        }
        self.init(
            mode: mode,
            journal: journal,
            additionalDenials: additionalDenials,
            executor: anchor.map { FileDescriptorExecutor(root: $0, queue: queue) } ?? NoMutation(),
            anchor: anchor,
            queue: queue
        )
    }

    init(
        mode: DeletionMode,
        journal: WALJournal,
        additionalDenials: DenyCheck = .none,
        executor: any FileMutating,
        anchor: OpenDirectory? = nil,
        queue: BlockingIOQueue = BlockingIOQueue(label: "com.sweep.deletion.io")
    ) {
        self.mode = mode
        self.journal = journal
        self.extraDenials = additionalDenials
        self.executor = executor
        self.anchor = anchor
        self.queue = queue
    }

    /// Validate and execute. Throws before any mutation when the plan itself is unacceptable;
    /// per-item refusals are reported in the returned ``DeletionReport``, not thrown.
    @discardableResult
    public func execute(_ plan: DeletionPlan) async throws -> DeletionReport {
        try validate(plan)

        do {
            try await journal.appendPlanned(
                operationID: plan.operationID,
                planVersion: plan.version,
                items: plan.items.map(\.journalItem)
            )
            try await journal.appendStarted(operationID: plan.operationID)
        } catch {
            throw DeletionError.journalUnavailable(String(describing: error))
        }

        var results: [DeletionItemResult] = []
        results.reserveCapacity(plan.items.count)

        for item in plan.items {
            let result = await perform(item)
            do {
                try await journal.appendItemResult(
                    operationID: plan.operationID,
                    item: item.journalItem,
                    outcome: result.outcome,
                    failureReason: result.failureReason,
                    trashURL: result.trashURL,
                    detail: result.detail
                )
            } catch {
                // Abort-on-journal-write-failure: stop immediately, leave the operation
                // uncommitted so the next recovery scan surfaces it.
                results.append(result)
                throw DeletionError.journalUnavailable(String(describing: error))
            }
            results.append(result)
        }

        do {
            try await journal.appendCommitted(operationID: plan.operationID)
        } catch {
            throw DeletionError.journalUnavailable(String(describing: error))
        }

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
        }

        for item in plan.items where item.action == .delete && item.tier != .safe {
            throw DeletionError.tierViolation(path: item.url.path, tier: item.tier)
        }
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

    private func perform(_ item: DeletionItem) async -> DeletionItemResult {
        // 1. Mode containment, re-checked per item. Plan validation already covers this; the
        //    duplicate is deliberate defense in depth around the only mutating call site.
        guard let root = mode.fixtureRoot else {
            return DeletionItemResult(
                item: item,
                outcome: .skipped,
                failureReason: .outsideFixtureRoot,
                detail: "no fixture root is anchored"
            )
        }
        guard Self.isStrictlyContained(item.url, in: root),
              let components = FileDescriptorPath.relativeComponents(of: item.url, under: root)
        else {
            return DeletionItemResult(
                item: item,
                outcome: .skipped,
                failureReason: .outsideFixtureRoot,
                detail: "not under fixture root \(root.path)"
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
            expectedParent: item.parentIdentity
        )
        do {
            switch item.action {
            case .trash:
                let trashURL = try await executor.trash(request)
                return DeletionItemResult(item: item, outcome: .succeeded, trashURL: trashURL)
            case .delete:
                try await executor.delete(request)
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
}
