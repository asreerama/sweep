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
    /// The plan's operation id. Used only to name this item's deterministic, per-operation
    /// quarantine slot (review finding #3/#5) — never anything a caller of `CleanService`
    /// supplies directly; it is always `DeletionPlan.operationID`.
    var operationID: UUID = UUID()
}

/// The mutation surface every trash-capable executor exposes. Deliberately tiny: one verb, no
/// path building, no recursion the caller can steer.
protocol TrashCapable: Sendable {
    /// Returns the resulting Trash URL when the system reports one.
    func trash(_ request: MutationRequest) async throws -> URL?

    /// Best-effort cleanup once an operation's items have all been processed: removes that
    /// operation's per-operation quarantine directory (review finding #3/#5) if, and only if, it
    /// is now empty. Never throws, and never removes anything that still holds content — a
    /// stranded slot stays exactly where ``QuarantineRecovery`` expects to find it.
    func finishOperation(_ operationID: UUID) async
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
    /// One exclusive-created directory per operation id seen by this executor instance (review
    /// finding #3): created fresh the first time an operation's id is seen (`EEXIST` is a hard
    /// failure, never silently reused), then cached and reused for every other item in that same
    /// operation. Only ever touched from `queue`.
    private var operationDirectories: [UUID: OpenDirectory] = [:]

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

    func finishOperation(_ operationID: UUID) async {
        try? await queue.run { self.performFinishOperation(operationID) }
    }

    private func performFinishOperation(_ operationID: UUID) {
        guard let directory = operationDirectories[operationID], let quarantine else { return }
        if (try? directory.childNames())?.isEmpty == true {
            try? quarantine.removeChildDirectory(operationID.uuidString)
        }
        operationDirectories[operationID] = nil
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
        let quarantine = try quarantineDirectory()
        let operationDirectory = try self.operationDirectory(for: request.operationID, in: quarantine)
        return try TrashStaging.trash(request: request, anchoredAt: root, operationQuarantine: operationDirectory)
    }

