import Darwin
import Foundation
import SweepUI

// MARK: - Models

/// One installed formula or cask, sized on disk.
struct BrewPackage: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isCask: Bool
    let installedVersion: String?
    let latestVersion: String?
    let sizeBytes: Int64
    /// Folded once here so the screen's per-keystroke filter is a plain `contains`, same
    /// construction-time discipline as `InventoryItem.searchKey`.
    let searchKey: String

    init(
        id: String, name: String, isCask: Bool,
        installedVersion: String?, latestVersion: String?, sizeBytes: Int64
    ) {
        self.id = id
        self.name = name
        self.isCask = isCask
        self.installedVersion = installedVersion
        self.latestVersion = latestVersion
        self.sizeBytes = sizeBytes
        self.searchKey = SearchFold.fold(name)
    }

    var isOutdated: Bool { latestVersion != nil }
}

struct BrewCacheInfo: Sendable, Hashable {
    let path: String
    let sizeBytes: Int64
}

/// Everything the Homebrew screen renders from one refresh.
struct BrewSnapshot: Sendable {
    let packages: [BrewPackage]
    let cache: BrewCacheInfo?
    let prefix: String

    static let empty = BrewSnapshot(packages: [], cache: nil, prefix: "")

    var outdated: [BrewPackage] { packages.filter(\.isOutdated) }
    var formulae: [BrewPackage] { packages.filter { !$0.isCask } }
    var casks: [BrewPackage] { packages.filter(\.isCask) }
    var totalBytes: Int64 { packages.reduce(0) { $0 + $1.sizeBytes } }
}

/// The slow tail of a refresh: what `brew outdated --json=v2` knows about newer versions, plus
/// the download cache's location and size. Fetched in the background *after* the listing is
/// already on screen — see `HomebrewModel.refresh()`'s staged-load doc.
struct BrewUpdateCheck: Sendable {
    let outdated: BrewOutdatedResponse
    let cache: BrewCacheInfo?
}

enum BrewGatewayError: Error, CustomStringConvertible, Sendable, Equatable {
    case brewNotFound
    case malformedOutput(String)

    var description: String {
        switch self {
        case .brewNotFound:
            "Homebrew was not found at \(BrewExecutable.appleSiliconPath) or \(BrewExecutable.intelPath)."
        case .malformedOutput(let detail):
            "Homebrew returned output Sweep could not parse: \(detail)"
        }
    }
}

// MARK: - Gateway protocol (test/fixture seam, mirrors `CleanBackend`)

/// What the Homebrew screen needs from brew, split into a staged read so the screen can render
/// the instant it opens (measured on this machine, 2026-09-01: the old single `snapshot()` call
/// took ~4.6 s warm — 3.45 s of serial per-package disk sizing plus 0.7 s of `brew outdated` —
/// which read as "the Homebrew screen is slow" next to apps that list packages instantly):
///
/// 1. ``listing()`` — names and installed versions straight from the Cellar/Caskroom directory
///    layout, no `brew` process at all. Milliseconds; this is what makes the screen instant.
/// 2. ``sizes(for:)`` — the real per-package disk walk, run concurrently and merged in when done.
/// 3. ``updateCheck()`` — `brew outdated` plus the cache readout, the only part that needs brew's
///    own knowledge, merged in whenever it lands.
///
/// Behind a protocol so `HomebrewModel` is unit testable against `FixtureBrewGateway` without
/// ever launching a process, and so a screenshot run can request fixture data
/// (`SWEEP_TOOLBOX_BREW_FIXTURE=1`) — a data-source choice, not a UI compromise: the screen code
/// is identical either way.
protocol BrewGateway: Sendable {
    var isAvailable: Bool { get }
    /// Filesystem-only: package names + installed versions from Cellar/Caskroom directory names.
    /// Sizes are 0 and `latestVersion` nil until the later stages land.
    func listing() async throws -> BrewSnapshot
    /// On-disk allocated bytes for each of `packages`, keyed by `BrewPackage.id`. Never throws:
    /// an unreadable directory is a size of zero on this screen, not an error banner.
    func sizes(for packages: [BrewPackage]) async -> [String: Int64]
    /// `brew outdated --json=v2` + `brew --cache` — the refresh's slow tail.
    func updateCheck() async throws -> BrewUpdateCheck
    /// `brew cleanup --prune=all --dry-run` — read-only, safe to call any time.
    func cleanupPreview() async throws -> String
    /// `brew cleanup --prune=all` — only ever called after the caller has shown the preview above
    /// and the user confirmed.
    func cleanup() async throws -> String
    func autoremovePreview() async throws -> String
    func autoremove() async throws -> String
    func upgrade(_ package: BrewPackage) async throws -> String
    /// `brew uninstall [--cask] <name>` — only ever called through the preview-then-confirm flow,
    /// same contract as every other mutation here.
    func uninstall(_ package: BrewPackage) async throws -> String
}

