import Foundation
import SweepPolicy

/// Which trust boundary an anchored root came through: a symbolic ``SweepPolicy/OperationRoot``
/// a catalog rule named, or the code-sign-clone detector's own process-derived root
/// (``SweepPolicy/SweepPolicy/authorize(externalRoot:resolvedPath:identity:home:)``). Both are
/// resolved and identity-pinned by ``SweepPolicy`` before anything is anchored; this only tags
/// which one, so a multi-root executor can key its per-root descriptor and quarantine cache.
enum TrashAnchorKey: Sendable, Hashable {
    case operationRoot(SweepPolicy.OperationRoot)
    case codeSignCloneRoot
}

/// One root Gate 1's trash-only mode is allowed to descend into: a symbolic or external root
/// ``SweepPolicy`` already authorized at least one item under, pinned to the device/inode that
/// authorization proved. ``DeletionCoordinator`` re-opens this by descriptor and re-checks the
/// identity before anchoring it (review finding #2's discipline applied to the root itself, not
/// just the leaf) — this struct only carries what authorization already established.
struct TrashOnlyAnchor: Sendable, Equatable {
    let key: TrashAnchorKey
    let url: URL
    let identity: PathIdentity
}

/// Gate 1's live executor: anchors one open directory descriptor per authorized root and can
/// only ever trash something under one of them.
///
/// This type has no `delete` method. Not "a delete method that is disabled", not "a delete
/// method gated by a flag checked at runtime" — there is no method by that name on this type at
/// all, so `someInstance.delete(...)` is a compile error wherever the concrete type is visible,
/// and `someInstance as? any FileMutating` fails at runtime for every instance, unconditionally,
/// because the conformance the cast is checking for was never declared. That is deliberate
/// (deliverable #2: "unlinkat/delete verbs structurally unreachable in this mode... not a
/// runtime flag") — see `TrashOnlyExecutorTests` for the assertions this makes possible.
///
/// Mirrors ``FileDescriptorExecutor``'s discipline exactly, just anchored at more than one root:
/// every mutation is resolved relative to an already-open descriptor, never a pathname, and the
/// actual trash-staging algorithm is the one shared implementation in ``TrashStaging``.
final class TrashOnlyFileDescriptorExecutor: TrashCapable, @unchecked Sendable {
    private let roots: [TrashAnchorKey: OpenDirectory]
    private let queue: BlockingIOQueue
    /// One quarantine per root: `renameat` cannot cross a device, so each authorized root needs
    /// its own staging directory on its own volume. Only ever touched from `queue`.
    private var quarantines: [TrashAnchorKey: OpenDirectory] = [:]

    init(anchors: [TrashAnchorKey: OpenDirectory], queue: BlockingIOQueue) {
        self.roots = anchors
        self.queue = queue
    }

    func trash(_ request: MutationRequest) async throws -> URL? {
        try await queue.run { try self.performTrash(request) }
    }

    private func performTrash(_ request: MutationRequest) throws -> URL? {
        // `request.anchorRoot` is set by `DeletionCoordinator` from the same anchor list this
        // executor was built from, so a miss here means the coordinator and the executor
        // disagree about which roots exist — a programming error, not a policy question — and
        // the item must fail rather than guess a root.
        guard let key = request.anchorRoot, let root = roots[key] else {
            throw FileDescriptorError.escapesRoot(path: request.url.path)
        }
        return try TrashStaging.trash(request: request, anchoredAt: root, quarantine: try quarantineDirectory(for: key, in: root))
    }

    private func quarantineDirectory(for key: TrashAnchorKey, in root: OpenDirectory) throws -> OpenDirectory {
        if let existing = quarantines[key] { return existing }
        try root.makeChildDirectory(FileDescriptorExecutor.quarantineDirectoryName)
        // `O_NOFOLLOW`: if something replaced the quarantine entry with a symlink, this refuses
        // rather than staging deletions somewhere else.
        let directory = try root.openChildDirectory(FileDescriptorExecutor.quarantineDirectoryName)
        quarantines[key] = directory
        return directory
    }
}
