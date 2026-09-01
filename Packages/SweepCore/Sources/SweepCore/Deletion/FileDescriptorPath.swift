import Darwin
import Foundation

/// Every way the descriptor-anchored walk can refuse.
///
/// These are refusals, not accidents: each one means the shape of the tree stopped matching
/// what the plan described, and the correct response is to abandon *this item* without
/// touching anything.
enum FileDescriptorError: Error, Equatable, CustomStringConvertible {
    case invalidComponent(String)
    case escapesRoot(path: String)
    case openFailed(component: String, code: Int32)
    case symlinkComponent(component: String)
    case notADirectory(component: String)
    case statFailed(component: String, code: Int32)
    case componentIdentityChanged(component: String)
    case volumeBoundary(component: String)
    case identityChanged(path: String)
    case descendantIdentityChanged(path: String)
    case tooDeep(path: String)
    case syscallFailed(name: String, component: String, code: Int32)
    case quarantineUnavailable(String)
    case trashFailed(String)
    case alreadyExists(component: String)
    /// Staging succeeded (the item was renamed into its exclusive per-operation quarantine
    /// slot) but the mutation could not be completed *and* rolling the item back to its
    /// original location also failed. The item is not where the plan found it and not in the
    /// Trash either — real recovery is required, and this is never silently reported as a plain
    /// failure (review finding #5).
    case strandedInQuarantine(quarantinePath: String, underlyingReason: String, rollbackReason: String)
    /// The just-created, supposedly-exclusive quarantine slot did not come back with the
    /// identity/ownership this process expects immediately after creating it.
    case quarantineSlotIdentityUnexpected(String)

    var code: Int32? {
        switch self {
        case .openFailed(_, let code), .statFailed(_, let code), .syscallFailed(_, _, let code):
            code
        default:
            nil
        }
    }

    var isNotFound: Bool { code == ENOENT || code == ENOTDIR }
    var isPermissionDenied: Bool { code == EACCES || code == EPERM }

    /// True when the refusal means "the disk no longer matches the plan" as opposed to
    /// "the operation failed". These are reported as `changed`, never as a failure.
    var isIdentityRefusal: Bool {
        switch self {
        case .symlinkComponent, .notADirectory, .componentIdentityChanged, .volumeBoundary,
             .identityChanged, .descendantIdentityChanged:
            true
        default:
            false
        }
    }

    var description: String {
        switch self {
        case .invalidComponent(let name):
            "refused: \(name) is not a usable path component"
        case .escapesRoot(let path):
            "refused: \(path) is not under the anchored root"
        case .openFailed(let component, let code):
            "openat(\(component)) failed: \(String(cString: strerror(code))) (\(code))"
        case .symlinkComponent(let component):
            "refused: \(component) is a symlink; the walk never follows one"
        case .notADirectory(let component):
            "refused: \(component) is no longer a directory"
        case .statFailed(let component, let code):
            "fstatat(\(component)) failed: \(String(cString: strerror(code))) (\(code))"
        case .componentIdentityChanged(let component):
            "refused: the directory \(component) is not the one captured at scan time"
        case .volumeBoundary(let component):
            "refused: \(component) is on another volume"
        case .identityChanged(let path):
            "refused: \(path) is not the object captured at scan time"
        case .descendantIdentityChanged(let path):
            "refused: a descendant of \(path) changed between validation and removal"
        case .tooDeep(let path):
            "refused: \(path) is nested deeper than the walk will go"
        case .syscallFailed(let name, let component, let code):
            "\(name)(\(component)) failed: \(String(cString: strerror(code))) (\(code))"
        case .quarantineUnavailable(let reason):
            "quarantine directory unavailable: \(reason)"
        case .trashFailed(let reason):
            "trashItem failed: \(reason)"
        case .alreadyExists(let component):
            "refused: \(component) already exists; an exclusive create was required here"
        case .strandedInQuarantine(let path, let underlying, let rollback):
            "moved to quarantine at \(path) but could not be trashed (\(underlying)) or rolled back (\(rollback)); recovery required"
        case .quarantineSlotIdentityUnexpected(let reason):
            "refused: freshly created quarantine slot did not verify: \(reason)"
        }
    }
}