// MARK: - Real gateway

/// Process-backed gateway. Every mutating call (`cleanup`, `autoremove`, `upgrade`) runs the real
/// `brew` subcommand as the current user — PLAN §2's "typed command adapters... run as user,
/// never root" — via `BrewProcessRunner`, never a shell. Reads, by contrast, avoid launching
/// `brew` wherever the filesystem already has the answer: the Cellar/Caskroom layout *is* brew's
/// own installed-package database, and reading it directly is what makes ``listing()`` instant.
struct RealBrewGateway: BrewGateway {
    private let brewPath: String?

    init(brewPath: String? = BrewExecutable.locate()) {
        self.brewPath = brewPath
    }

    var isAvailable: Bool { brewPath != nil }

    /// `/opt/homebrew/bin/brew` → `/opt/homebrew` (and the Intel equivalent). Fixed layout —
    /// brew itself derives the prefix the same way.
    static func prefix(forBrewPath brewPath: String) -> String {
        ((brewPath as NSString).deletingLastPathComponent as NSString).deletingLastPathComponent
    }

    func listing() async throws -> BrewSnapshot {
        guard let brewPath else { throw BrewGatewayError.brewNotFound }
        return try await Task.detached(priority: .userInitiated) {
            Self.buildListing(prefix: Self.prefix(forBrewPath: brewPath))
        }.value
    }

    /// One `Cellar/<name>/<version>` (or `Caskroom/<token>/<version>`) readdir pass. The newest
    /// version directory is reported as the installed version — with multiple kegs present that
    /// matches `brew outdated`'s `installed_versions.last` convention, and ``updateCheck()``
    /// refines it later for the outdated rows anyway.
    private static func buildListing(prefix: String) -> BrewSnapshot {
        var packages: [BrewPackage] = []
        for (root, isCask) in [(prefix + "/Cellar", false), (prefix + "/Caskroom", true)] {
            for entry in versionedDirectories(in: root) {
                packages.append(BrewPackage(
                    id: "\(isCask ? "cask" : "formula"):\(entry.name)",
                    name: entry.name,
                    isCask: isCask,
                    installedVersion: entry.version,
                    latestVersion: nil,
                    sizeBytes: 0
                ))
            }
        }
        return BrewSnapshot(packages: packages, cache: nil, prefix: prefix)
    }

