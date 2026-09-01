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
    /// Three things happen here that did not before:
    ///
    /// - `O_APPEND`, so every write lands at the real end of file. A one-time `seekToEnd` was
    ///   only correct while exactly one instance existed (review finding #7).
    /// - `flock(LOCK_EX | LOCK_NB)`, held for the descriptor's life, so a second owner is told
    ///   so instead of silently interleaving records with the first.
    /// - `fsync` of the containing directory and of every ancestor this call created, so the
    ///   directory *entry* for the journal survives a power loss, not just its contents
    ///   (review finding #8).
    static func open(url: URL) throws -> JournalFile {
        let directory = url.deletingLastPathComponent()
        let created = try createDirectories(at: directory, journalURL: url)

        let path = url.path
        let fd = path.withCString { Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC, 0o600) }
        guard fd >= 0 else {
            throw JournalError.cannotCreate(url: url, reason: String(cString: strerror(errno)))
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

    func readAll() throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw JournalError.cannotCreate(url: url, reason: error.localizedDescription)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        flock(fd, LOCK_UN)
        Darwin.close(fd)
    }
}
