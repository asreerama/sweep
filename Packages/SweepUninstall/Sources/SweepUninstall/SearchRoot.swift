import Foundation

/// Leftover search roots, per PLAN.md §3 module 5: the `~/Library` subdirectories most
/// third-party leftovers land in, plus `/Library/LaunchDaemons` and pkgutil's receipts
/// database. Ported knowledge from Pearcleaner's `Logic/Locations.swift`, narrowed to the
/// roots this deliverable specifies (Pearcleaner also globs many app-specific dev-tool /
/// analytics-SDK cache paths — that curated list belongs to the System Junk / Developer
/// modules' rule catalog, not the uninstaller's ownership matcher).
public enum SearchRoot: String, CaseIterable, Sendable, Hashable {
    case applicationSupport
    case caches
    case preferences
    case containers
    case groupContainers
    case savedApplicationState
    case launchAgents
    case webKit
    case httpStorages
    case libraryLaunchDaemons
    case pkgReceipt

    /// Resolves the root to a concrete filesystem location. `homeDirectory`,
    /// `systemLaunchDaemonsDirectory`, and `pkgutilReceiptsDirectory` are overridable so tests
    /// can point every root — including the two system-owned ones — at a fixture tree instead
    /// of real system directories, without this package ever needing write access to test.
    public func url(
        homeDirectory: URL,
        systemLaunchDaemonsDirectory: URL = URL(fileURLWithPath: "/Library/LaunchDaemons"),
        pkgutilReceiptsDirectory: URL = URL(fileURLWithPath: "/private/var/db/receipts")
    ) -> URL {
        switch self {
        case .applicationSupport: homeDirectory.appendingPathComponent("Library/Application Support")
        case .caches: homeDirectory.appendingPathComponent("Library/Caches")
        case .preferences: homeDirectory.appendingPathComponent("Library/Preferences")
        case .containers: homeDirectory.appendingPathComponent("Library/Containers")
        case .groupContainers: homeDirectory.appendingPathComponent("Library/Group Containers")
        case .savedApplicationState: homeDirectory.appendingPathComponent("Library/Saved Application State")
        case .launchAgents: homeDirectory.appendingPathComponent("Library/LaunchAgents")
        case .webKit: homeDirectory.appendingPathComponent("Library/WebKit")
        case .httpStorages: homeDirectory.appendingPathComponent("Library/HTTPStorages")
        case .libraryLaunchDaemons: systemLaunchDaemonsDirectory
        case .pkgReceipt: pkgutilReceiptsDirectory
        }
    }

    /// Extra recursion depth allowed past the root's immediate children, for roots known to
    /// nest vendor subfolders one level down (e.g. `Application Support/JetBrains/Toolbox`).
    /// Still depth-limited — never an unbounded walk.
    var extraDepth: Int {
        switch self {
        case .applicationSupport, .caches: 1
        default: 0
        }
    }

    /// All filesystem roots this package actually walks with `FileManager` (excludes
    /// `.pkgReceipt`, which is queried via `pkgutil` instead — see `PkgutilReceipts.swift`).
    public static var filesystemRoots: [SearchRoot] {
        allCases.filter { $0 != .pkgReceipt }
    }

    /// Finds which filesystem root (if any) an absolute URL falls under. Used to attribute a
    /// `Conditions`-table forced-include path to its real root rather than inventing a
    /// synthetic provenance value. (Only ever searches `filesystemRoots`, so a
    /// `pkgutilReceiptsDirectory` override is never relevant here.)
    static func root(
        containing url: URL,
        homeDirectory: URL,
        systemLaunchDaemonsDirectory: URL
    ) -> SearchRoot? {
        let standardized = url.standardizedFileURL.path
        for root in filesystemRoots {
            let rootPath = root.url(homeDirectory: homeDirectory, systemLaunchDaemonsDirectory: systemLaunchDaemonsDirectory).standardizedFileURL.path
            if standardized == rootPath || standardized.hasPrefix(rootPath + "/") {
                return root
            }
        }
        return nil
    }
}
