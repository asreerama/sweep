import Darwin
import Foundation

/// The journal's file descriptor and every syscall that touches it.
///
/// Split out of ``WALJournal`` so the durability rules live in one auditable place, and so the
/// descriptor has a single-threaded owner: every method must run on the journal's serial
/// ``BlockingIOQueue``. That is what makes `@unchecked Sendable` true rather than hopeful.
final class JournalFile: @unchecked Sendable {
    let url: URL
    /// Directories `fsync`'d at open: the journal's own directory plus every ancestor this open
    /// had to create. Recorded so the ordering guarantee is testable rather than assumed.
    private(set) var syncedDirectories: [String] = []

    private var fd: Int32
    private var closed = false

    private init(fd: Int32, url: URL) {
        self.fd = fd
        self.url = url
    }

    deinit {
        if !closed { Darwin.close(fd) }
    }

    var isClosed: Bool { closed }

    /// Opens the journal for appending, exclusively, and makes its existence durable.
    ///
    /// Five things happen here that did not before:
    ///
    /// - The containing directory is reached by descending from the nearest already-existing
    ///   ancestor one path component at a time: `openat`/`mkdirat`, `O_NOFOLLOW` at every step,
    ///   **no `realpath` anywhere in the descent**. The journal file itself is opened
    ///   `openat(dirFD, name, O_NOFOLLOW)` relative to the result, never `open(fullPath)`. A
    ///   pre-planted symlink anywhere along the way (the containing directory itself, or any
    ///   component Sweep creates leading to it) is refused outright (`ELOOP`), never silently
    ///   followed (Codex G1 finding #4, and review finding #2's discipline extended to the
    ///   directory chain, not just the leaf file).
    /// - Every directory Sweep itself creates along that descent is `fstat`'d immediately after
    ///   creation and refused unless it is owned by this account with no group/other write access
    ///   (finding #4: "verify ownership/mode per component"). The pre-existing ancestor found at
    ///   the top of the descent is the one trust boundary, exactly the way `OpenDirectory.openRoot`
    ///   already treats its own anchor.
    /// - `O_APPEND`, so every write lands at the real end of file. A one-time `seekToEnd` was
    ///   only correct while exactly one instance existed (review finding #7).
    /// - The opened file is `fstat`'d and refused unless it is a regular file with exactly one
    ///   hard link, owned by this account, and not writable by group or other: closing the other
    ///   half of finding #2 and finding #4's hard-link gap. Even a non-symlink node planted at
    ///   that path (a FIFO, a device node, a file some other uid or a looser mode controls, or a
    ///   *hard link* into another private regular file this account owns) is refused before a
    ///   single byte is ever written to it. `O_NOFOLLOW` alone does not catch a hard link: it is
    ///   never a symlink, it is literally the same inode reachable under a second name, which is
    ///   exactly why `st_nlink` has to be checked explicitly.
    /// - `flock(LOCK_EX | LOCK_NB)`, held for the descriptor's life, so a second owner is told
    ///   so instead of silently interleaving records with the first.
    /// - `fsync` of the containing directory and of every ancestor this call created, so the
    ///   directory *entry* for the journal survives a power loss, not just its contents
    ///   (review finding #8).
    static func open(url: URL) throws -> JournalFile {
        let directory = url.deletingLastPathComponent()
        let (anchor, created) = try descendCreatingDirectories(to: directory, journalURL: url)

        let filename = url.lastPathComponent
        // `anchor` (an `OpenDirectory`) closes its own descriptor in `deinit`. `withExtendedLifetime`
        // guarantees ARC cannot deallocate it (and so cannot close `anchor.fd` out from under this
        // syscall) before `openat` has actually run.
        let fd = withExtendedLifetime(anchor) {
            filename.withCString {
                Darwin.openat(anchor.fd, $0, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
            }
        }
        guard fd >= 0 else {
            let code = errno
            let reason = code == ELOOP
                ? "refused: \(filename) is a symlink; the journal is never opened through one"
                : String(cString: strerror(code))
            throw JournalError.cannotCreate(url: url, reason: reason)
        }

        do {
            try verifyOwnedPrivateRegularFile(fd: fd, filename: filename)
        } catch {
            Darwin.close(fd)
            throw error
        }

        let file = JournalFile(fd: fd, url: url)

        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK || code == EAGAIN {
                throw JournalError.locked(url: url)
            }
            throw JournalError.cannotCreate(url: url, reason: "flock: \(String(cString: strerror(code)))")
        }

        // Deepest first: a directory entry is only durable once the directory that holds it is.
        for path in ([directory.path] + created).reversed() {
            try syncDirectory(atPath: path, url: url)
            file.syncedDirectories.append(path)
        }
        return file
    }

