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
/// This phase ships `fixtureOnly` only: every path must sit strictly under one injected
/// fixture root, and anything else is refused before a single byte moves.
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
    public static func fixtureOnly(root: URL) -> DeletionMode {
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
        }
    }
}

/// The only type in Sweep permitted to mutate the filesystem.
///
/// Every item goes through the same gauntlet, in this order: plan-level validation, fixture
/// containment, policy denylist backstop, identity revalidation against the scan-time
/// device/inode/mtime/link-count, then and only then the mutation. The write-ahead log is
/// durable before each step that can lose information, and a journal write that fails aborts
/// the operation rather than proceeding unlogged.
public actor DeletionCoordinator {
    private let mode: DeletionMode
    private let journal: WALJournal
    private let extraDenials: DenyCheck
    private let executor: any FileMutating

    public init(mode: DeletionMode, journal: WALJournal, additionalDenials: DenyCheck = .none) {
        self.init(
            mode: mode,
            journal: journal,
            additionalDenials: additionalDenials,
            executor: FileSystemExecutor()
        )
    }

    init(
        mode: DeletionMode,
        journal: WALJournal,
        additionalDenials: DenyCheck = .none,
        executor: any FileMutating
    ) {
        self.mode = mode
        self.journal = journal
        self.extraDenials = additionalDenials
        self.executor = executor
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
            let result = perform(item)
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
    static func isStrictlyContained(_ url: URL, in root: URL) -> Bool {
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let resolved = parent.appending(path: url.lastPathComponent).standardizedFileURL
        guard resolved.path != resolvedRoot.path else { return false }
        return resolved.path.hasPrefix(resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/")
    }

    // MARK: - Per-item execution

    private func perform(_ item: DeletionItem) -> DeletionItemResult {
        // 1. Mode containment, re-checked per item. Plan validation already covers this; the
        //    duplicate is deliberate defense in depth around the only mutating call site.
        if let root = mode.fixtureRoot, !Self.isStrictlyContained(item.url, in: root) {
            return DeletionItemResult(
                item: item,
                outcome: .skipped,
                failureReason: .outsideFixtureRoot,
                detail: "not under fixture root \(root.path)"
            )
        }

        // 2. Policy backstop. The producer should never have offered a denied path; if it did,
        //    that is a bug, and the bug must not delete anything.
        if SweepPolicy.isDeniedLexically(item.url) || extraDenials.isDenied(item.url) {
            return DeletionItemResult(
                item: item,
                outcome: .skipped,
                failureReason: .policyDenied,
                detail: "denied by policy"
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

        // 4. Identity revalidation: re-stat without following symlinks and compare
        //    device/inode/type/mtime/link count against the scan-time capture.
        let current: FileIdentity
        do {
            current = try FileIdentity.read(at: item.url, volume: item.identity.volume)
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
                detail: "item mutated since scan (mtime or link count differs)"
            )
        }

        // 5. Mutate.
        do {
            switch item.action {
            case .trash:
                let trashURL = try executor.trash(item.url)
                return DeletionItemResult(item: item, outcome: .succeeded, trashURL: trashURL)
            case .delete:
                try executor.delete(item.url)
                return DeletionItemResult(item: item, outcome: .succeeded)
            }
        } catch {
            return DeletionItemResult(
                item: item,
                outcome: .failed,
                failureReason: failureReason(for: error),
                detail: (error as NSError).localizedDescription
            )
        }
    }
}
