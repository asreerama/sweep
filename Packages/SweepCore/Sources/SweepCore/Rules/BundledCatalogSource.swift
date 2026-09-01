import CryptoKit
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
        /// There is no baked-in expected digest to compare it against in this build (that needs
        /// a signing manifest for `rules/`, which does not exist yet) — this is recorded so a
        /// caller inspecting a `CleanReport` or the WAL later has a tamper-evident fingerprint of
        /// what actually authorized the run.
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
        BundledCatalogDirectoryBox.shared.setOnce(directory)
    }

    /// Test-only escape hatch for the write-once box above. Every SweepCore test that needs
    /// `CleanService` to authorize against a specific fixture catalog calls this before
    /// `configureBundledCatalogDirectory`, so each test gets its own directory instead of racing
    /// whichever test happened to call `configureBundledCatalogDirectory` first in the process.
    /// Nothing in this package's non-test sources references it, and it is still internal —
    /// unreachable from a module that imports SweepCore without `@testable`.
    static func resetBundledCatalogDirectoryForTesting() {
        BundledCatalogDirectoryBox.shared.reset()
    }

    /// Loads, validates and hash-pins the bundled catalog: the injected directory if one was
    /// configured, otherwise `Bundle.main`'s own `rules/catalog.json` resource. This is the
    /// *only* route by which `CleanService` ever obtains a `RuleCatalog` — never a caller's.
    static func loadPinnedBundledCatalog() throws -> PinnedCatalog {
        let directory = try resolveBundledCatalogDirectory()
        let catalogURL = directory.appending(path: RuleCatalogLoader.bundledCatalogFileName)
        let data: Data
        do {
            data = try Data(contentsOf: catalogURL)
        } catch {
            throw RuleCatalogError.unreadable(url: catalogURL, reason: error.localizedDescription)
        }
        let catalog = try RuleCatalogLoader.loadBundled(from: directory)
        // Belt and suspenders: `loadBundled` (via `RuleCatalog`'s `Decodable` initializer)
        // already validates, but this finding asked for validation to be mandatory *inside the
        // load* regardless of how the catalog got here, so a future loader change cannot
        // silently drop it without this call still catching it.
        try catalog.validate()

        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return PinnedCatalog(catalog: catalog, sha256Hex: hex)
    }

    private static func resolveBundledCatalogDirectory() throws -> URL {
        if let injected = BundledCatalogDirectoryBox.shared.value { return injected }
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
}

/// The write-once box itself, pulled out of `CleanService` so its locking is auditable on its
/// own. `@unchecked Sendable`: every access is through the lock.
private final class BundledCatalogDirectoryBox: @unchecked Sendable {
    static let shared = BundledCatalogDirectoryBox()

    private let lock = NSLock()
    private var directory: URL?

    var value: URL? {
        lock.lock()
        defer { lock.unlock() }
        return directory
    }

    func setOnce(_ url: URL) {
        lock.lock()
        defer { lock.unlock() }
        guard directory == nil else { return }
        directory = url
    }

    func reset() {
        lock.lock()
        defer { lock.unlock() }
        directory = nil
    }
}
