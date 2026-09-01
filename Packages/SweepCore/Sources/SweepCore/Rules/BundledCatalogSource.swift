import CryptoKit
import Darwin
import Foundation

/// Codex Gate-1 finding #1 (CRITICAL): before this, `CleanRequest` took a caller-supplied
/// `catalog: RuleCatalog`. A caller could run a real scan under an allowlisted root, stamp an
/// arbitrary rule id onto a candidate, and hand `CleanService` a hand-built `RuleCatalog`
/// containing a broad `.safe`/`.trash` rule for that id — every subsequent identity/root check
/// would pass, because they all trust the caller's catalog to say what the rule means. Deletion
/// only ever authorizes against a catalog `CleanService` loaded and validated itself.
extension CleanService {

    /// One successfully loaded, hash-pinned bundled catalog.
    struct PinnedCatalog: Sendable {
        let catalog: RuleCatalog
        /// Hex-encoded SHA-256 of the exact `catalog.json` bytes this catalog was decoded from.
        /// There is no signed manifest for `rules/` to compare this against yet: see the doc
        /// comment on ``CleanService/loadPinnedBundledCatalog()`` for the accepted interim design
        /// and the upgrade path. Recorded so a caller inspecting a `CleanReport` or the WAL later
        /// has a tamper-evident fingerprint of what actually authorized the run, and so a
        /// ``SelectionBatch`` minted at scan time can be refused if the catalog changed before
        /// execute time.
        let sha256Hex: String
    }

    enum BundledCatalogError: Error, Equatable, CustomStringConvertible {
        case unavailable
        var description: String {
            "no bundled rule catalog directory found: no directory was injected at startup and "
                + "Bundle.main carries no rules/catalog.json resource"
        }
    }

    /// Write-once injection point for the directory holding the signed bundle's `schema.json` +
    /// `catalog.json` pair. Internal: this is startup wiring for the loader, not part of the
    /// pinned `CleanRequest`/`CleanReport` surface, and nothing outside this package may repoint
    /// it once a process is running. The first call wins; every call after that is a no-op, so
    /// an already-running process's catalog source can never be swapped out from under it.
    static func configureBundledCatalogDirectory(_ directory: URL) {
        BundledCatalogDirectoryBox.shared.setDirectoryOnce(directory)
    }

    /// Test-only escape hatch for the write-once box above. Every SweepCore test that needs
    /// `CleanService` to authorize against a specific fixture catalog calls this before
    /// `configureBundledCatalogDirectory`, so each test gets its own directory instead of racing
    /// whichever test happened to call `configureBundledCatalogDirectory` first in the process.
    /// Also clears the cached pinned catalog below it, so a later test's fixture bytes are the
    /// ones actually read, never a previous test's cached decode. Nothing in this package's
    /// non-test sources references it, and it is still internal: unreachable from a module that
    /// imports SweepCore without `@testable`.
    static func resetBundledCatalogDirectoryForTesting() {
        BundledCatalogDirectoryBox.shared.reset()
    }

    /// Loads, validates and hash-pins the bundled catalog: the injected directory if one was
    /// configured, otherwise `Bundle.main`'s own `rules/catalog.json` resource. This is the
    /// *only* route by which `CleanService` ever obtains a `RuleCatalog` — never a caller's.
    ///
    /// Codex Gate-1 finding #2 (CRITICAL): the previous version pinned only a mutable *directory*
    /// URL and re-read `catalog.json` from that pathname on every call, once via
    /// `Data(contentsOf:)` to compute the digest, and again, independently, via
    /// `RuleCatalogLoader.loadBundled(from:)` to decode it. Two separate pathname reads of the
    /// same name mean the digest could describe different bytes than the ones actually decoded
    /// (a symlink swap or a rewrite between the two reads, or between any two calls, changes what
    /// a running process authorizes against without ever touching the pinned directory). Pinning
    /// the directory was never pinning the catalog.
    ///
    /// Now: the directory is opened once as a descriptor, `catalog.json` is opened relative to it
    /// with `openat(..., O_NOFOLLOW)`, a symlink planted at that name is refused outright
    /// (`ELOOP`), never followed, and read into memory exactly once. Those exact bytes are both
    /// decoded and hashed, so the digest is provably a digest of what got decoded. The resulting
    /// `PinnedCatalog` is cached in the write-once box below the first time this succeeds; every
    /// later call in this process, from any thread, returns that cached value without reading the
    /// filesystem again: "pinned" now means what it says.
    ///
    /// There is no signed manifest for `rules/` yet to compare the digest against before caching
    /// it; that is out of scope here and remains the accepted interim design (Codex's own
    /// framing: "read-once + journaled digest is the accepted design"). The upgrade path is a
    /// signed manifest shipped alongside `rules/catalog.json`. Once it exists, this function is
    /// where the digest computed below would be checked against it *before* the result is cached,
    /// refusing to pin (and to run) a catalog whose signature does not verify.
    static func loadPinnedBundledCatalog() throws -> PinnedCatalog {
        if let cached = BundledCatalogDirectoryBox.shared.cachedPinnedCatalog {
            return cached
        }

        let directory = try resolveBundledCatalogDirectory()
        let data = try readCatalogBytesOnce(inDirectory: directory)
        let catalog = try RuleCatalogLoader.load(data: data)
        // Belt and suspenders: decoding (via `RuleCatalog`'s `Decodable` initializer) already
        // validates, but this finding asked for validation to be mandatory *inside the load*
        // regardless of how the catalog got here, so a future loader change cannot silently drop
        // it without this call still catching it.
        try catalog.validate()

        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        let pinned = PinnedCatalog(catalog: catalog, sha256Hex: hex)

        // First successful load in the process wins; a call racing this one gets back the exact
        // same cached value rather than whatever its own concurrent read produced.
        return BundledCatalogDirectoryBox.shared.cachePinnedCatalogOnce(pinned)
    }