    private static func versionedDirectories(in root: String) -> [(name: String, version: String?)] {
        let fileManager = FileManager.default
        guard let names = try? fileManager.contentsOfDirectory(atPath: root) else { return [] }
        return names
            .filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .compactMap { name in
                let directory = root + "/" + name
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: directory, isDirectory: &isDirectory),
                      isDirectory.boolValue else { return nil }
                let versions = ((try? fileManager.contentsOfDirectory(atPath: directory)) ?? [])
                    .filter { !$0.hasPrefix(".") }
                    .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
                return (name, versions.last)
            }
    }

    /// Every package's walk is its own task — the walks are syscall-bound and independent, and
    /// the concurrent pool brings the measured 3.45 s serial pass down to well under a second on
    /// a warm cache.
    func sizes(for packages: [BrewPackage]) async -> [String: Int64] {
        guard let brewPath else { return [:] }
        let prefix = Self.prefix(forBrewPath: brewPath)
        return await withTaskGroup(of: (String, Int64).self, returning: [String: Int64].self) { group in
            for package in packages {
                let root = prefix + (package.isCask ? "/Caskroom/" : "/Cellar/") + package.name
                group.addTask(priority: .utility) {
                    (package.id, DirectorySize.allocatedBytes(atPath: root))
                }
            }
            var result: [String: Int64] = [:]
            for await (id, bytes) in group { result[id] = bytes }
            return result
        }
    }

    func updateCheck() async throws -> BrewUpdateCheck {
        guard let brewPath else { throw BrewGatewayError.brewNotFound }
        return try await Task.detached(priority: .utility) {
            let outdated = try Self.decodeOutdated(
                BrewProcessRunner.run(brewPath: brewPath, ["outdated", "--json=v2"])
            )
            // `brew --cache` (not `SweepPolicy.resolvedRoots(for: .homebrewCache)`) on purpose:
            // brew honors `HOMEBREW_CACHE` and a user who has relocated it (e.g. off the internal
            // drive) has a real cache directory `SweepPolicy`'s fixed `~/Library/Caches/Homebrew`
            // candidate would never find — asking the tool that owns the setting beats guessing
            // its default.
            var cache: BrewCacheInfo?
            if let cachePath = try? BrewProcessRunner.run(brewPath: brewPath, ["--cache"])
                .trimmingCharacters(in: .whitespacesAndNewlines), !cachePath.isEmpty {
                cache = BrewCacheInfo(path: cachePath, sizeBytes: DirectorySize.allocatedBytes(atPath: cachePath))
            }
            return BrewUpdateCheck(outdated: outdated, cache: cache)
        }.value
    }

    /// Mutations get their own clock and output budget (user-reported: "I confirm the upgrade,
    /// the loader goes around for a minute, but the upgrade doesn't happen"): a real
    /// `brew upgrade` downloads and installs for MINUTES, and the default 30 s read timeout was
    /// killing every one of them mid-download — the failure landed in the console disclosure
    /// while the package, honestly, stayed outdated. 30 minutes is generous headroom for a big
    /// bottle on a slow connection while still being a real hang ceiling; 32 MB likewise for a
    /// chatty install log, where overflowing the cap would kill a live install.
    private static let mutationTimeout: TimeInterval = 30 * 60
    private static let mutationOutputByteLimit = 32 * 1024 * 1024

    func cleanupPreview() async throws -> String { try await run(["cleanup", "--prune=all", "--dry-run"]) }
    func cleanup() async throws -> String { try await mutate(["cleanup", "--prune=all"]) }
    func autoremovePreview() async throws -> String { try await run(["autoremove", "--dry-run"]) }
    func autoremove() async throws -> String { try await mutate(["autoremove"]) }

    func upgrade(_ package: BrewPackage) async throws -> String {
        try await mutate(package.isCask ? ["upgrade", "--cask", package.name] : ["upgrade", package.name])
    }

    func uninstall(_ package: BrewPackage) async throws -> String {
        try await mutate(package.isCask ? ["uninstall", "--cask", package.name] : ["uninstall", package.name])
    }

    /// Reads: fast commands on the default 30 s clock.
    private func run(_ arguments: [String]) async throws -> String {
        guard let brewPath else { throw BrewGatewayError.brewNotFound }
        return try await Task.detached(priority: .userInitiated) {
            try BrewProcessRunner.run(brewPath: brewPath, arguments)
        }.value
    }

    private func mutate(_ arguments: [String]) async throws -> String {
        guard let brewPath else { throw BrewGatewayError.brewNotFound }
        return try await Task.detached(priority: .userInitiated) {
            try BrewProcessRunner.run(
                brewPath: brewPath, arguments,
                timeout: Self.mutationTimeout, outputByteLimit: Self.mutationOutputByteLimit
            )
        }.value
    }

    private static func decodeOutdated(_ json: String) throws -> BrewOutdatedResponse {
        guard let data = json.data(using: .utf8), !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return BrewOutdatedResponse(formulae: [], casks: [])
        }
        do {
            return try JSONDecoder().decode(BrewOutdatedResponse.self, from: data)
        } catch {
            throw BrewGatewayError.malformedOutput(String(describing: error))
        }
    }
}

