import Darwin
import Foundation

/// Minimal identity of a filesystem entry obtained via `lstat` — i.e. facts about the entry
/// itself, never a trailing symlink it points at. Used to detect a symlink without ever
/// resolving it, and to let a caller pin a search root's device number so a walk can also catch
/// a mount point substituted inside the tree (the same device-crossing signal, without needing
/// an explicit symlink).
///
/// See finding #10 in the adversarial review: `FileManager.fileExists(atPath:isDirectory:)`
/// (used previously by `RootWalker` and `AppInventory`) follows symlinks — it is `stat`
/// semantics, not `lstat` — which let a symlinked directory be silently treated as real content
/// of a search root and recursed into.
struct EntryIdentity: Equatable {
    let device: dev_t
    let inode: ino_t
    let isSymbolicLink: Bool
    let isDirectory: Bool
}

enum FileIdentityReader {
    /// `lstat`s `url`'s path — never follows a trailing symlink. Returns `nil` if the path does
    /// not exist or cannot be statted (broken symlink, permission denied, or a benign race where
    /// the entry vanished between listing its parent directory and getting here); every caller
    /// treats that identically to "skip it", never guesses.
    static func lstatIdentity(at url: URL) -> EntryIdentity? {
        var info = stat()
        let result = url.path.withCString { lstat($0, &info) }
        guard result == 0 else { return nil }
        let fileType = info.st_mode & S_IFMT
        return EntryIdentity(
            device: info.st_dev,
            inode: info.st_ino,
            isSymbolicLink: fileType == S_IFLNK,
            isDirectory: fileType == S_IFDIR
        )
    }
}
