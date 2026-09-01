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
    /// Four things happen here that did not before:
    ///
    /// - The containing directory is opened by descriptor first, and the journal file itself is
    ///   opened `openat(dirFD, name, O_NOFOLLOW)` relative to it — never `open(fullPath)` — so a
    ///   pre-planted symlink named `clean-journal.jsonl` is refused outright (`ELOOP`) instead of
    ///   silently followed into appending WAL JSON onto an arbitrary writable target (review
    ///   finding #2).
    /// - `O_APPEND`, so every write lands at the real end of file. A one-time `seekToEnd` was
    ///   only correct while exactly one instance existed (review finding #7).
    /// - The opened file is `fstat`'d and refused unless it is a regular file, owned by this
    ///   account, and not writable by group or other — closing the other half of finding #2:
    ///   even a non-symlink node planted at that path (a FIFO, a device node, a file some other
    ///   uid or a looser mode controls) is refused before a single byte is ever written to it.
    /// - `flock(LOCK_EX | LOCK_NB)`, held for the descriptor's life, so a second owner is told
    ///   so instead of silently interleaving records with the first.
    /// - `fsync` of the containing directory and of every ancestor this call created, so the
    ///   directory *entry* for the journal survives a power loss, not just its contents
    ///   (review finding #8).
    static func open(url: URL) throws -> JournalFile {
        let directory = url.deletingLastPathComponent()
        let created = try createDirectories(at: directory, journalURL: url)

        // Ancestors above the directory legitimately contain symlinks (`/var` -> `/private/var`);
        // only the *leaf* journal file itself must never be one, which is what `O_NOFOLLOW` below
        // enforces. `realpath` here only collapses the (already-created) containing directory's
        // own spelling, mirroring `OpenDirectory.openRoot`.
        let resolvedDirectoryPath = realpathOf(directory.standardizedFileURL.path) ?? directory.standardizedFileURL.path
        let dirFD = resolvedDirectoryPath.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard dirFD >= 0 else {
            throw JournalError.cannotCreate(
                url: url, reason: "open(\(resolvedDirectoryPath)): \(String(cString: strerror(errno)))"
            )
        }
        defer { Darwin.close(dirFD) }

        let filename = url.lastPathComponent
        let fd = filename.withCString {
            Darwin.openat(dirFD, $0, O_RDWR | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
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
    /// `O_NOFOLLOW` would not catch), owned by this account, with no group/other write access.
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

    /// Creates missing ancestors of `directory`, returning the ones this call actually created,
    /// shallowest first.
    private static func createDirectories(at directory: URL, journalURL: URL) throws -> [String] {
        var missing: [URL] = []
        var current = directory.standardizedFileURL
        while !FileManager.default.fileExists(atPath: current.path) {
            missing.append(current)
            let parent = current.deletingLastPathComponent().standardizedFileURL
            if parent.path == current.path { break }
            current = parent
        }
        guard !missing.isEmpty else { return [] }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw JournalError.cannotCreate(url: journalURL, reason: error.localizedDescription)
        }
        return missing.reversed().map(\.path)
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