/// An open directory file descriptor, and the only sanctioned way to reach a file for mutation.
///
/// The point is that a descriptor names an *inode*, not a pathname. Once this is open, renaming
/// the directory, replacing it with a symlink, or swapping an ancestor cannot redirect anything
/// done through it: `openat`, `fstatat`, `unlinkat` and `renameat` all resolve relative to the
/// descriptor. That closes the window between "we checked the path" and "we acted on the path"
/// that pathname APIs leave open (review finding #2).
///
/// Marked `@unchecked Sendable` because a raw descriptor has no compiler-visible ownership: it
/// is safe here only because every instance is created and used from ``BlockingIOQueue``'s single
/// serial queue, and closed exactly once in `deinit`.
final class OpenDirectory: @unchecked Sendable {
    let fd: Int32
    /// Pathname the descriptor was opened from. Diagnostics and `FileManager.trashItem` only;
    /// it is never used to reach a file.
    let path: String

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    deinit {
        close(fd)
    }

    /// Anchors a root. The pathname is collapsed with `realpath` first so the anchor is taken on
    /// the real directory, then opened `O_NOFOLLOW` so the final component cannot be a symlink.
    static func openRoot(_ url: URL) throws -> OpenDirectory {
        let requested = url.standardizedFileURL.path
        let resolved = realpathOf(requested) ?? requested
        let fd = resolved.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            throw FileDescriptorError.openFailed(component: resolved, code: errno)
        }
        return OpenDirectory(fd: fd, path: resolved)
    }

    /// Opens an already-existing directory directly by pathname, `O_NOFOLLOW`, with **no**
    /// `realpath` collapsing first (Codex G1 finding #4: "no realpath of a caller path"). Safe
    /// without `realpath` because `O_NOFOLLOW` only ever refuses the *final* path component: a
    /// symlink anywhere *above* this directory (`/var` -> `/private/var`) is still resolved
    /// transparently by the kernel as ordinary path lookup; only this directory's own final
    /// component is refused if it turns out to be a symlink. Use ``openRoot(_:)`` instead when the
    /// caller's spelling and its `realpath`-collapsed form need to be treated as the same root
    /// (the authorization/anchor use case); use this when the caller already knows the exact
    /// directory that exists and wants no pathname resolution applied to it at all.
    static func openExisting(_ url: URL) throws -> OpenDirectory {
        let path = url.standardizedFileURL.path
        let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            throw FileDescriptorError.openFailed(component: path, code: errno)
        }
        return OpenDirectory(fd: fd, path: path)
    }

    /// Opens a child directory without following a symlink. `ELOOP` here is the attack being
    /// refused: the component was a symlink at the moment of the call.
    func openChildDirectory(_ name: String) throws -> OpenDirectory {
        try Self.validate(component: name)
        let fd = name.withCString { openat(self.fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard fd >= 0 else {
            let code = errno
            switch code {
            case ELOOP, ENOTDIR:
                // `O_NOFOLLOW` refused it either way; which of the two the kernel reports for a
                // symlink-to-directory varies, so the entry is re-stat'd purely to name the
                // refusal accurately. The open already failed: this changes the message, never
                // the outcome.
                let kind = (try? identity(ofChild: name))?.kind
                throw kind == .symbolicLink
                    ? FileDescriptorError.symlinkComponent(component: name)
                    : FileDescriptorError.notADirectory(component: name)
            default:
                throw FileDescriptorError.openFailed(component: name, code: code)
            }
        }
        return OpenDirectory(fd: fd, path: path + "/" + name)
    }

    /// `fstatat(..., AT_SYMLINK_NOFOLLOW)`: the identity of a child, relative to this descriptor.
    func identity(ofChild name: String, volume: VolumeIdentity? = nil) throws -> FileIdentity {
        try Self.validate(component: name)
        var status = stat()
        let result = name.withCString { fstatat(self.fd, $0, &status, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else {
            throw FileDescriptorError.statFailed(component: name, code: errno)
        }
        return FileIdentity(status, volume: volume)
    }

    /// Identity of the directory this descriptor already holds open. Immune to any rename.
    func identity(volume: VolumeIdentity? = nil) throws -> FileIdentity {
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw FileDescriptorError.statFailed(component: path, code: errno)
        }
        return FileIdentity(status, volume: volume)
    }

    func unlinkChild(_ name: String) throws {
        try Self.validate(component: name)
        guard name.withCString({ unlinkat(self.fd, $0, 0) }) == 0 else {
            throw FileDescriptorError.syscallFailed(name: "unlinkat", component: name, code: errno)
        }
    }

    /// `unlinkat(AT_REMOVEDIR)` is `rmdir`: it refuses a non-empty directory, which is exactly the
    /// guarantee that makes bottom-up removal safe.
    func removeChildDirectory(_ name: String) throws {
        try Self.validate(component: name)
        guard name.withCString({ unlinkat(self.fd, $0, AT_REMOVEDIR) }) == 0 else {
            throw FileDescriptorError.syscallFailed(name: "unlinkat(AT_REMOVEDIR)", component: name, code: errno)
        }
    }

    /// Idempotent create: an existing directory at `name` is accepted silently. Correct for the
    /// top-level, long-lived quarantine container (`.sweep-quarantine`) that every trash
    /// operation in a session legitimately shares and re-opens — but never appropriate for a
    /// slot that must be provably fresh; see ``makeChildDirectoryExclusive(_:mode:)`` for that.
    func makeChildDirectory(_ name: String, mode: mode_t = 0o700) throws {
        try Self.validate(component: name)
        guard name.withCString({ mkdirat(self.fd, $0, mode) }) == 0 else {
            if errno == EEXIST { return }
            throw FileDescriptorError.syscallFailed(name: "mkdirat", component: name, code: errno)
        }
    }

    /// Review finding #3: `mkdirat` treating `EEXIST` as success is only safe for a container
    /// meant to be shared and reused (``makeChildDirectory(_:mode:)`` above). A per-operation or
    /// per-item quarantine slot must be provably fresh — nothing else, including a same-uid
    /// process racing this one or a slot planted before this run started, may already occupy
    /// that name — so this variant fails loudly on `EEXIST` instead of quietly reusing whatever
    /// is already there.
    func makeChildDirectoryExclusive(_ name: String, mode: mode_t = 0o700) throws {
        try Self.validate(component: name)
        guard name.withCString({ mkdirat(self.fd, $0, mode) }) == 0 else {
            if errno == EEXIST {
                throw FileDescriptorError.alreadyExists(component: name)
            }
            throw FileDescriptorError.syscallFailed(name: "mkdirat", component: name, code: errno)
        }
    }

    /// Descriptor-relative atomic rename. Both ends are inodes, so neither side can be redirected
    /// by a concurrent rename of a directory in either pathname.
    func renameChild(_ name: String, into destination: OpenDirectory, as newName: String) throws {
        try Self.validate(component: name)
        try Self.validate(component: newName)
        let result = name.withCString { source in
            newName.withCString { target in
                renameat(self.fd, source, destination.fd, target)
            }
        }
        guard result == 0 else {
            throw FileDescriptorError.syscallFailed(name: "renameat", component: name, code: errno)
        }
    }

    /// Entry names in this directory, `.` and `..` removed.
    func childNames() throws -> [String] {
        let duplicate = dup(fd)
        guard duplicate >= 0 else {
            throw FileDescriptorError.syscallFailed(name: "dup", component: path, code: errno)
        }
        guard let handle = fdopendir(duplicate) else {
            let code = errno
            close(duplicate)
            throw FileDescriptorError.syscallFailed(name: "fdopendir", component: path, code: code)
        }
        defer { closedir(handle) }   // also closes `duplicate`

        var names: [String] = []
        while let entry = readdir(handle) {
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)
                ) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            names.append(name)
        }
        return names
    }

    /// A path component must be a single name. `.`, `..` and anything containing a separator are
    /// rejected before they reach a syscall, so no relative escape is expressible.
    static func validate(component: String) throws {
        guard !component.isEmpty,
              component != ".",
              component != "..",
              !component.contains("/"),
              !component.utf8.contains(0)
        else {
            throw FileDescriptorError.invalidComponent(component)
        }
    }
}

