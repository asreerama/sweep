import Foundation
import SweepUI

// MARK: - Pure logic (unit-testable; see Tests/SweepAppTests/PluginInventoryTests.swift)

/// One plug-in surface Sweep inventories (Toolbox "Plugins" module).
///
/// Per-user and system-wide variants of the same surface merge into a single category — the
/// location is a per-item fact (``PluginScope``), never a second category — matching the
/// inventory spec ("each a category; per-user and system-wide variants merged into one category
/// with the location shown per item").
enum PluginCategory: String, CaseIterable, Sendable, Hashable {
    case spotlightImporter
    case quickLookGenerator
    case preferencePane
    case audioPlugin
    case internetPlugin
    case appExtension

    var title: String {
        switch self {
        case .spotlightImporter: "Spotlight Importers"
        case .quickLookGenerator: "Quick Look Generators"
        case .preferencePane: "Preference Panes"
        case .audioPlugin: "Audio Plug-Ins"
        case .internetPlugin: "Internet Plug-Ins"
        case .appExtension: "App Extensions"
        }
    }

    var symbol: String {
        switch self {
        case .spotlightImporter: "magnifyingglass"
        case .quickLookGenerator: "eye"
        case .preferencePane: "switch.2"
        case .audioPlugin: "waveform"
        case .internetPlugin: "network"
        case .appExtension: "puzzlepiece.extension"
        }
    }
}

/// Where one filesystem plug-in was found: the user's own Library, or a system-wide Library
/// directory. Drives the safety tier (INVENTORY SPEC "Tiering") — never a per-category constant,
/// since every filesystem category has both a user and a system root.
enum PluginScope: Sendable, Hashable {
    case user
    case system

    /// `~/Library` items are reversible by the user alone (`.safe`); `/Library` items need
    /// privileges Sweep never acquires, so a Trash attempt there is expected to need review even
    /// when the OS happens to allow it (`.caution`).
    var tier: SweepTier {
        switch self {
        case .user: .safe
        case .system: .caution
        }
    }
}

/// One plug-in row, filesystem-backed (categories 1-5) or a `pluginkit` app extension (category
/// 6). `id` is always the absolute path — the same convention every other inventory in this app
/// uses for reveal/trash targets (see `InventoryList`'s doc comment).
struct PluginItem: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let path: String
    /// Secondary line: a home-abbreviated path for categories 1-5, or "Lives inside <App>" for
    /// an app extension, which has no independent location worth showing — it lives wherever its
    /// parent app does.
    let detail: String
    /// CFBundleIdentifier (categories 1-5) or the containing app's name (category 6). `nil` when
    /// `Bundle(url:)` could not resolve one — routine for a plug-in with no `Info.plist` bundle
    /// identifier, not an error.
    let owner: String?
    let category: PluginCategory
    /// `nil` for app extensions: they are not a filesystem root Sweep owns a scope opinion about.
    let scope: PluginScope?
    /// `nil` for app extensions, which are read-only and carry no deletion-safety opinion at all
    /// (see `PluginItem.isRemovable`) — never `.safe`, which would read as Sweep vouching for a
    /// removal it does not offer.
    let tier: SweepTier?
    /// Allocated size on disk. Always 0 for app extensions: their bytes belong to the parent app
    /// bundle already counted by Uninstaller: double-counting them here would overstate space.
    let byteCount: Int64
    /// Categories 1-5 only. App extensions live inside their parent app; removing one means
    /// uninstalling that app, which is the Uninstaller module's job, not this one's.
    let isRemovable: Bool
}

/// One category's items, plus the totals its header shows.
struct PluginCategoryGroup: Identifiable, Sendable {
    let category: PluginCategory
    let items: [PluginItem]

    var id: String { category.rawValue }
    var byteCount: Int64 { items.reduce(0) { $0 + $1.byteCount } }
    /// Worst tier among the group's items — a group badge that read "Safe" while holding one
    /// `.caution` item would be a lie. App extensions (`tier == nil`) never enter this
    /// computation, so a pure app-extension group settles on `.safe` by default; the screen
    /// never actually shows a tier badge for that category (see `PluginsScreen`).
    var tier: SweepTier { items.compactMap(\.tier).max() ?? .safe }
}

/// SIP policy: everything under `/System` is excluded entirely, at every category. Not
/// actionable (SIP forbids touching it) and pure noise in an inventory meant to surface what a
/// user or a third-party installer put on the machine.
enum PluginPathPolicy {
    static func isUnderSystem(_ path: String) -> Bool {
        path == "/System" || path.hasPrefix("/System/")
    }
}

