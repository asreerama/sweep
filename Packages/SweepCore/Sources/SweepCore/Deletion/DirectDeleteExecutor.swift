import Darwin
import Foundation

/// Gate 2 (PLAN §6, not yet open — `CleanService.gate2Open` stays `false`): the mutation surface
/// for tier-`safe`, action-`delete`, undo-`regenerated` cache rules.
///
/// Deliberately its own protocol, not an extension of ``TrashCapable``/``FileMutating``: this
/// type has no `trash` method at all — not disabled, not gated, simply absent — the exact mirror
/// of ``TrashOnlyFileDescriptorExecutor`` having no `delete` method. A `DeletionPlan` built for
/// one mode's executor cannot be handed to the other's: ``DeletionCoordinator``'s `directDelete`
/// mode holds only a `DirectDeleteCapable` value in its `directDeleteExecutor` storage, its
/// `trashOnly` mode holds only a `TrashCapable` value in `executor`, and neither protocol
/// conforms to the other — there is no cast that lets a plan reach the wrong verb.
protocol DirectDeleteCapable: Sendable {
    /// Unlink (file) or bottom-up-remove (directory) the item this request names. No quarantine,
    /// no staging, no rename: direct deletion is terminal, so the only durability guarantee is
    /// the one every mode already gets from `DeletionCoordinator.execute(_:)` — the whole plan,
    /// including this item's `action == .delete`, is durably `appendPlanned` (fsync'd) before any
    /// item is processed, so a crash between that record and this call leaves a record naming
    /// exactly what was about to be unlinked, re-evaluable on the next run.
    func delete(_ request: MutationRequest) async throws
}

/// Mutates only through descriptors anchored at one of several already-open, identity-pinned
/// roots — exactly ``TrashOnlyFileDescriptorExecutor``'s discipline (multi-root, FD-anchored,
/// `O_NOFOLLOW` throughout, per-descendant identity checks, bottom-up directory removal, a
/// volume-crossing refusal equivalent to `FTS_XDEV`), with the terminal operation swapped:
/// `unlinkat` / `unlinkat(AT_REMOVEDIR)` instead of quarantine-rename-then-`trashItem`.
///
/// No quarantine directory exists for this executor: there is nothing to stage, because deletion
/// has no rollback. The leaf-identity gauntlet is the same one the trash path shares
/// (``TrashStaging/validatedLeaf(parent:leaf:expected:)``) — direct delete is no less strict about
/// proving it has the right object, only less forgiving of a mistake once it acts.
///
/// This is a new, parallel implementation of the bottom-up directory walk
/// (``FileDescriptorExecutor`` already has one, for fixture mode's `.delete` action) rather than a
/// shared call into that audited Gate-1 type — deliberately, so Gate 1's reviewed code is never
/// touched by Gate 2's addition.
final class DirectDeleteExecutor: DirectDeleteCapable, @unchecked Sendable {
    private let roots: [TrashAnchorKey: OpenDirectory]
    private let queue: BlockingIOQueue

    init(anchors: [TrashAnchorKey: OpenDirectory], queue: BlockingIOQueue) {
        self.roots = anchors
        self.queue = queue
    }

    func delete(_ request: MutationRequest) async throws {
        try await queue.run { try self.performDelete(request) }
    }

    // MARK: - On the serial queue

    private func performDelete(_ request: MutationRequest) throws {
        // `request.anchorRoot` is set by `DeletionCoordinator` from the same anchor list this
        // executor was built from (mirrors `TrashOnlyFileDescriptorExecutor.performTrash`): a
        // miss here means the coordinator and the executor disagree about which roots exist — a
        // programming error, not a policy question — and the item must fail rather than guess a
        // root.
        guard let key = request.anchorRoot, let root = roots[key] else {
            throw FileDescriptorError.escapesRoot(path: request.url.path)
        }

        let (parent, leaf) = try FileDescriptorPath.descend(
            from: root,
            components: request.relativeComponents,
            expectedParent: request.expectedParent
        )
        let actual = try TrashStaging.validatedLeaf(parent: parent, leaf: leaf, expected: request.expected)

        if actual.kind == .directory {
            try removeTree(parent: parent, name: leaf, expected: actual)
        } else {
            // Symlinks included: `unlinkat` removes the link, never its target. A hard-linked
            // regular file loses exactly this one directory entry — the inode's data, and every
            // other name still pointing at it, survive untouched.
            try parent.unlinkChild(leaf)
        }
    }

    /// Bottom-up removal, mirroring `FileDescriptorExecutor.removeTree`/`empty` exactly: every
    /// descendant is identity-checked immediately before it is unlinked, a mount point below the
    /// planned directory is refused rather than crossed, and the walk has the same depth ceiling
    /// so a pathological tree fails the item instead of recursing unbounded over unvalidated
    /// descendants.
    private func removeTree(parent: OpenDirectory, name: String, expected: FileIdentity) throws {
        let directory = try parent.openChildDirectory(name)
        let opened = try directory.identity(volume: expected.volume)
        // `openChildDirectory` and the `fstatat` before it are two syscalls; this proves nothing
        // swapped the directory in between.
        guard opened.isSameFile(as: expected) else {
            throw FileDescriptorError.identityChanged(path: directory.path)
        }

        try empty(directory, device: opened.deviceID, depth: 0)

        do {
            try parent.removeChildDirectory(name)
        } catch let error as FileDescriptorError where error.code == ENOTEMPTY {
            // Something was written into it while it was being emptied. That content was never
            // planned, so it stays and the item fails.
            throw FileDescriptorError.descendantIdentityChanged(path: directory.path)
        }
    }

    private func empty(_ directory: OpenDirectory, device: UInt64, depth: Int) throws {
        guard depth < FileDescriptorExecutor.maximumTreeDepth else {
            throw FileDescriptorError.tooDeep(path: directory.path)
        }

        for name in try directory.childNames() {
            let entry = try directory.identity(ofChild: name)
            guard entry.deviceID == device else {
                // A mount point appeared below the planned directory (the `FTS_XDEV` equivalent):
                // it belongs to another volume with another policy and is never ours to cross or
                // remove.
                throw FileDescriptorError.volumeBoundary(component: name)
            }

            if entry.kind == .directory {
                let child = try directory.openChildDirectory(name)
                guard try child.identity().isSameFile(as: entry) else {
                    throw FileDescriptorError.descendantIdentityChanged(path: child.path)
                }
                try empty(child, device: device, depth: depth + 1)
                do {
                    try directory.removeChildDirectory(name)
                } catch let error as FileDescriptorError where error.code == ENOTEMPTY {
                    throw FileDescriptorError.descendantIdentityChanged(path: child.path)
                }
            } else {
                try directory.unlinkChild(name)
            }
        }
    }
}
