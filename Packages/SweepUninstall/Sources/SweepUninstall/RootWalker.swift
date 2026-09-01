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
/// Never follows symlinks into unrelated trees implicitly (`FileManager.contentsOfDirectory`
/// lists the link itself, does not traverse through it), never writes, never deletes.
enum RootWalker {
    static func entries(in root: SearchRoot, homeDirectory: URL, systemLaunchDaemonsDirectory: URL, fileManager: FileManager) -> [RootEntry] {
        guard root != .pkgReceipt else { return [] }
        let rootURL = root.url(homeDirectory: homeDirectory, systemLaunchDaemonsDirectory: systemLaunchDaemonsDirectory)
        return walk(rootURL, remainingDepth: root.extraDepth, fileManager: fileManager)
    }

    private static func walk(_ directory: URL, remainingDepth: Int, fileManager: FileManager) -> [RootEntry] {
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
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: item.path, isDirectory: &isDirectory) else { continue }
            let baseName = isDirectory.boolValue ? item.lastPathComponent : NameNormalization.stem(of: item)
            result.append(RootEntry(url: item, baseName: baseName, isDirectory: isDirectory.boolValue))

            if isDirectory.boolValue, remainingDepth > 0 {
                result.append(contentsOf: walk(item, remainingDepth: remainingDepth - 1, fileManager: fileManager))
            }
        }
        return result
    }
}