/// A location expressed as an anchored root descriptor plus a list of validated components.
///
/// Nothing in the deletion path takes a pathname: it takes one of these, walks it descriptor by
/// descriptor, and hands back the open parent plus the leaf's name.
struct FileDescriptorPath {

    /// Components of `url` relative to `root`, or `nil` when `url` is not strictly under it.
    ///
    /// Both ends are collapsed with `realpath` — the root, and the item's *parent* — so the two
    /// are compared in one canonical spelling (`/var/…` and `/private/var/…` are the same
    /// directory) and so an item reached through a symlinked parent is judged by where it really
    /// lives. A parent that resolves outside the root returns `nil`.
    ///
    /// The last component is never resolved: a symlink item is deleted as the link it is, not as
    /// whatever it points at. The result is only a *route*; the descent is what proves it, and it
    /// refuses any symlink that appears along it afterwards.
    static func relativeComponents(of url: URL, under root: URL) -> [String]? {
        let standardizedRoot = root.standardizedFileURL.path
        let rootPath = realpathOf(standardizedRoot) ?? standardizedRoot
        let lexicalParent = url.deletingLastPathComponent().standardizedFileURL.path
        let parentPath = realpathOf(lexicalParent) ?? lexicalParent

        // Two spellings are accepted for the root, and only two: its resolved form and the one it
        // was given. A parent that does not exist yet (or vanished) cannot be resolved, so the
        // lexical pair is what lets a vanished item still be reported as vanished rather than as
        // an escape.
        let candidates: [(root: String, parent: String)] = [
            (rootPath, parentPath),
            (standardizedRoot, lexicalParent),
        ]
        var stripped: [String]?
        for candidate in candidates {
            let rootComponents = candidate.root.split(separator: "/").map(String.init)
            var parentComponents = candidate.parent.split(separator: "/").map(String.init)
            guard parentComponents.count >= rootComponents.count,
                  Array(parentComponents.prefix(rootComponents.count)) == rootComponents
            else { continue }
            parentComponents.removeFirst(rootComponents.count)
            stripped = parentComponents
            break
        }
        guard let parentComponents = stripped else { return nil }

        let relative = parentComponents + [url.lastPathComponent]
        guard relative.allSatisfy({ $0 != "." && $0 != ".." && !$0.isEmpty && !$0.contains("/") }) else {
            return nil
        }
        return relative
    }

