import Foundation

/// A macOS application discovered on disk via its bundle `Info.plist`.
///
/// Read-only fact record. `AppInventory` never writes, moves, or deletes anything — it only
/// reads `Info.plist` and (cheaply) the embedded code signature.
public struct InstalledApp: Sendable, Hashable, Identifiable {
    public var id: String { bundlePath.path }

    /// `CFBundleIdentifier`. Nil for the rare malformed bundle; such apps can still be
    /// listed but can never be bundle-id-matched by `LeftoverMatcher`.
    public let bundleIdentifier: String?
    /// Display name: `CFBundleDisplayName`, then `CFBundleName`, then the bundle's own
    /// filename stem.
    public let name: String
    /// `CFBundleShortVersionString`, when present.
    public let shortVersion: String?
    /// `CFBundleVersion`, when present.
    public let buildVersion: String?
    /// Absolute, standardized location of the `.app` bundle.
    public let bundlePath: URL
    /// Code-signing team identifier, read cheaply (no full signature validation).
    public let teamIdentifier: String?
    /// Code-signing identifier string (`kSecCodeInfoIdentifier`), read cheaply.
    public let signingIdentifier: String?
    /// Heuristic only (see `SigningInfo.isAppleSigned`) — not a trust decision.
    public let isAppleSigned: Bool
    /// True when the bundle lives under a known Apple system location
    /// (`/System/...`). Combined with `isAppleSigned`, a useful signal for "never offer to
    /// uninstall this" policy layers built on top of this package.
    public let isSystemLocation: Bool

    public init(
        bundleIdentifier: String?,
        name: String,
        shortVersion: String?,
        buildVersion: String?,
        bundlePath: URL,
        teamIdentifier: String?,
        signingIdentifier: String?,
        isAppleSigned: Bool,
        isSystemLocation: Bool
    ) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.shortVersion = shortVersion
        self.buildVersion = buildVersion
        self.bundlePath = bundlePath
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
        self.isAppleSigned = isAppleSigned
        self.isSystemLocation = isSystemLocation
    }
}

/// Enumerates installed applications. Strictly read-only: `FileManager.contentsOfDirectory`
/// and `Info.plist` reads only, never a write/remove/trash call.
public enum AppInventory {
    /// `/Applications` and `~/Applications`, the two conventional install roots.
    public static func defaultApplicationsDirectories(fileManager: FileManager = .default) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    /// Scans `directories` plus exactly one level of subdirectories (e.g.
    /// `/Applications/Utilities`, a vendor folder like `/Applications/JetBrains Toolbox`) for
    /// `.app` bundles, and reads each one's `Info.plist` plus cheap signing info.
    ///
    /// Depth-limited by construction: a `.app` bundle is never descended into, and a plain
    /// subdirectory is only ever expanded one level past the roots given.
    public static func scan(
        directories: [URL] = AppInventory.defaultApplicationsDirectories(),
        fileManager: FileManager = .default
    ) -> [InstalledApp] {
        var bundleURLs: [URL] = []
        var seenPaths = Set<String>()
        for directory in directories {
            collectAppBundles(in: directory, remainingDepth: 1, fileManager: fileManager, into: &bundleURLs, seenPaths: &seenPaths)
        }
        return bundleURLs.compactMap { readAppInfo(at: $0) }
    }

    private static func collectAppBundles(
        in directory: URL,
        remainingDepth: Int,
        fileManager: FileManager,
        into result: inout [URL],
        seenPaths: inout Set<String>
    ) {
        // Deliberately NOT `.skipsHiddenFiles`: on macOS 26, cryptex-relocated system apps
        // (Safari confirmed on this machine) are dot-less symlinks carrying the BSD `hidden`
        // flag (`stat` reports `restricted,hidden`) — `.skipsHiddenFiles` drops them from
        // enumeration entirely. This is almost certainly the mechanism behind Pearcleaner
        // issue #533 ("Applications/Utilities apps not listed", PLAN.md §0). Dotfile noise
        // (`.DS_Store`, `.localized`) is filtered explicitly below by name instead, which
        // does not touch dot-less-but-hidden-flagged entries like `Safari.app`.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        for entry in entries {
            guard !entry.lastPathComponent.hasPrefix(".") else { continue }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory) else { continue }

            if entry.pathExtension == "app" {
                let standardized = entry.standardizedFileURL.path
                if seenPaths.insert(standardized).inserted {
                    result.append(entry.standardizedFileURL)
                }
                continue // never descend into a bundle
            }

            guard isDirectory.boolValue, remainingDepth > 0 else { continue }
            collectAppBundles(in: entry, remainingDepth: remainingDepth - 1, fileManager: fileManager, into: &result, seenPaths: &seenPaths)
        }
    }

    private static func readAppInfo(at bundleURL: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: bundleURL), let infoDictionary = bundle.infoDictionary else { return nil }

        let name = (infoDictionary["CFBundleDisplayName"] as? String)
            ?? (infoDictionary["CFBundleName"] as? String)
            ?? NameNormalization.stem(of: bundleURL)

        let signing = SigningInfoReader.read(at: bundleURL)
        let isSystemLocation = bundleURL.path.hasPrefix("/System/")

        return InstalledApp(
            bundleIdentifier: bundle.bundleIdentifier,
            name: name,
            shortVersion: infoDictionary["CFBundleShortVersionString"] as? String,
            buildVersion: infoDictionary["CFBundleVersion"] as? String,
            bundlePath: bundleURL,
            teamIdentifier: signing?.teamIdentifier,
            signingIdentifier: signing?.signingIdentifier,
            isAppleSigned: signing?.isAppleSigned ?? false,
            isSystemLocation: isSystemLocation
        )
    }
}
