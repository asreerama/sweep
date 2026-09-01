import Darwin
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

/// Result of ``AppInventory/scanReportingCompleteness(directories:fileManager:)`` — the apps
/// found, plus whether the scan is trustworthy as a complete picture of what is installed.
public struct AppInventoryScan: Sendable {
    public let apps: [InstalledApp]
    /// `false` when at least one applications root that DOES exist could not be fully
    /// enumerated — permission denied, an unexpected symlink/non-directory sitting where a real
    /// directory should be, or a subdirectory whose contents could not be listed. A root that
    /// simply does not exist (most machines have no `~/Applications` at all) does not count
    /// against this: there is nothing hidden behind a directory that was never there.
    ///
    /// Codex Gate-U finding #1: an incomplete scan can never prove a leftover has no sibling
    /// consumer — some other installed app might live exactly inside the directory this scan
    /// could not read — so Gate U treats `isComplete == false` as a reason to cap every leftover's
    /// evidence at manual review, never to promote anything.
    public let isComplete: Bool

    public init(apps: [InstalledApp], isComplete: Bool) {
        self.apps = apps
        self.isComplete = isComplete
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
    ///
    /// Thin wrapper over ``scanReportingCompleteness(directories:fileManager:)`` for callers that
    /// only ever wanted the app list (every call site before Codex Gate-U finding #1). New callers
    /// that need to know whether the scan actually saw everywhere it was supposed to look should
    /// call that instead.
    public static func scan(
        directories: [URL] = AppInventory.defaultApplicationsDirectories(),
        fileManager: FileManager = .default
    ) -> [InstalledApp] {
        scanReportingCompleteness(directories: directories, fileManager: fileManager).apps
    }

    /// Same scan as ``scan(directories:fileManager:)``, plus a completeness signal (Codex Gate-U
    /// finding #1): whether every root this scan was asked to look at was actually readable.
    public static func scanReportingCompleteness(
        directories: [URL] = AppInventory.defaultApplicationsDirectories(),
        fileManager: FileManager = .default
    ) -> AppInventoryScan {
        var bundleURLs: [URL] = []
        var seenPaths = Set<String>()
        var isComplete = true
        for directory in directories {
            // A root that simply does not exist is not incomplete — there is nothing behind it to
            // miss. Only a root that exists but fails the "real, non-symlink directory" check
            // (finding #10) or cannot be enumerated counts against completeness.
            guard pathExists(directory) else { continue }
            guard let rootIdentity = FileIdentityReader.lstatIdentity(at: directory),
                  rootIdentity.isDirectory, !rootIdentity.isSymbolicLink
            else {
                isComplete = false
                continue
            }
            collectAppBundles(
                in: directory, remainingDepth: 1, rootDevice: rootIdentity.device, fileManager: fileManager,
                into: &bundleURLs, seenPaths: &seenPaths, isComplete: &isComplete
            )
        }

        // Codex Gate-U finding A (second re-check loop): a `compactMap` here would silently drop
        // any `.app` directory this scan found but could not fully turn into an `InstalledApp` —
        // an unreadable/missing `Info.plist`, most commonly — while leaving `isComplete == true`.
        // That is exactly the same hole as an unreadable root: some other installed app could be
        // sitting at that exact path, and this scan would have no way to prove otherwise. Every
        // entry `collectAppBundles` handed back is either fully resolved into the result, or it
        // flips `isComplete`; none is ever quietly skipped.
        var apps: [InstalledApp] = []
        apps.reserveCapacity(bundleURLs.count)
        for bundleURL in bundleURLs {
            guard let app = readAppInfo(at: bundleURL) else {
                isComplete = false
                continue
            }
            if app.bundleIdentifier == nil {
                // Still listed (existing contract — `InstalledApp.bundleIdentifier`'s own doc
                // comment: "such apps can still be listed"), but a bundle with no readable
                // `CFBundleIdentifier` can never be exact-bundle-id matched by `LeftoverMatcher`,
                // so it is invisible to the one ambiguous-ownership check that matters most for
                // Gate U's "no sibling consumer exists" proof. The scan cannot claim completeness
                // while it contains an app it could not fully identify.
                isComplete = false
            }
            apps.append(app)
        }
        return AppInventoryScan(apps: apps, isComplete: isComplete)
    }

    /// Plain `lstat` existence check — never follows a trailing symlink, consistent with every
    /// other identity read in this file. Used only to tell "this root was never there" (fine, not
    /// incomplete) apart from "this root exists but something is wrong with it" (incomplete).
    private static func pathExists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } == 0
    }

    private static func collectAppBundles(
        in directory: URL,
        remainingDepth: Int,
        rootDevice: dev_t,
        fileManager: FileManager,
        into result: inout [URL],
        seenPaths: inout Set<String>,
        isComplete: inout Bool
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
        ) else {
            // Codex Gate-U finding #1: a directory that exists but could not be listed (permission
            // denied, or it vanished in the instant between the caller's own check and this one)
            // might be hiding a sibling app this scan can never now see.
            isComplete = false
            return
        }

        for entry in entries {
            guard !entry.lastPathComponent.hasPrefix(".") else { continue }

            // The `.app` check is a pure extension test — deliberately made *before* the identity
            // read below, so an existing `.app`-named entry whose identity cannot be read is never
            // mistaken for "genuinely non-app noise" and quietly skipped (Codex Gate-U finding A,
            // second re-check loop).
            let isAppShaped = entry.pathExtension == "app"

            // `lstat`, never `stat`/`fileExists` (finding #10): reports the entry itself, never
            // follows a trailing symlink. A symlink FILE always reports its own containing
            // directory's device via `lstat` regardless of what it points to, so this does not
            // reject the legitimate macOS 26 case (a dot-less `.app`-extension symlink into a
            // cryptex mount) — it only rejects a REAL directory substituted by a different-device
            // mount, or a device mismatch that should never occur for an ordinary symlink/file.
            guard let identity = FileIdentityReader.lstatIdentity(at: entry), identity.device == rootDevice else {
                if isAppShaped {
                    // Finding A: this scan cannot vouch that no other installed app lives at this
                    // exact `.app` path — it cannot even read what is sitting there — so it must
                    // never silently claim completeness the way skipping unreadable noise does.
                    isComplete = false
                }
                continue
            }

            if isAppShaped {
                // Terminal regardless of symlink status: macOS 26 legitimately relocates some
                // system apps (Safari confirmed on this machine) to a dot-less symlink pointing
                // into a cryptex mount, and `Bundle(url:)` in `readAppInfo` below correctly
                // resolves that. Never descend further either way.
                let standardized = entry.standardizedFileURL.path
                if seenPaths.insert(standardized).inserted {
                    result.append(entry.standardizedFileURL)
                }
                continue // never descend into a bundle
            }

            // Never recurse through a symlinked subdirectory: it could point anywhere on disk,
            // and recursing into it would misattribute unrelated `.app` bundles found there as
            // installed at this (spoofed) location — finding #10 in the adversarial review.
            guard identity.isDirectory, !identity.isSymbolicLink, remainingDepth > 0 else { continue }
            collectAppBundles(
                in: entry, remainingDepth: remainingDepth - 1, rootDevice: rootDevice, fileManager: fileManager,
                into: &result, seenPaths: &seenPaths, isComplete: &isComplete
            )
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
