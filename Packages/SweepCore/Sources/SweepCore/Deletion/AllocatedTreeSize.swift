import Darwin
import Foundation

/// Allocated on-disk bytes of one file or tree, for report honesty (Codex Gate-U re-review
/// finding #6: every uninstall item was reported as zero bytes). Physical walk (`FTS_PHYSICAL` —
/// symlinks sized as themselves, never followed), each inode counted once, `st_blocks` × 512 per
/// POSIX. Missing or unreadable entries contribute zero: a size readout must never turn into an
/// authorization signal or a failure.
enum AllocatedTreeSize {
    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    static func bytes(atPath path: String) -> Int64 {
        var argv: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
        defer { free(argv[0]) }
        guard let stream = fts_open(&argv, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return 0 }
        defer { fts_close(stream) }

        var total: Int64 = 0
        var seen = Set<InodeKey>()
        while let entry = fts_read(stream) {
            let info = Int32(entry.pointee.fts_info)
            guard info == FTS_F || info == FTS_SL || info == FTS_SLNONE || info == FTS_DEFAULT || info == FTS_D,
                  let status = entry.pointee.fts_statp?.pointee else { continue }
            let key = InodeKey(device: UInt64(bitPattern: Int64(status.st_dev)), inode: status.st_ino)
            guard seen.insert(key).inserted else { continue }
            total += Int64(status.st_blocks) * 512
        }
        return total
    }
}