    /// Walks from `root` down to the leaf's parent, opening every intermediate component with
    /// `O_NOFOLLOW | O_DIRECTORY`.
    ///
    /// `expectedParent`, when the scan captured one, is compared against the final directory's
    /// identity taken from its own descriptor (review finding #5): the chain has to be the chain
    /// the plan was built from, not merely *a* chain of directories with the right names.
    static func descend(
        from root: OpenDirectory,
        components: [String],
        expectedParent: FileIdentity?,
        maximumDepth: Int = 128
    ) throws -> (parent: OpenDirectory, leaf: String) {
        guard let leaf = components.last else {
            throw FileDescriptorError.invalidComponent("")
        }
        guard components.count <= maximumDepth else {
            throw FileDescriptorError.tooDeep(path: components.joined(separator: "/"))
        }

        let rootIdentity = try root.identity()
        var current = root
        for component in components.dropLast() {
            let next = try current.openChildDirectory(component)
            let identity = try next.identity()
            guard identity.deviceID == rootIdentity.deviceID else {
                throw FileDescriptorError.volumeBoundary(component: component)
            }
            current = next
        }

        if let expectedParent {
            let actual = try current.identity(volume: expectedParent.volume)
            guard actual.isSameFile(as: expectedParent) else {
                throw FileDescriptorError.componentIdentityChanged(
                    component: components.dropLast().last ?? root.path
                )
            }
        }

        try OpenDirectory.validate(component: leaf)
        return (current, leaf)
    }
}

/// `realpath(3)`. Used only to anchor a root, where symlinks above it (`/var` → `/private/var`)
/// are legitimate. Below the anchor, a symlink is refused rather than resolved.
func realpathOf(_ path: String) -> String? {
    guard let buffer = path.withCString({ realpath($0, nil) }) else { return nil }
    defer { free(buffer) }
    return String(cString: buffer)
}