enum PluginInventoryLogic {
    static func excludingSystem(_ items: [PluginItem]) -> [PluginItem] {
        items.filter { !PluginPathPolicy.isUnderSystem($0.path) }
    }

    /// One `PluginCategoryGroup` per non-empty category, in the fixed order the inventory spec
    /// numbers them — never sorted by size the way a junk scan's groups are: this is a plug-in
    /// manager, and a stable category order is more legible than one that reshuffles on refresh.
    static func buildGroups(from items: [PluginItem]) -> [PluginCategoryGroup] {
        PluginCategory.allCases.compactMap { category in
            let matched = items.filter { $0.category == category }
            guard !matched.isEmpty else { return nil }
            return PluginCategoryGroup(category: category, items: matched)
        }
    }
}

// MARK: - pluginkit output parsing (pure)

/// The user-election tag `pluginkit -m -v` prefixes each line with (see `man pluginkit`
/// DISCOVERY MATCHING / `-m` section). Not surfaced as its own UI affordance yet; kept typed
/// rather than discarded so a future row detail ("ignored by you") is a display change only.
enum PluginKitElection: Sendable, Equatable {
    case use
    case ignore
    case debug
    case superseded
    case unknown
    case none
}

/// One parsed line of `pluginkit -m -v` output.
struct PluginKitEntry: Sendable, Equatable {
    let election: PluginKitElection
    let identifier: String
    let version: String?
    let uuid: String
    let path: String
}

/// Parses `/usr/bin/pluginkit -m -v` output as a pure function over its captured text, so the
/// real format (flag column, `identifier(version)`, UUID, timestamp, path — tab-separated after
/// the flag) is unit-testable against fixture strings without spawning a process.
///
/// Tolerant by construction: a line that does not carry an `identifier(version)` field and at
/// least three tab-separated fields after it is dropped rather than crashing or fabricating a
/// row. `pluginkit`'s own format has been stable for years, but this is System output Sweep does
/// not control, and a garbage or truncated line here must never take the whole scan down with it.
enum PluginKitParser {
    private static let electionFlags: Set<Character> = ["+", "-", "!", "=", "?"]

    static func parseLine(_ rawLine: String) -> PluginKitEntry? {
        var line = rawLine
        if line.hasSuffix("\r") { line.removeLast() }
        guard !line.isEmpty else { return nil }

        let election: PluginKitElection
        if let first = line.first, electionFlags.contains(first) {
            election = mapElection(first)
            line.removeFirst()
        } else {
            election = .none
        }

        // The flag (or its absence) is followed by column-padding whitespace of no fixed width;
        // trimming here is what makes the parser indifferent to exactly how many spaces `pluginkit`
        // used, real output or a hand-written fixture alike.
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let fields = trimmed.components(separatedBy: "\t").map { $0.trimmingCharacters(in: .whitespaces) }
        guard fields.count >= 4 else { return nil }

        let identifierAndVersion = fields[0]
        let uuid = fields[1]
        // fields[2] is the timestamp column — consumed to keep the index math honest, not
        // currently surfaced by any row.
        // A path field can itself contain spaces (real example: "Messages Share Extension.appex")
        // but never a literal tab, so this is always exactly fields[3]; joining any stray trailing
        // fields back in is a defensive no-op for anything short of malformed input.
        let path = fields[3...].joined(separator: "\t")

        guard
            let openParen = identifierAndVersion.firstIndex(of: "("),
            identifierAndVersion.hasSuffix(")")
        else { return nil }

        let identifier = String(identifierAndVersion[identifierAndVersion.startIndex..<openParen])
        let versionEnd = identifierAndVersion.index(before: identifierAndVersion.endIndex)
        let versionRaw = String(identifierAndVersion[identifierAndVersion.index(after: openParen)..<versionEnd])
        // `pluginkit` prints a missing version as the literal text "(null)" nested inside the
        // outer parens (e.g. `com.apple.fskit.exfat((null))`); stripping any wrapping parens
        // before comparing normalizes that down to "null" regardless of how many layers deep it
        // is quoted.
        let normalizedVersion = versionRaw.trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        let version: String? = (normalizedVersion.isEmpty || normalizedVersion == "null") ? nil : normalizedVersion

        guard !identifier.isEmpty, !uuid.isEmpty, !path.isEmpty else { return nil }

        return PluginKitEntry(election: election, identifier: identifier, version: version, uuid: uuid, path: path)
    }

