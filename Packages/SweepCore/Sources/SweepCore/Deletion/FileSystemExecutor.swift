import Darwin
import Foundation

/// One item's worth of mutation, expressed the only way the executor accepts it: as components
/// relative to an already-anchored root, plus the identities the plan expects to find.
///
/// There is no pathname in this request that the executor will resolve. `url` exists so a
/// refusal can name the item in the journal.
struct MutationRequest: Sendable {
    let url: URL
    let relativeComponents: [String]
    let expected: FileIdentity
    /// Scan-time identity of the immediate parent, when the scan captured one.
    let expectedParent: FileIdentity?
    /// Which of a multi-root executor's anchors this request descends from. `nil` for a
    /// single-root executor (fixture mode, and eventually gate-2 live mode), where there is only
    /// ever one anchor and no ambiguity to resolve. Only ``TrashOnlyFileDescriptorExecutor``
    /// reads this.
    var anchorRoot: TrashAnchorKey? = nil
}

/// The mutation surface every trash-capable executor exposes. Deliberately tiny: one verb, no
/// path building, no recursion the caller can steer.
protocol TrashCapable: Sendable {
    /// Returns the resulting Trash URL when the system reports one.
    func trash(_ request: MutationRequest) async throws -> URL?
}

/// The full mutation surface: trash, plus unlink. Only ever implemented by an executor anchored
/// at a *single* root the coordinator itself opened (fixture mode today; gate 2's live mode
/// later) — never by ``TrashOnlyFileDescriptorExecutor``, which conforms to ``TrashCapable`` only
/// and has no `delete` method to call at all. That asymmetry is what makes Gate 1's trash-only
/// mode structurally incapable of deleting anything: there is no runtime flag guarding `delete`,
/// there is simply no such method on the type trash-only mode is given (deliverable #2,
/// "structurally unreachable... not a runtime flag"). See `TrashOnlyExecutorTests` for the
/// compile-surface proof.
protocol FileMutating: TrashCapable {
    func delete(_ request: MutationRequest) async throws
}

/// Mutates only through descriptors anchored at a root that was opened once, up front.
///
/// Three properties this buys, all of which the pathname-based version lacked:
///
/// - **No TOCTOU between check and act.** Validation (`fstatat`) and mutation (`unlinkat`,
///   `renameat`) are issued against the same open parent descriptor, so a rename of any
///   directory in the pathname cannot redirect the mutation (review finding #2).
/// - **No unvalidated recursion.** A planned directory is emptied bottom-up with each leaf
///   identity-checked immediately before its `unlinkat`, and directories go only via
///   `AT_REMOVEDIR`, which the kernel refuses on a non-empty directory (review finding #3).
/// - **No cooperative-pool blocking.** Every syscall runs on a dedicated serial queue
///   (review finding #16).
final class FileDescriptorExecutor: FileMutating, @unchecked Sendable {
    /// Deeper than any real cache tree; a cycle would need a symlink, and symlinks are refused.
    static let maximumTreeDepth = 64
    static let quarantineDirectoryName = ".sweep-quarantine"

    private let root: OpenDirectory
    private let queue: BlockingIOQueue
    /// Opened lazily on first trash and then held; the descriptor *is* the identity pin.
    /// Only ever touched from `queue`.
    private var quarantine: OpenDirectory?

    init(root: OpenDirectory, queue: BlockingIOQueue) {
        self.root = root
        self.queue = queue
    }

    // MARK: - FileMutating

    func delete(_ request: MutationRequest) async throws {
        try await queue.run { try self.performDelete(request) }
    }

    func trash(_ request: MutationRequest) async throws -> URL? {
        try await queue.run { try self.performTrash(request) }
    }

    // MARK: - On the serial queue

    private func performDelete(_ request: MutationRequest) throws {
        let (parent, leaf) = try FileDescriptorPath.descend(
            from: root,
            components: request.relativeComponents,
            expectedParent: request.expectedParent
        )
        let actual = try TrashStaging.validatedLeaf(parent: parent, leaf: leaf, expected: request.expected)

        if actual.kind == .directory {
            try removeTree(parent: parent, name: leaf, expected: actual)
        } else {
            try parent.unlinkChild(leaf)
        }
    }

    private func performTrash(_ request: MutationRequest) throws -> URL? {
        try TrashStaging.trash(request: request, anchoredAt: root, quarantine: try quarantineDirectory())
    }

    /// Bottom-up removal. `removeItem`'s recursive delete is never used, because it would take
    /// the pathname and delete whatever is under it — including content created after the scan,
    /// and including anything a symlinked subdirectory points at.
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
            // Something was written into it while we were emptying it. That content was never
            // planned, so it stays and the item fails.
            throw FileDescriptorError.descendantIdentityChanged(path: directory.path)
        }
    }

    private func empty(_ directory: OpenDirectory, device: UInt64, depth: Int) throws {
        guard depth < Self.maximumTreeDepth else {
            throw FileDescriptorError.tooDeep(path: directory.path)
        }

        for name in try directory.childNames() {
            let entry = try directory.identity(ofChild: name)
            guard entry.deviceID == device else {
                // A mount point appeared below the planned directory; it belongs to another
                // volume with another policy and is never ours to remove.
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
                // Symlinks included: `unlinkat` removes the link, never its target.
                try directory.unlinkChild(name)
            }
        }
    }

    private func quarantineDirectory() throws -> OpenDirectory {
        if let quarantine { return quarantine }
        try root.makeChildDirectory(Self.quarantineDirectoryName)
        // `O_NOFOLLOW`: if something replaced the quarantine entry with a symlink, this refuses
        // rather than staging deletions somewhere else.
        let directory = try root.openChildDirectory(Self.quarantineDirectoryName)
        quarantine = directory
        return directory
    }
}

