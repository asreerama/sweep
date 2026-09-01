import Darwin
import Foundation

/// One item found while walking a search root.
struct RootEntry: Sendable, Hashable {
    let url: URL
    /// The piece compared against bundle ids / names. For a file, its extension is stripped
    /// (`com.example.foo.plist` → `com.example.foo`); a directory's name is used verbatim,
    /// since a dot in a directory name is not an "extension" to remove — stripping it would
    /// mangle a real directory like `Application Support/MyApp.Config` into `MyApp`. This
    /// mirrors Pearcleaner's own file/directory distinction in `AppPathFinder`.
    let baseName: String
    let isDirectory: Bool
}

/// Depth-limited directory listing used by both the ownership matcher and orphan detector.
/// Never follows symlinks: every entry's type comes from `lstat` (never `stat`/`fileExists`),
/// and recursion never descends through a symlinked directory or across a device boundary from
/// the search root's own device — pinned once, at the start of the walk, and re-checked for
/// every entry at every depth.
///
/// See finding #10 in the adversarial review: the previous `fileExists(atPath:isDirectory:)` +
/// `contentsOfDirectory` recursion followed symlinks, so a symlinked directory planted under
/// e.g. `~/Library/Caches` could make an exact-bundle-id-named folder physically located
/// anywhere else on disk (e.g. `~/Documents`) surface as "found under Caches" — and therefore
/// auto-selectable — leftover evidence.
enum RootWalker {
    static func entries(in root: SearchRoot, homeDirectory: URL, systemLaunchDaemonsDirectory: URL, fileManager: FileManager) -> [RootEntry] {
        guard root != .pkgReceipt else { return [] }
        let rootURL = root.url(homeDirectory: homeDirectory, systemLaunchDaemonsDirectory: systemLaunchDaemonsDirectory)

        // The root itself must be a real (non-symlink) directory — if it doesn't exist, isn't a
        // directory, or is itself unexpectedly a symlink, there is nothing safe to pin a device
        // identity to or walk.
        guard let rootIdentity = FileIdentityReader.lstatIdentity(at: rootURL),
              rootIdentity.isDirectory, !rootIdentity.isSymbolicLink else {
            return []
        }

        return walk(rootURL, remainingDepth: root.extraDepth, rootDevice: rootIdentity.device, fileManager: fileManager)
    }

    private static func walk(_ directory: URL, remainingDepth: Int, rootDevice: dev_t, fileManager: FileManager) -> [RootEntry] {
        // See the matching note in AppInventory.swift: `.skipsHiddenFiles` drops BSD
        // hidden-flagged entries (confirmed for macOS 26 cryptex-relocated system apps), not
        // just dotfiles. Dotfile noise is filtered explicitly by name below instead.
        guard let items = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return [] }

        var result: [RootEntry] = []
        for item in items {
            guard !item.lastPathComponent.hasPrefix(".") else { continue }

            // `lstat`, never `stat`/`fileExists`: reports the entry itself, never follows a
            // trailing symlink. A device mismatch (e.g. a volume mounted inside the tree) is
            // treated exactly like an escape attempt — skipped outright, matched or not.
            guard let identity = FileIdentityReader.lstatIdentity(at: item), identity.device == rootDevice else { continue }

            let isDirectory = identity.isDirectory
            let baseName = isDirectory ? item.lastPathComponent : NameNormalization.stem(of: item)
            result.append(RootEntry(url: item, baseName: baseName, isDirectory: isDirectory))

            // Never recurse through a symlink, even one pointing at a real directory on this
            // same device: descending into it would attribute whatever lives at the OTHER end
            // of the link to this root — exactly the escape finding #10 describes.
            if isDirectory, !identity.isSymbolicLink, remainingDepth > 0 {
                result.append(contentsOf: walk(item, remainingDepth: remainingDepth - 1, rootDevice: rootDevice, fileManager: fileManager))
            }
        }
        return result
    }
}