    static func parse(_ output: String) -> [PluginKitEntry] {
        output.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { parseLine(String($0)) }
    }

    private static func mapElection(_ flag: Character) -> PluginKitElection {
        switch flag {
        case "+": .use
        case "-": .ignore
        case "!": .debug
        case "=": .superseded
        case "?": .unknown
        default: .none
        }
    }
}

/// Owner attribution for a `pluginkit` app extension (inventory spec, category 6): the containing
/// `.app`'s name when the path runs through one, else `"System"`.
enum PluginAppExtensionOwner {
    static func name(fromPath path: String) -> String {
        for component in path.split(separator: "/") where component.hasSuffix(".app") {
            return String(component.dropLast(4))
        }
        return "System"
    }
}

/// Builds read-only ``PluginItem`` rows straight from parsed `pluginkit` entries — pure, since an
/// app extension's row needs nothing PluginKit did not already print (no disk walk, no
/// `Bundle` lookup: it is not independently removable, so it carries no size and no bundle-id
/// owner of its own).
enum PluginAppExtensionBuilder {
    static func buildItems(from entries: [PluginKitEntry]) -> [PluginItem] {
        entries
            .map { entry -> PluginItem in
                let owner = PluginAppExtensionOwner.name(fromPath: entry.path)
                return PluginItem(
                    id: entry.path,
                    name: entry.identifier,
                    path: entry.path,
                    detail: "Lives inside \(owner)",
                    owner: owner,
                    category: .appExtension,
                    scope: nil,
                    tier: nil,
                    byteCount: 0,
                    isRemovable: false
                )
            }
            .sorted { lhs, rhs in
                if lhs.owner != rhs.owner { return (lhs.owner ?? "") < (rhs.owner ?? "") }
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
    }

    static func buildItems(from pluginKitOutput: String) -> [PluginItem] {
        buildItems(from: PluginKitParser.parse(pluginKitOutput))
    }
}

// MARK: - Filesystem surfaces (pure catalog; impure scan)

/// One directory Sweep checks for a given category/scope, and the bundle extensions that count as
/// a plug-in there.
struct PluginFilesystemSurface: Sendable {
    let category: PluginCategory
    let scope: PluginScope
    let directory: URL
    let extensions: Set<String>
}

/// Every filesystem root the inventory spec names (categories 1-5), as plain data — no disk
/// access — so the category/scope/extension assignment is unit-testable on its own, independent
/// of what happens to be installed on the machine running the tests.
enum PluginSurfaceCatalog {
    static func filesystemSurfaces(home: URL) -> [PluginFilesystemSurface] {
        func user(_ category: PluginCategory, _ relativePath: String, _ extensions: Set<String>) -> PluginFilesystemSurface {
            PluginFilesystemSurface(category: category, scope: .user, directory: home.appending(path: relativePath), extensions: extensions)
        }
        func system(_ category: PluginCategory, _ absolutePath: String, _ extensions: Set<String>) -> PluginFilesystemSurface {
            PluginFilesystemSurface(category: category, scope: .system, directory: URL(fileURLWithPath: absolutePath), extensions: extensions)
        }

        return [
            user(.spotlightImporter, "Library/Spotlight", ["mdimporter"]),
            system(.spotlightImporter, "/Library/Spotlight", ["mdimporter"]),

            user(.quickLookGenerator, "Library/QuickLook", ["qlgenerator"]),
            system(.quickLookGenerator, "/Library/QuickLook", ["qlgenerator"]),

            user(.preferencePane, "Library/PreferencePanes", ["prefpane"]),
            system(.preferencePane, "/Library/PreferencePanes", ["prefpane"]),

            user(.audioPlugin, "Library/Audio/Plug-Ins/Components", ["component"]),
            user(.audioPlugin, "Library/Audio/Plug-Ins/VST", ["vst"]),
            user(.audioPlugin, "Library/Audio/Plug-Ins/VST3", ["vst3"]),
            system(.audioPlugin, "/Library/Audio/Plug-Ins/Components", ["component"]),
            system(.audioPlugin, "/Library/Audio/Plug-Ins/VST", ["vst"]),
            system(.audioPlugin, "/Library/Audio/Plug-Ins/VST3", ["vst3"]),

            // The inventory spec gives no extension for this category (legacy NPAPI bundles);
            // ".plugin" is what every real Internet Plug-Ins install actually uses (Flash Player,
            // QuickTime, Java, …). ".webplugin" is included alongside it defensively — some older
            // third-party installers used that suffix — costing nothing when it matches nothing.
            user(.internetPlugin, "Library/Internet Plug-Ins", ["plugin", "webplugin"]),
            system(.internetPlugin, "/Library/Internet Plug-Ins", ["plugin", "webplugin"]),
        ]
    }
}

/// Walks a bundle directory summing allocated file sizes. Small `FileManager.enumerator` walk —
/// plug-in bundles at this scale (a handful of files, occasionally a large audio sample library)
/// do not need `fts` or a second engine; callers run this off the main actor regardless, since
/// even a `FileManager` enumerator is disk I/O.
enum PluginSizeCalculator {
    static func allocatedSize(at url: URL, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]
        ) else { return 0 }

        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard
                let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey]),
                values.isRegularFile == true
            else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }
        return total
    }
}