    /// Refuses anything opened above that is not exactly what this process created or already
    /// owns exclusively: a regular file (never a FIFO or device node slipped in under a name
    /// `O_NOFOLLOW` would not catch) with exactly one hard link (never a pre-planted hard link
    /// into some other private, same-owner regular file: `O_NOFOLLOW` cannot catch this, because
    /// a hard link is not a symlink, it is the same inode under a second name), owned by this
    /// account, with no group/other write access (Codex G1 finding #4).
    private static func verifyOwnedPrivateRegularFile(fd: Int32, filename: String) throws {
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw JournalError.cannotCreate(
                url: URL(fileURLWithPath: filename), reason: "fstat: \(String(cString: strerror(errno)))"
            )
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw JournalError.cannotCreate(
                url: URL(fileURLWithPath: filename), reason: "refused: \(filename) is not a regular file"
            )
        }
        guard status.st_nlink == 1 else {
            throw JournalError.cannotCreate(
                url: URL(fileURLWithPath: filename),
                reason: "refused: \(filename) has \(status.st_nlink) hard links; the journal must be the only name for its inode"
            )
        }
        guard status.st_uid == getuid() else {
            throw JournalError.cannotCreate(
                url: URL(fileURLWithPath: filename), reason: "refused: \(filename) is not owned by this account"
            )
        }
        guard status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw JournalError.cannotCreate(
                url: URL(fileURLWithPath: filename), reason: "refused: \(filename) is writable by group or other"
            )
        }
    }

    /// Reaches `directory` by descending from the nearest already-existing ancestor one path
    /// component at a time, creating whatever is missing along the way. Returns the open
    /// descriptor on `directory` itself, plus every path this call created, shallowest first.
    ///
    /// No `realpath` anywhere in this descent (Codex G1 finding #4: "no realpath of a caller
    /// path"). None is needed: `O_NOFOLLOW` only ever refuses the *final* component of
    /// whatever path a syscall is given, so opening the nearest existing ancestor's raw pathname
    /// directly is exactly as safe as opening a pre-resolved one. A symlink anywhere *above* that
    /// ancestor (`/var` -> `/private/var`) is still traversed transparently by the kernel as
    /// ordinary path resolution; only the ancestor's own final component, and everything Sweep
    /// creates below it, is ever refused if it turns out to be a symlink.
    private static func descendCreatingDirectories(
        to directory: URL, journalURL: URL
    ) throws -> (anchor: OpenDirectory, created: [String]) {
        var missingComponents: [String] = []
        var ancestor = directory.standardizedFileURL
        while !FileManager.default.fileExists(atPath: ancestor.path) {
            missingComponents.append(ancestor.lastPathComponent)
            let parent = ancestor.deletingLastPathComponent().standardizedFileURL
            guard parent.path != ancestor.path else {
                throw JournalError.cannotCreate(
                    url: journalURL, reason: "no existing ancestor found above \(directory.path)"
                )
            }
            ancestor = parent
        }
        missingComponents.reverse()   // shallowest first

        var current: OpenDirectory
        do {
            current = try OpenDirectory.openExisting(ancestor)
        } catch {
            throw JournalError.cannotCreate(url: journalURL, reason: String(describing: error))
        }

        var created: [String] = []
        for component in missingComponents {
            do {
                try current.makeChildDirectory(component)
                let child = try current.openChildDirectory(component)
                try verifyOwnedPrivateDirectory(child, journalURL: journalURL)
                current = child
            } catch {
                throw JournalError.cannotCreate(url: journalURL, reason: String(describing: error))
            }
            created.append(current.path)
        }

        return (current, created)
    }

    /// A directory Sweep itself just created along the journal's path must verify as exclusively
    /// this account's before anything descends into it further. Mirrors
    /// `verifyOwnedPrivateRegularFile`'s discipline, applied to a directory (Codex G1 finding #4).
    private static func verifyOwnedPrivateDirectory(_ directory: OpenDirectory, journalURL: URL) throws {
        var status = stat()
        guard fstat(directory.fd, &status) == 0 else {
            throw JournalError.cannotCreate(url: journalURL, reason: "fstat: \(String(cString: strerror(errno)))")
        }
        guard status.st_uid == getuid() else {
            throw JournalError.cannotCreate(
                url: journalURL, reason: "refused: \(directory.path) is not owned by this account"
            )
        }
        guard status.st_mode & (S_IWGRP | S_IWOTH) == 0 else {
            throw JournalError.cannotCreate(
                url: journalURL, reason: "refused: \(directory.path) is writable by group or other"
            )
        }
    }

    private static func syncDirectory(atPath path: String, url: URL) throws {
        let fd = path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard fd >= 0 else {
            throw JournalError.syncFailed(reason: "open(\(path)): \(String(cString: strerror(errno)))")
        }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else {
            throw JournalError.syncFailed(reason: "fsync(\(path)): \(String(cString: strerror(errno)))")
        }
    }

    /// One framed record, appended and made durable. `O_APPEND` makes the offset atomic, so two
    /// writers can never overlay each other's bytes even if the lock were somehow bypassed.
    func append(_ data: Data) throws {
        guard !closed else { throw JournalError.closed }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw JournalError.writeFailed(reason: String(cString: strerror(errno)))
                }
                offset += written
            }
        }
        // fsync(2): the log must survive a power loss, not merely a crash.
        guard fsync(fd) == 0 else {
            throw JournalError.syncFailed(reason: String(cString: strerror(errno)))
        }
    }

    /// Cuts a torn final record off the end and makes the repair durable before anything is
    /// appended after it (review finding #6).
    func truncate(to length: Int) throws {
        guard !closed else { throw JournalError.closed }
        guard ftruncate(fd, off_t(length)) == 0 else {
            throw JournalError.writeFailed(reason: "ftruncate: \(String(cString: strerror(errno)))")
        }
        guard fsync(fd) == 0 else {
            throw JournalError.syncFailed(reason: "fsync after truncate: \(String(cString: strerror(errno)))")
        }
    }

    /// Reads the journal's current contents via `pread` against the same locked descriptor
    /// every append uses — never `Data(contentsOf: url)`. A pathname re-read here is exactly the
    /// other half of review finding #2: even with the open itself hardened, re-reading by
    /// pathname for recovery/replay would let a swap of the pathname *after* open cause recovery
    /// to see a different file than the one being appended to and locked.
    func readAll() throws -> Data {
        guard !closed else { throw JournalError.closed }
        var status = stat()
        guard fstat(fd, &status) == 0 else {
            throw JournalError.writeFailed(reason: "fstat: \(String(cString: strerror(errno)))")
        }
        let length = Int(status.st_size)
        guard length > 0 else { return Data() }

        var buffer = Data(count: length)
        var readError: Int32?
        let bytesRead: Int = buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return 0 }
            var readSoFar = 0
            while readSoFar < length {
                let n = pread(fd, base.advanced(by: readSoFar), length - readSoFar, off_t(readSoFar))
                if n < 0 {
                    if errno == EINTR { continue }
                    readError = errno
                    return readSoFar
                }
                if n == 0 { break }   // file shrank concurrently; stop at what is actually there
                readSoFar += n
            }
            return readSoFar
        }
        if let readError {
            throw JournalError.writeFailed(reason: "pread: \(String(cString: strerror(readError)))")
        }
        return buffer.prefix(bytesRead)
    }

    func close() {
        guard !closed else { return }
        closed = true
        flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}