    /// The digest half of ``loadPinnedBundledCatalog()``, exposed publicly (Codex G1 finding #5)
    /// so a caller outside this package (a scan, specifically) can embed "the catalog I saw" as
    /// a ``SelectionBatch/catalogDigest``. Never exposes the catalog itself, only its digest, and
    /// calling it never re-reads the filesystem once a catalog is already pinned: it is exactly
    /// ``loadPinnedBundledCatalog()``, which caches after its first successful call.
    public static func currentCatalogDigest() throws -> String {
        try loadPinnedBundledCatalog().sha256Hex
    }

    private static func resolveBundledCatalogDirectory() throws -> URL {
        if let injected = BundledCatalogDirectoryBox.shared.directory { return injected }
        if let bundledCatalog = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "rules") {
            return bundledCatalog.deletingLastPathComponent()
        }
        if let resourceURL = Bundle.main.resourceURL {
            let candidate = resourceURL.appending(path: "rules")
            let catalogPath = candidate.appending(path: RuleCatalogLoader.bundledCatalogFileName).path
            if FileManager.default.fileExists(atPath: catalogPath) {
                return candidate
            }
        }
        throw BundledCatalogError.unavailable
    }

    /// Opens `directory` as a descriptor and reads `catalog.json` relative to it with a single
    /// `openat(..., O_NOFOLLOW)`, never a second pathname lookup, and never a symlink followed.
    /// `schema.json`'s *presence* (not its contents: the schema is never parsed at runtime; see
    /// ``RuleCatalogLoader/loadBundled(from:)``) is checked the same way, via `fstatat` against
    /// the same directory descriptor, so the whole read is one open directory, two syscalls, no
    /// second pathname resolution anywhere in between.
    private static func readCatalogBytesOnce(inDirectory directory: URL) throws -> Data {
        let directoryPath = directory.standardizedFileURL.path
        let directoryFD = directoryPath.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_CLOEXEC) }
        guard directoryFD >= 0 else {
            throw RuleCatalogError.unreadable(
                url: directory, reason: "open(\(directoryPath)): \(String(cString: strerror(errno)))"
            )
        }
        defer { Darwin.close(directoryFD) }

        let schemaName = RuleCatalogLoader.bundledSchemaFileName
        var schemaStatus = stat()
        guard schemaName.withCString({ fstatat(directoryFD, $0, &schemaStatus, AT_SYMLINK_NOFOLLOW) }) == 0 else {
            throw RuleCatalogError.unreadable(
                url: directory.appending(path: schemaName),
                reason: "\(schemaName) not found alongside \(RuleCatalogLoader.bundledCatalogFileName)"
            )
        }

        let catalogName = RuleCatalogLoader.bundledCatalogFileName
        let catalogURL = directory.appending(path: catalogName)
        let fileFD = catalogName.withCString {
            Darwin.openat(directoryFD, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard fileFD >= 0 else {
            let code = errno
            let reason = code == ELOOP
                ? "refused: \(catalogName) is a symlink; the bundled catalog is never read through one"
                : String(cString: strerror(code))
            throw RuleCatalogError.unreadable(url: catalogURL, reason: reason)
        }
        defer { Darwin.close(fileFD) }

        var status = stat()
        guard fstat(fileFD, &status) == 0 else {
            throw RuleCatalogError.unreadable(url: catalogURL, reason: "fstat: \(String(cString: strerror(errno)))")
        }
        guard status.st_mode & S_IFMT == S_IFREG else {
            throw RuleCatalogError.unreadable(url: catalogURL, reason: "refused: \(catalogName) is not a regular file")
        }

        var data = Data()
        data.reserveCapacity(max(0, Int(status.st_size)))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let bytesRead = buffer.withUnsafeMutableBytes { raw -> Int in
                Darwin.read(fileFD, raw.baseAddress, raw.count)
            }
            if bytesRead < 0 {
                if errno == EINTR { continue }
                throw RuleCatalogError.unreadable(url: catalogURL, reason: "read: \(String(cString: strerror(errno)))")
            }
            if bytesRead == 0 { break }
            data.append(contentsOf: buffer[0..<bytesRead])
        }
        return data
    }
}

/// The write-once directory, plus the pinned catalog it produced, cached after the first
/// successful load (Codex G1 finding #2). Pulled out of `CleanService` so its locking is
/// auditable on its own. `@unchecked Sendable`: every access is through the lock.
private final class BundledCatalogDirectoryBox: @unchecked Sendable {
    static let shared = BundledCatalogDirectoryBox()

    private let lock = NSLock()
    private var directoryValue: URL?
    private var pinnedCatalogValue: CleanService.PinnedCatalog?

    var directory: URL? {
        lock.lock()
        defer { lock.unlock() }
        return directoryValue
    }

    var cachedPinnedCatalog: CleanService.PinnedCatalog? {
        lock.lock()
        defer { lock.unlock() }
        return pinnedCatalogValue
    }

    func setDirectoryOnce(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard directoryValue == nil else { return }
        directoryValue = url
    }

    /// First successful load wins for the life of the box; every call after that, even one that
    /// raced this one, gets back this exact value instead of whatever its own read produced.
    @discardableResult
    func cachePinnedCatalogOnce(_ candidate: CleanService.PinnedCatalog) -> CleanService.PinnedCatalog {
        lock.lock()
        defer { lock.unlock() }
        if let pinnedCatalogValue { return pinnedCatalogValue }
        pinnedCatalogValue = candidate
        return candidate
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        directoryValue = nil
        pinnedCatalogValue = nil
    }
}