/// Read-only directory listing over the filesystem plug-in surfaces. Every failure (unreadable
/// directory, permission-denied stat) is dropped silently — a `/Library` directory this process
/// cannot list is routine on a stock Mac, not an error worth a footnote.
enum PluginFilesystemScanner {
    static func scan(_ surface: PluginFilesystemSurface, home: URL, fileManager: FileManager = .default) -> [PluginItem] {
        guard let entries = try? fileManager.contentsOfDirectory(at: surface.directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let homePath = home.path
        return entries
            .filter { surface.extensions.contains($0.pathExtension.lowercased()) }
            .map { url -> PluginItem in
                let size = PluginSizeCalculator.allocatedSize(at: url, fileManager: fileManager)
                let owner = Bundle(url: url)?.bundleIdentifier
                return PluginItem(
                    id: url.path,
                    name: url.deletingPathExtension().lastPathComponent,
                    path: url.path,
                    detail: SweepFormat.abbreviatingHome(url.path, home: homePath),
                    owner: owner,
                    category: surface.category,
                    scope: surface.scope,
                    tier: surface.scope.tier,
                    byteCount: size,
                    isRemovable: true
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func scanAll(home: URL, fileManager: FileManager = .default) -> [PluginItem] {
        PluginSurfaceCatalog.filesystemSurfaces(home: home).flatMap { scan($0, home: home, fileManager: fileManager) }
    }
}

/// Spawns `/usr/bin/pluginkit -m -v` exactly once per scan and hands back its raw stdout for
/// ``PluginKitParser`` to parse. Any launch failure (sandboxed build, missing binary) yields an
/// empty string, which parses to zero entries — the app extensions category is simply omitted
/// rather than the whole scan failing.
enum PluginKitRunner {
    static func captureOutput(executableURL: URL = URL(fileURLWithPath: "/usr/bin/pluginkit")) -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = ["-m", "-v"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return ""
        }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}

/// The full Plugins inventory: every filesystem surface plus one `pluginkit` spawn, merged and
/// grouped by category. Impure and comparatively slow (several directory walks and one process
/// spawn) — `PluginsModel` runs this inside a detached `Task`, mirroring every other Toolbox scan.
enum PluginInventoryEngine {
    static func scan(home: URL, fileManager: FileManager = .default) -> [PluginCategoryGroup] {
        let filesystemItems = PluginFilesystemScanner.scanAll(home: home, fileManager: fileManager)
        let appExtensionItems = PluginAppExtensionBuilder.buildItems(from: PluginKitRunner.captureOutput())
        let allItems = PluginInventoryLogic.excludingSystem(filesystemItems + appExtensionItems)
        return PluginInventoryLogic.buildGroups(from: allItems)
    }
}

// MARK: - Removal (impure)

enum PluginRemovalOutcome: Sendable, Equatable {
    case succeeded
    case failed(String)
}

/// Moves one filesystem plug-in to the Trash. Categories 1-5 only — `PluginsModel` never offers
/// this for an app extension, and the `isRemovable` guard here is the same refusal repeated at
/// the one place the actual mutation happens, in case a future call site forgets to check first.
enum PluginRemovalService {
    static func trash(_ item: PluginItem, fileManager: FileManager = .default) -> PluginRemovalOutcome {
        guard item.isRemovable else {
            return .failed("this item lives inside its owning app and cannot be removed from here")
        }
        do {
            try fileManager.trashItem(at: URL(fileURLWithPath: item.path), resultingItemURL: nil)
            return .succeeded
        } catch {
            return .failed((error as NSError).localizedDescription)
        }
    }
}
