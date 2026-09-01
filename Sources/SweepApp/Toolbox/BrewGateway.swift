import Darwin
import Foundation

// MARK: - Models

/// One installed formula or cask, sized on disk.
struct BrewPackage: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let isCask: Bool
    let installedVersion: String?
    let latestVersion: String?
    let sizeBytes: Int64

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

/// What the Homebrew screen needs from brew. Behind a protocol so `HomebrewModel` is unit
/// testable against `FixtureBrewGateway` without ever launching a process, and so a screenshot
/// run can request fixture data (`SWEEP_TOOLBOX_BREW_FIXTURE=1`) on a machine where a real
/// Homebrew refresh would be slow — "fixture data acceptable for Homebrew if machine brew is
/// slow" is a data-source choice, not a UI compromise: the screen code is identical either way.
protocol BrewGateway: Sendable {
    var isAvailable: Bool { get }
    func snapshot() async throws -> BrewSnapshot
    /// `brew cleanup --prune=all --dry-run` — read-only, safe to call any time.
    func cleanupPreview() async throws -> String
    /// `brew cleanup --prune=all` — only ever called after the caller has shown the preview above
    /// and the user confirmed.
    func cleanup() async throws -> String
    func autoremovePreview() async throws -> String
    func autoremove() async throws -> String
    func upgrade(_ package: BrewPackage) async throws -> String
}

// MARK: - Real gateway

/// Process-backed gateway. Every mutating call (`cleanup`, `autoremove`, `upgrade`) runs the real
/// `brew` subcommand as the current user — PLAN §2's "typed command adapters... run as user,
/// never root" — via `BrewProcessRunner`, never a shell.
struct RealBrewGateway: BrewGateway {
    private let brewPath: String?

    init(brewPath: String? = BrewExecutable.locate()) {
        self.brewPath = brewPath
    }

    var isAvailable: Bool { brewPath != nil }

    func snapshot() async throws -> BrewSnapshot {
        guard let brewPath else { throw BrewGatewayError.brewNotFound }
        return try await Task.detached(priority: .utility) {
            try Self.buildSnapshot(brewPath: brewPath)
        }.value
    }

    func cleanupPreview() async throws -> String { try await run(["cleanup", "--prune=all", "--dry-run"]) }
    func cleanup() async throws -> String { try await run(["cleanup", "--prune=all"]) }
    func autoremovePreview() async throws -> String { try await run(["autoremove", "--dry-run"]) }
    func autoremove() async throws -> String { try await run(["autoremove"]) }

    func upgrade(_ package: BrewPackage) async throws -> String {
        try await run(package.isCask ? ["upgrade", "--cask", package.name] : ["upgrade", package.name])
    }

    private func run(_ arguments: [String]) async throws -> String {
        guard let brewPath else { throw BrewGatewayError.brewNotFound }
        return try await Task.detached(priority: .userInitiated) {
            try BrewProcessRunner.run(brewPath: brewPath, arguments)
        }.value
    }

    // MARK: - Snapshot assembly (runs off the main actor; `brew list`/`--prefix`/`--cache` are
    // fast, but sizing every Cellar/Caskroom directory is a real disk walk per package)

