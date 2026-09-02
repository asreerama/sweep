import Darwin
import Foundation
import SweepPolicy

/// Pre-trash deep validation of a staged directory tree (Codex Gate-U finding #2): a directory
/// is trashed whole by one atomic rename, so everything inside it at that moment rides along.
/// The shallow identity checks cover the directory's own metadata; this walk covers its
/// contents — refusing a mount surfaced inside the tree (foreign device) and any object whose
/// device+inode matches a protected area's own directory (someone relocating ~/Documents or the
/// Photos library INSIDE a reviewed leftover directory after review must abort the trash).
///
/// Runs against the STAGED tree — already renamed into this operation's exclusive quarantine
/// slot — because that is the object that will actually be trashed; a walk of the live path
/// before staging would race the rename it is trying to protect.
enum DeepTreeValidator {
    /// Protected-area identities, read once per process: the areas themselves are fixed for the
    /// lifetime of a login session, and `lstat` on ~12 well-known paths is not worth repeating
    /// per item. An area that does not exist on this machine simply contributes nothing.
    private static let protectedIdentities: [UInt64: Set<UInt64>] = {
        var byDevice: [UInt64: Set<UInt64>] = [:]
        for urls in SweepPolicy.protectedURLs().values {
            for url in urls {
                var status = stat()
                guard lstat(url.path, &status) == 0 else { continue }
                byDevice[UInt64(bitPattern: Int64(status.st_dev)), default: []].insert(status.st_ino)
            }
        }
        return byDevice
    }()

    /// Production entry point: the process-wide protected set.
    static func firstViolation(inTreeAt path: String, expectedDevice: UInt64) -> String? {
        firstViolation(inTreeAt: path, expectedDevice: expectedDevice, protectedIdentities: protectedIdentities)
    }

    /// Walks the whole tree at `path` (physically — symlinks are entries, never followed) and
    /// returns a human-readable description of the first violation, or nil when the tree is
    /// clean. `expectedDevice` is the staged directory's own device: every entry must match it.
    /// The identity set is injectable so a test can mark one of its own fixture inodes protected
    /// without touching the real user's Documents.
    static func firstViolation(
        inTreeAt path: String, expectedDevice: UInt64, protectedIdentities: [UInt64: Set<UInt64>]
    ) -> String? {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(argv[0]) }
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else {
            return "the staged tree could not be opened for validation"
        }
        defer { fts_close(stream) }

        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            // Directories are visited pre-order (FTS_D) and post-order (FTS_DP); checking
            // pre-order only keeps each object checked exactly once. FTS_F/FTS_SL/FTS_DEFAULT
            // cover files, symlinks and everything else with a stat.
            guard info == FTS_D || info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT,
                  let status = entry.pointee.fts_statp?.pointee else {
                if info == FTS_DNR || info == FTS_ERR || info == FTS_NS {
                    let failedPath = String(cString: entry.pointee.fts_path)
                    return "an entry could not be read during validation: \(failedPath)"
                }
                continue
            }
            let device = UInt64(bitPattern: Int64(status.st_dev))
            if device != expectedDevice {
                let entryPath = String(cString: entry.pointee.fts_path)
                return "contains an entry on a different volume (a mount point): \(entryPath)"
            }
            if protectedIdentities[device]?.contains(status.st_ino) == true {
                let entryPath = String(cString: entry.pointee.fts_path)
                return "contains a protected location moved inside it since review: \(entryPath)"
            }
        }
        return nil
    }
}