/// Mirrors `brew outdated --json=v2`'s real shape (verified against Homebrew 6.0.15 output).
struct BrewOutdatedResponse: Decodable, Sendable {
    let formulae: [BrewOutdatedEntry]
    let casks: [BrewOutdatedEntry]
}

struct BrewOutdatedEntry: Decodable, Sendable {
    let name: String
    let installedVersions: [String]
    let currentVersion: String

    enum CodingKeys: String, CodingKey {
        case name
        case installedVersions = "installed_versions"
        case currentVersion = "current_version"
    }
}

// MARK: - Directory sizing

/// On-disk sizing for one Cellar/Caskroom/cache directory, entirely in-process rather than
/// shelling out to `du`: this module already launches `brew` as its one external command per
/// PLAN §2, and a size readout is exactly the kind of typed, native API read
/// `SweepCore.ScanEngine` already uses everywhere else in Sweep (allocated blocks, hard-link
/// deduplicated), so this keeps every size in the app honest the same way.
///
/// Walks with `fts(3)`, not `FileManager.enumerator`: the enumerator pays per-entry URL
/// construction plus a redundant `lstat` on top of its own directory reads, measured here at
/// 3.45 s over this machine's ~200 k Cellar files where a bare `find` does the same walk in
/// 0.47 s. `fts` hands back each entry's `stat` from the walk itself — no second syscall, no URL.
enum DirectorySize {
    private struct InodeKey: Hashable {
        let device: Int32
        let inode: UInt64
    }

    /// Sum of on-disk allocated bytes under `path`, each inode counted once. Missing or
    /// unreadable paths return 0 rather than throwing — an uninstalled package or a permission
    /// hiccup is a size of zero on this screen, never an error banner.
    static func allocatedBytes(atPath path: String) -> Int64 {
        // `FTS_PHYSICAL`, never `FTS_LOGICAL`: a symlink (common inside a Caskroom `.app`) is
        // sized as itself, never followed — following one risks double-counting or an infinite
        // loop through a self-referential link, neither of which needs guarding by hand when the
        // walk itself refuses to follow.
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(argv[0]) }
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return 0 }
        defer { fts_close(stream) }

        var total: Int64 = 0
        var seen = Set<InodeKey>()
        while let entry = fts_read(stream) {
            guard Int32(entry.pointee.fts_info) == FTS_F, let info = entry.pointee.fts_statp?.pointee else { continue }
            let key = InodeKey(device: info.st_dev, inode: info.st_ino)
            guard seen.insert(key).inserted else { continue }
            // `st_blocks` is always in 512-byte units, independent of the filesystem's own block
            // size (a POSIX guarantee `stat(2)` documents), so this needs no APFS-specific math.
            total += Int64(info.st_blocks) * 512
        }
        return total
    }
}

// MARK: - Fixture gateway (screenshots / tests without a real `brew` invocation)

/// Realistic, static data mirroring a real `brew outdated --json=v2`/`brew list` run on this
/// machine (Homebrew 6.0.15, captured 2026-09-01) — used when `SWEEP_TOOLBOX_BREW_FIXTURE=1` asks
/// for it, and by `HomebrewModelTests`. The staged reads all derive from one `snapshotResult` so
/// a test controls the whole refresh with a single seam. Every mutating call fails loudly rather
/// than silently pretending to succeed: a fixture that quietly "ran" `cleanup` would be a worse
/// test double than no test double at all.
struct FixtureBrewGateway: BrewGateway {
    enum FixtureError: Error, Sendable { case mutationsDisabled }