    /// The first call for a given operation id creates its quarantine directory exclusively
    /// (`EEXIST` refuses rather than reuses — review finding #3) and verifies it; every later
    /// item in the same operation reuses the cached descriptor.
    private func operationDirectory(for operationID: UUID, in quarantine: OpenDirectory) throws -> OpenDirectory {
        if let existing = operationDirectories[operationID] { return existing }
        let name = operationID.uuidString
        try quarantine.makeChildDirectoryExclusive(name)
        let directory = try quarantine.openChildDirectory(name)
        try TrashStaging.verifyFreshQuarantineSlot(directory, expectedDeviceID: try quarantine.identity().deviceID)
        operationDirectories[operationID] = directory
        return directory
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

    /// Deterministic per-item slot name: device+inode only, never the path (which may contain
    /// characters unsafe as a single path component, and would leak arbitrary length into a
    /// filename). The same object always names the same slot, so a second attempt at it within
    /// the same operation collides loudly on the exclusive create below rather than silently
    /// double-staging.
    static func slotName(for identity: FileIdentity) -> String {
        "\(identity.deviceID)-\(identity.inode)"
    }

    /// - Parameter performTrashItem: `FileManager.trashItem(at:resultingItemURL:)` by default.
    ///   Test-only seam (Codex G1 finding #3): lets a test substitute a stand-in that reports
    ///   success without actually removing the leaf, proving the post-success decoy verification
    ///   below catches it, without depending on coaxing the real Trash API into that behavior.
    static func trash(
        request: MutationRequest,
        anchoredAt root: OpenDirectory,
        operationQuarantine: OpenDirectory,
        performTrashItem: (URL) throws -> URL? = { url in
            var resulting: NSURL?
            try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
            return resulting as URL?
        }
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
        // rename, into an exclusive slot inside this operation's own quarantine directory (review
        // finding #3): the slot's name is derived from this object's own device/inode, created
        // with `makeChildDirectoryExclusive` — a slot that already exists is refused outright,
        // never silently reused — and its owner/mode/device are verified immediately after
        // creation, before anything is renamed into it.
        let slotName = Self.slotName(for: actual)
        try operationQuarantine.makeChildDirectoryExclusive(slotName)
        let slot = try operationQuarantine.openChildDirectory(slotName)
        try Self.verifyFreshQuarantineSlot(slot, expectedDeviceID: try operationQuarantine.identity().deviceID)

        try parent.renameChild(leaf, into: slot, as: leaf)

        let trashResult: URL?
        do {
            // The identity of what actually landed is re-read from the slot's own descriptor —
            // authoritative, because it is `fstatat` against a directory this process just
            // created and holds open. A second, pathname-based re-read here would only add
            // another TOCTOU-vulnerable step for no additional assurance, so there is none.
            let moved = try slot.identity(ofChild: leaf, volume: actual.volume)
            guard moved.isSameFile(as: actual) else {
                throw FileDescriptorError.identityChanged(path: request.url.path)
            }

            // Codex Gate-U finding #2: a directory is trashed whole, so what rides inside it
            // matters. The staged tree — the object actually about to be trashed, post-rename,
            // not the racy live path — is deep-walked here: every entry must live on the same
            // device (a mount surfaced inside would drag another volume's content along), and no
            // entry may carry the identity of a protected area (someone moving ~/Documents into
            // a leftover directory after review must abort the trash, not enrich it). A refusal
            // throws into the rollback path below, which renames the item back where it was.
            if moved.kind == .directory {
                let stagedPath = URL(fileURLWithPath: slot.path).appending(path: leaf).path
                if let violation = DeepTreeValidator.firstViolation(
                    inTreeAt: stagedPath, expectedDevice: moved.pathIdentity.deviceID
                ) {
                    throw FileDescriptorError.protectedContentInsideDirectory(
                        path: request.url.path, detail: violation
                    )
                }
            }

            // From this line on, `FileManager.trashItem` is a pathname API — the one hop in this
            // whole pipeline that cannot be made descriptor-relative, because Foundation's Trash
            // implementation only ever accepts a path. The window is narrowed as far as it can
            // be: the pathname names a slot this process just created *exclusively* (a fresh
            // `mkdir` that fails on `EEXIST`), deterministically named from this operation's id
            // and this object's own device/inode, holding exactly the object just proven
            // identical by descriptor a moment ago. This is **not** fully race-free: a same-uid
            // process could still, in principle, unlink or replace the leaf at that exact
            // pathname in the instant between this line and the syscall inside `trashItem`. That
            // residual gap is real, and nothing short of Sweep re-implementing the Trash protocol
            // itself (`FSMoveObjectToTrashSync` or lower) instead of calling
            // `FileManager.trashItem` would close it.
            let quarantinedURL = URL(fileURLWithPath: slot.path).appending(path: leaf)
            do {
                trashResult = try performTrashItem(quarantinedURL)
            } catch {
                throw FileDescriptorError.trashFailed((error as NSError).localizedDescription)
            }
        } catch {
            // Quarantine is a staging area, never a grave: anything that does not reach the Trash
            // goes back where it came from, through the same descriptors. Unlike before, a
            // failure of *this* rollback rename is never swallowed (review finding #5): it is the
            // one failure mode that actually strands the item, so it is re-thrown as a distinct,
            // never-suppressed error the coordinator must report as "moved, recovery required."
            let firstError = error
            do {
                try slot.renameChild(leaf, into: parent, as: leaf)
            } catch let rollbackError {
                let quarantinedPath = URL(fileURLWithPath: slot.path).appending(path: leaf).path
                throw FileDescriptorError.strandedInQuarantine(
                    quarantinePath: quarantinedPath,
                    underlyingReason: String(describing: firstError),
                    rollbackReason: String(describing: rollbackError)
                )
            }
            // The rollback itself succeeded; only the now-empty slot directory remains, and
            // failing to remove it is cosmetic (the item is already safely back at its original
            // location), so this cleanup alone may still be best-effort.
            try? operationQuarantine.removeChildDirectory(slotName)
            throw firstError
        }

        // Codex G1 finding #3 (CRITICAL): `trashItem` returning without throwing is not itself
        // proof the leaf actually left the slot. `OpenDirectory.path` (what `quarantinedURL`
        // above was built from) is only a cached spelling, recorded for diagnostics and for
        // `trashItem` itself, and must never be treated as authoritative for success. Verified
        // the same way every other step in this pipeline verifies anything: `fstatat` against the
        // slot descriptor this process still holds open. If the expected leaf is still physically
        // present, this is a decoy success. It is deliberately *not* auto-rolled-back the way a
        // thrown error above would be: `trashItem`'s own success report may already have
        // registered this object with the system Trash even though the bytes never left the slot,
        // so silently renaming it back could leave that bookkeeping pointing at a phantom entry.
        // Reported exactly like a failed-rollback stranding instead: recovery required, at the
        // slot location, never silently suppressed into a claimed success.
        // Codex G1 verdict 3: only a clean ENOENT proves absence. Any occupant (same object,
        // decoy replacement) or any stat failure after a claimed trashItem success leaves the
        // outcome indeterminate and must surface as recovery-required, never as success.
        let leafState: FileIdentity?
        do {
            leafState = try slot.identity(ofChild: leaf, volume: actual.volume)
        } catch FileDescriptorError.statFailed(_, let code) where code == ENOENT {
            leafState = nil
        } catch {
            let quarantinedPath = URL(fileURLWithPath: slot.path).appending(path: leaf).path
            throw FileDescriptorError.strandedInQuarantine(
                quarantinePath: quarantinedPath,
                underlyingReason: "post-trash verification could not stat the slot leaf: \(error)",
                rollbackReason: "verification failed; object state indeterminate"
            )
        }
        if leafState != nil { // same object or a decoy occupant: both indeterminate
            let quarantinedPath = URL(fileURLWithPath: slot.path).appending(path: leaf).path
            throw FileDescriptorError.strandedInQuarantine(
                quarantinePath: quarantinedPath,
                underlyingReason: "trashItem(at:) reported success but the expected leaf is still "
                    + "present in the slot held by descriptor; a cached pathname is never authoritative",
                rollbackReason: "rollback deliberately not attempted: trashItem's own success report "
                    + "makes the object's Trash bookkeeping state indeterminate"
            )
        }

        // Codex Gate-U finding #3: an empty slot proves the object LEFT, not where it WENT. When
        // the system reported a resulting Trash URL, the object there must be the exact
        // device+inode this process verified in the slot a moment ago — a same-uid substitution
        // in `trashItem`'s one pathname hop would otherwise trash a different object and report
        // success for the reviewed one. `lstat` of the Trash entry can only produce a false
        // refusal (extra caution), never a false success.
        if let trashResult {
            var status = stat()
            let matches = lstat(trashResult.path, &status) == 0
                && UInt64(bitPattern: Int64(status.st_dev)) == actual.deviceID
                && status.st_ino == actual.inode
            guard matches else {
                throw FileDescriptorError.trashedObjectMismatch(path: request.url.path, trashPath: trashResult.path)
            }
        }

        try? operationQuarantine.removeChildDirectory(slotName)
        return trashResult
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

    /// After an exclusive create, re-derives what actually landed on disk directly from the fd
    /// rather than trusting the create call's mode argument — review finding #3's "owner/mode/
    /// device verified after creation."
    static func verifyFreshQuarantineSlot(_ directory: OpenDirectory, expectedDeviceID: UInt64) throws {
        var status = stat()
        guard fstat(directory.fd, &status) == 0 else {
            throw FileDescriptorError.quarantineSlotIdentityUnexpected(
                "fstat failed: \(String(cString: strerror(errno)))"
            )
        }
        guard status.st_mode & S_IFMT == S_IFDIR else {
            throw FileDescriptorError.quarantineSlotIdentityUnexpected("not a directory")
        }
        guard status.st_uid == getuid() else {
            throw FileDescriptorError.quarantineSlotIdentityUnexpected(
                "owner uid \(status.st_uid) does not match this account"
            )
        }
        guard status.st_mode & (S_IRWXG | S_IRWXO) == 0 else {
            throw FileDescriptorError.quarantineSlotIdentityUnexpected("accessible to group or other")
        }
        let deviceID = UInt64(bitPattern: Int64(status.st_dev))
        guard deviceID == expectedDeviceID else {
            throw FileDescriptorError.quarantineSlotIdentityUnexpected("on a different device than its quarantine root")
        }
    }
}

/// Maps a descriptor, Cocoa or POSIX error onto the failure vocabulary the journal and UI
/// distinguish.
func failureReason(for error: any Error) -> ItemFailureReason {
    if let descriptorError = error as? FileDescriptorError {
        if case .strandedInQuarantine = descriptorError { return .rollbackFailed }
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
         .outsideAuthorizedRoot, .actionNotPermitted, .notAuthorized, .directDeleteRequirementNotMet:
        .skipped
    case .permissionDenied, .filesystemError, .journalUnavailable: .failed
    // Review finding #5: a real mutation happened (the item left its original location) and
    // neither half of the usual "trashed" / "rolled back" outcome pair completed. This must
    // never collapse into `.failed`, which would misleadingly claim nothing was touched.
    case .rollbackFailed: .movedRecoveryRequired
    }
}