    private static func buildSnapshot(brewPath: String) throws -> BrewSnapshot {
        let prefix = try BrewProcessRunner.run(brewPath: brewPath, ["--prefix"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cellar = URL(fileURLWithPath: prefix).appendingPathComponent("Cellar")
        let caskroom = URL(fileURLWithPath: prefix).appendingPathComponent("Caskroom")

        let formulaNames = lines(try BrewProcessRunner.run(brewPath: brewPath, ["list", "--formula", "-1"]))
        let caskNames = lines(try BrewProcessRunner.run(brewPath: brewPath, ["list", "--cask", "-1"]))

        let outdatedJSON = try BrewProcessRunner.run(brewPath: brewPath, ["outdated", "--json=v2"])
        let outdated = try decodeOutdated(outdatedJSON)
        let outdatedFormulaByName = Dictionary(outdated.formulae.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let outdatedCaskByName = Dictionary(outdated.casks.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

        var packages: [BrewPackage] = []
        for name in formulaNames {
            let entry = outdatedFormulaByName[name]
            packages.append(BrewPackage(
                id: "formula:\(name)",
                name: name,
                isCask: false,
                installedVersion: entry?.installedVersions.last,
                latestVersion: entry?.currentVersion,
                sizeBytes: DirectorySize.allocatedBytes(at: cellar.appendingPathComponent(name))
            ))
        }
        for name in caskNames {
            let entry = outdatedCaskByName[name]
            packages.append(BrewPackage(
                id: "cask:\(name)",
                name: name,
                isCask: true,
                installedVersion: entry?.installedVersions.last,
                latestVersion: entry?.currentVersion,
                sizeBytes: DirectorySize.allocatedBytes(at: caskroom.appendingPathComponent(name))
            ))
        }

        // `brew --cache` (not `SweepPolicy.resolvedRoots(for: .homebrewCache)`) on purpose: brew
        // honors `HOMEBREW_CACHE` and a user who has relocated it (e.g. off the internal drive)
        // has a real cache directory `SweepPolicy`'s fixed `~/Library/Caches/Homebrew` candidate
        // would never find — asking the tool that owns the setting beats guessing its default.
        var cache: BrewCacheInfo?
        if let cachePath = try? BrewProcessRunner.run(brewPath: brewPath, ["--cache"])
            .trimmingCharacters(in: .whitespacesAndNewlines), !cachePath.isEmpty {
            cache = BrewCacheInfo(path: cachePath, sizeBytes: DirectorySize.allocatedBytes(at: URL(fileURLWithPath: cachePath)))
        }

        return BrewSnapshot(packages: packages.sorted { $0.sizeBytes > $1.sizeBytes }, cache: cache, prefix: prefix)
    }

    private static func lines(_ output: String) -> [String] {
        output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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

/// On-disk sizing for one Cellar/Caskroom/cache directory, entirely in-process (`FileManager` +
/// `lstat`) rather than shelling out to `du`: this module already launches `brew` as its one
/// external command per PLAN §2, and a size readout is exactly the kind of typed, native API read
/// `SweepCore.ScanEngine` already uses everywhere else in Sweep (allocated blocks, hard-link
/// deduplicated), so this keeps every size in the app honest the same way.
enum DirectorySize {
    private struct InodeKey: Hashable {
        let device: Int32
        let inode: UInt64
    }

    /// Sum of on-disk allocated bytes under `url`, each inode counted once. Missing or unreadable
    /// paths return 0 rather than throwing — an uninstalled package or a permission hiccup is a
    /// size of zero on this screen, never an error banner.
    static func allocatedBytes(at url: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: nil, options: []
        ) else { return 0 }

        var total: Int64 = 0
        var seen = Set<InodeKey>()
        for case let fileURL as URL in enumerator {
            var info = stat()
            // `lstat`, never `stat`: a symlink (common inside a Caskroom `.app`) is sized as
            // itself, never followed — following one risks double-counting or an infinite loop
            // through a self-referential link, neither of which this screen needs to guard
            // against by hand when `lstat` already refuses to.
            guard lstat(fileURL.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
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
/// for it, and by `HomebrewModelTests`. Every mutating call fails loudly rather than silently
/// pretending to succeed: a fixture that quietly "ran" `cleanup` would be a worse test double than
/// no test double at all.
struct FixtureBrewGateway: BrewGateway {
    enum FixtureError: Error, Sendable { case mutationsDisabled }

    var isAvailable = true
    var snapshotResult: Result<BrewSnapshot, Error> = .success(.sample)
    var previewOutput = "Nothing to prune, would remove 0B."
    var mutationResult: Result<String, Error> = .failure(FixtureError.mutationsDisabled)

    func snapshot() async throws -> BrewSnapshot { try snapshotResult.get() }
    func cleanupPreview() async throws -> String { previewOutput }
    func cleanup() async throws -> String { try mutationResult.get() }
    func autoremovePreview() async throws -> String { previewOutput }
    func autoremove() async throws -> String { try mutationResult.get() }
    func upgrade(_ package: BrewPackage) async throws -> String { try mutationResult.get() }
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