    var isAvailable = true
    var snapshotResult: Result<BrewSnapshot, Error> = .success(.sample)
    var previewOutput = "Nothing to prune, would remove 0B."
    var mutationResult: Result<String, Error> = .failure(FixtureError.mutationsDisabled)

    func listing() async throws -> BrewSnapshot { try snapshotResult.get() }

    func sizes(for packages: [BrewPackage]) async -> [String: Int64] {
        guard let snapshot = try? snapshotResult.get() else { return [:] }
        return Dictionary(snapshot.packages.map { ($0.id, $0.sizeBytes) }, uniquingKeysWith: { first, _ in first })
    }

    func updateCheck() async throws -> BrewUpdateCheck {
        let snapshot = try snapshotResult.get()
        func entry(_ package: BrewPackage) -> BrewOutdatedEntry {
            BrewOutdatedEntry(
                name: package.name,
                installedVersions: [package.installedVersion].compactMap { $0 },
                currentVersion: package.latestVersion ?? ""
            )
        }
        return BrewUpdateCheck(
            outdated: BrewOutdatedResponse(
                formulae: snapshot.formulae.filter(\.isOutdated).map(entry),
                casks: snapshot.casks.filter(\.isOutdated).map(entry)
            ),
            cache: snapshot.cache
        )
    }

    func cleanupPreview() async throws -> String { previewOutput }
    func cleanup() async throws -> String { try mutationResult.get() }
    func autoremovePreview() async throws -> String { previewOutput }
    func autoremove() async throws -> String { try mutationResult.get() }
    func upgrade(_ package: BrewPackage) async throws -> String { try mutationResult.get() }
    func uninstall(_ package: BrewPackage) async throws -> String { try mutationResult.get() }
}

extension BrewSnapshot {
    static let sample = BrewSnapshot(
        packages: [
            BrewPackage(id: "formula:pytorch", name: "pytorch", isCask: false, installedVersion: "2.11.0", latestVersion: "2.13.0_3", sizeBytes: 2_840_000_000),
            BrewPackage(id: "formula:ffmpeg", name: "ffmpeg", isCask: false, installedVersion: "8.1", latestVersion: "9.0.1_1", sizeBytes: 412_000_000),
            BrewPackage(id: "formula:node", name: "node", isCask: false, installedVersion: "26.4.0", latestVersion: "26.8.1", sizeBytes: 118_000_000),
            BrewPackage(id: "formula:gcc", name: "gcc", isCask: false, installedVersion: "15.2.0_1", latestVersion: "16.2.0", sizeBytes: 612_000_000),
            BrewPackage(id: "formula:go", name: "go", isCask: false, installedVersion: nil, latestVersion: nil, sizeBytes: 528_000_000),
            BrewPackage(id: "formula:jq", name: "jq", isCask: false, installedVersion: nil, latestVersion: nil, sizeBytes: 2_100_000),
            BrewPackage(id: "formula:openssl@3", name: "openssl@3", isCask: false, installedVersion: "3.6.3", latestVersion: "3.6.4", sizeBytes: 9_400_000),
            BrewPackage(id: "cask:home-assistant", name: "home-assistant", isCask: true, installedVersion: "2026.4", latestVersion: "2026.9.0", sizeBytes: 210_000_000),
            BrewPackage(id: "cask:flutter", name: "flutter", isCask: true, installedVersion: nil, latestVersion: nil, sizeBytes: 3_120_000_000),
            BrewPackage(id: "cask:codexbar", name: "codexbar", isCask: true, installedVersion: nil, latestVersion: nil, sizeBytes: 24_000_000),
        ],
        cache: BrewCacheInfo(path: "/Volumes/DevSSD/Caches/Homebrew", sizeBytes: 4_920_000_000),
        prefix: "/opt/homebrew"
    )
}
