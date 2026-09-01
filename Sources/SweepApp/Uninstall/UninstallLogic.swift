import Foundation
import SweepPolicy
import SweepUninstall

// MARK: - Pure logic (unit-testable; see Tests/SweepAppTests/UninstallerLogicTests.swift)

/// Sort keys the Uninstaller's app list offers (PLAN §3 module 5: "icons, sizes, last-used,
/// search + sort").
enum AppSortField: String, CaseIterable, Identifiable, Sendable {
    case name
    case size
    case lastUsed

    var id: Self { self }

    var label: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .lastUsed: "Last used"
        }
    }
}

enum UninstallLogic {
    /// Case- and diacritic-insensitive filter over name and bundle id, same contract as
    /// `InventoryGroup.filtered(by:)` elsewhere in the app.
    static func filterApps(_ apps: [InstalledApp], query: String) -> [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter { app in
            app.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (app.bundleIdentifier?.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    /// `sizeByPath`/`lastUsedByPath` are keyed by `InstalledApp.id` (the bundle path). Both are
    /// populated lazily in the background, so a sort can run before every value has arrived —
    /// apps with no value on record sort last regardless of direction, rather than jumping to
    /// wherever a missing `Int64`/`Date` would otherwise land.
    static func sortApps(
        _ apps: [InstalledApp],
        field: AppSortField,
        ascending: Bool,
        sizeByPath: [String: Int64],
        lastUsedByPath: [String: Date]
    ) -> [InstalledApp] {
        switch field {
        case .name:
            let sorted = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return ascending ? sorted : sorted.reversed()
        case .size:
            return sortByOptional(apps, ascending: ascending) { sizeByPath[$0.id] }
        case .lastUsed:
            return sortByOptional(apps, ascending: ascending) { lastUsedByPath[$0.id] }
        }
    }

    /// Sorts by an optional comparable value, always pushing `nil` (not-yet-computed) entries to
    /// the end regardless of `ascending`, then breaking ties by name for a stable, readable order.
    private static func sortByOptional<Value: Comparable>(
        _ apps: [InstalledApp],
        ascending: Bool,
        value: (InstalledApp) -> Value?
    ) -> [InstalledApp] {
        let (known, unknown) = apps.reduce(into: ([InstalledApp](), [InstalledApp]())) { result, app in
            if value(app) != nil { result.0.append(app) } else { result.1.append(app) }
        }
        let sortedKnown = known.sorted { lhs, rhs in
            guard let l = value(lhs), let r = value(rhs) else { return false }
            if l == r { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
            return ascending ? l < r : l > r
        }
        let sortedUnknown = unknown.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return sortedKnown + sortedUnknown
    }

    /// PLAN §3 module 5: "System/protected apps (SweepPolicy denials, Apple signed) show a lock
    /// and refuse selection." Never Sweep itself either, regardless of how it happens to be
    /// signed in a given build.
    ///
    /// `app.isAppleSigned`/`app.isSystemLocation` (`SweepUninstall`) both go stale for a macOS 26
    /// cryptex-relocated system app: `/Applications/Safari.app` is a symlink into
    /// `/System/Cryptexes/...`, so the literal, unresolved `bundlePath` never starts with
    /// `/System/`, and `SecCertificateCopySubjectSummary` came back empty for it in testing on
    /// this exact machine (found running this module's own drop-route tests against real Safari)
    /// — `isAppleSigned` is documented as a heuristic, not a trust decision, and this is exactly
    /// the kind of case it can miss. `SweepUninstall` is off-limits for this deliverable, so the
    /// fix lives here: resolve symlinks before checking for a `/System/` root, and separately
    /// treat Apple's own reserved `com.apple.` bundle-id namespace as protected outright. Both are
    /// defense in depth on top of the upstream signals, never a replacement for them.
    static func isProtected(_ app: InstalledApp, sweepBundleIdentifier: String?) -> Bool {
        if app.isAppleSigned || app.isSystemLocation { return true }
        if let sweepBundleIdentifier, !sweepBundleIdentifier.isEmpty, app.bundleIdentifier == sweepBundleIdentifier {
            return true
        }
        if let bundleIdentifier = app.bundleIdentifier, bundleIdentifier.hasPrefix("com.apple.") {
            return true
        }
        if app.bundlePath.resolvingSymlinksInPath().path.hasPrefix("/System/") {
            return true
        }
        return SweepPolicy.isDeniedLexically(app.bundlePath)
    }
}

// MARK: - Size / last-used (impure: touches the filesystem)

/// On-disk allocated size for an arbitrary file or directory tree.
///
/// This is a plain `URLResourceValues` walk (PLAN Appendix B: `totalFileAllocatedSizeKey`), not
/// `SweepCore.ScanEngine` — the Uninstaller's read-only inventory has no need for that engine's
/// hardlink/clone-family dedup machinery (that precision matters for a cleaning report's honest
/// "freed" number; it doesn't change what an app-bundle-or-leftover size readout is for here),
/// and pulling it in would mean this display-only screen depending on SweepCore for something
/// `LargeOldFilesScreen` already shows is unnecessary at this tier.
enum FileSizeCalculator {
    static func allocatedSize(at url: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return singleFileAllocatedSize(url) }

        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    private static func singleFileAllocatedSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? 0)
    }
}

/// App bundle size + last-used, computed lazily per bundle in the background (PLAN deliverable
/// 1: "size computed lazily per bundle allocated-size in background, last-used via
/// `.contentAccessDateKey` best-effort").
enum AppMetadataCalculator {
    static func allocatedSize(of app: InstalledApp) -> Int64 {
        FileSizeCalculator.allocatedSize(at: app.bundlePath)
    }

    /// Best-effort: `contentAccessDateKey` is not maintained by every filesystem/backup state,
    /// so a `nil` here means "unknown", never "never used" — the row shows nothing rather than a
    /// misleading date.
    static func lastUsedDate(of app: InstalledApp) -> Date? {
        try? app.bundlePath.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
    }
}