/// The trash-staging algorithm every trash-capable executor uses: rename the leaf into a
/// quarantine directory this process created and holds open, validate the move landed on the
/// same object, hand `FileManager.trashItem` a pathname nothing else has a handle on, and roll
/// back to the original location if anything after the rename fails.
///
/// Pulled out so ``FileDescriptorExecutor`` (fixture mode, and eventually gate 2's live mode) and
/// ``TrashOnlyFileDescriptorExecutor`` (Gate 1's real-filesystem trash-only mode) share one
/// implementation of the only code that actually moves something into the real Trash — the two
/// executors differ only in how many roots they anchor and which verbs they expose, never in how
/// a trash actually happens.
enum TrashStaging {
    static func trash(
        request: MutationRequest,
        anchoredAt root: OpenDirectory,
        quarantine: OpenDirectory
    ) throws -> URL? {
        let (parent, leaf) = try FileDescriptorPath.descend(
            from: root,
            components: request.relativeComponents,
            expectedParent: request.expectedParent
        )
        let actual = try validatedLeaf(parent: parent, leaf: leaf, expected: request.expected)

        // A directory is trashed whole, by rename: nothing is destroyed, the move is atomic, and
        // the Trash entry restores the subtree intact. Per-descendant validation is what deletion
        // needs, because deletion is not reversible.
        //
        // `FileManager.trashItem` is the only API that can produce a restorable Trash entry, and
        // it only speaks pathnames. So the item is first moved, by descriptor-relative atomic
        // rename, into the quarantine directory the caller already holds open. The pathname
        // handed to Foundation is therefore one nothing else has a handle on, and it is
        // re-validated against the identity that was just moved immediately before the call.
        let slotName = UUID().uuidString
        try quarantine.makeChildDirectory(slotName)
        let slot = try quarantine.openChildDirectory(slotName)
        try parent.renameChild(leaf, into: slot, as: leaf)

        do {
            let moved = try slot.identity(ofChild: leaf, volume: actual.volume)
            guard moved.isSameFile(as: actual) else {
                throw FileDescriptorError.identityChanged(path: request.url.path)
            }
            let quarantinedURL = URL(fileURLWithPath: slot.path).appending(path: leaf)
            guard let onDisk = try? FileIdentity.read(at: quarantinedURL),
                  onDisk.isSameFile(as: moved) else {
                throw FileDescriptorError.identityChanged(path: quarantinedURL.path)
            }

            var resulting: NSURL?
            do {
                try FileManager.default.trashItem(at: quarantinedURL, resultingItemURL: &resulting)
            } catch {
                throw FileDescriptorError.trashFailed((error as NSError).localizedDescription)
            }
            try? quarantine.removeChildDirectory(slotName)
            return resulting as URL?
        } catch {
            // Quarantine is a staging area, never a grave: anything that does not reach the Trash
            // goes back where it came from, through the same descriptors.
            try? slot.renameChild(leaf, into: parent, as: leaf)
            try? quarantine.removeChildDirectory(slotName)
            throw error
        }
    }

    /// `fstatat` against the open parent, compared with the plan. Both halves matter: same inode
    /// (it is the object we planned) and unchanged (nothing wrote to it since).
    static func validatedLeaf(
        parent: OpenDirectory,
        leaf: String,
        expected: FileIdentity
    ) throws -> FileIdentity {
        let actual = try parent.identity(ofChild: leaf, volume: expected.volume)
        guard actual.isSameFile(as: expected), actual.isUnchanged(from: expected) else {
            throw FileDescriptorError.identityChanged(path: parent.path + "/" + leaf)
        }
        return actual
    }
}

/// Maps a descriptor, Cocoa or POSIX error onto the failure vocabulary the journal and UI
/// distinguish.
func failureReason(for error: any Error) -> ItemFailureReason {
    if let descriptorError = error as? FileDescriptorError {
        if descriptorError.isNotFound { return .vanished }
        if descriptorError.isPermissionDenied { return .permissionDenied }
        if descriptorError.isIdentityRefusal { return .identityChanged }
        switch descriptorError {
        case .escapesRoot, .invalidComponent: return .outsideFixtureRoot
        default: return .filesystemError
        }
    }
    if let identityError = error as? FileIdentityError {
        if identityError.isNotFound { return .vanished }
        if identityError.isPermissionDenied { return .permissionDenied }
        return .filesystemError
    }
    let nsError = error as NSError
    switch nsError.domain {
    case NSCocoaErrorDomain:
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .vanished
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return .permissionDenied
        default:
            return .filesystemError
        }
    case NSPOSIXErrorDomain:
        switch Int32(nsError.code) {
        case ENOENT: return .vanished
        case EACCES, EPERM: return .permissionDenied
        default: return .filesystemError
        }
    default:
        return .filesystemError
    }
}

/// Outcome that goes with a failure reason. `changed` is not a failure: the disk moved under the
/// plan, nothing was touched, and the correct response is to re-scan.
func outcome(for reason: ItemFailureReason) -> ItemOutcome {
    switch reason {
    case .identityChanged: .changed
    case .vanished, .policyDenied, .outsideFixtureRoot, .tierViolation, .notAttempted,
         .outsideAuthorizedRoot, .actionNotPermitted, .notAuthorized:
        .skipped
    case .permissionDenied, .filesystemError: .failed
    }
}
