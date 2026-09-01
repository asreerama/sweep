import Darwin
import Foundation
import SweepPolicy

/// Filesystem timestamp kept at `stat` precision. `Date` round-trips lose nanoseconds, and
/// identity revalidation compares timestamps for equality, so the raw pair is stored.
public struct FileTimestamp: Sendable, Hashable, Codable, Comparable {
    public let seconds: Int64
    public let nanoseconds: Int64

    public init(seconds: Int64, nanoseconds: Int64) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    init(_ spec: timespec) {
        self.seconds = Int64(spec.tv_sec)
        self.nanoseconds = Int64(spec.tv_nsec)
    }

    public static let zero = FileTimestamp(seconds: 0, nanoseconds: 0)

    public var date: Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }

    public static func < (lhs: FileTimestamp, rhs: FileTimestamp) -> Bool {
        (lhs.seconds, lhs.nanoseconds) < (rhs.seconds, rhs.nanoseconds)
    }
}

/// What a path is, taken from `lstat` (symlinks are never followed).
public enum FileKind: String, Sendable, Codable, CaseIterable {
    case file
    case directory
    case symbolicLink
    case other
}

/// Pins a volume so a walk can refuse to cross it and a delete can refuse a moved item.
/// `deviceID` is the authority; `uuid` is recorded for logs and for cross-mount reasoning.
public struct VolumeIdentity: Sendable, Hashable, Codable {
    public let deviceID: UInt64
    public let uuid: String?

    public init(deviceID: UInt64, uuid: String?) {
        self.deviceID = deviceID
        self.uuid = uuid
    }

    public func isSameVolume(as other: VolumeIdentity) -> Bool {
        deviceID == other.deviceID
    }

    /// Volume identity of the filesystem `url` lives on.
    public static func read(at url: URL) throws -> VolumeIdentity {
        let status = try FileIdentity.lstatPath(url)
        let uuid = try? url.resourceValues(forKeys: [.volumeUUIDStringKey]).volumeUUIDString
        return VolumeIdentity(deviceID: UInt64(bitPattern: Int64(status.st_dev)), uuid: uuid)
    }
}

/// Identity of one filesystem item, captured at scan time and revalidated at delete time.
///
/// Path strings are not identity: symlinks, case-insensitive lookups, Unicode normalization
/// and firmlinks all make two different paths the same file, and a rename makes the same path
/// a different file. Device + inode is the identity; the timestamp and link count detect
/// mutation of that identity between scan and delete.
public struct FileIdentity: Sendable, Hashable, Codable {
    public let deviceID: UInt64
    public let inode: UInt64
    public let volume: VolumeIdentity
    public let kind: FileKind
    public let linkCount: Int
    public let modification: FileTimestamp
    /// `st_ctimespec`. Unlike mtime, no API lets a process set it backwards: an in-place rewrite
    /// followed by `utimes` to restore mtime still moves ctime forward (review finding #5).
    public let statusChange: FileTimestamp
    /// `st_size`. Catches a same-length-preserving edit only in combination with the timestamps,
    /// but catches truncation and growth on its own.
    public let size: Int64
    /// `st_flags` — `uchg`, `schg`, `hidden`, `compressed`. A file that gained or lost an
    /// immutability flag since the scan is not the file the plan described.
    public let flags: UInt32
    /// `st_uid`. Not part of ``isSameFile(as:)``/``isUnchanged(from:)`` (ownership is a
    /// different axis than "is this the same, untouched object"); captured purely so the
    /// rule-authorization pipeline can require a candidate be owned by the account running Sweep
    /// before it authorizes anything against it (review finding #9's "verifies owner UID").
    public let ownerUserID: UInt32

    public init(
        deviceID: UInt64,
        inode: UInt64,
        volume: VolumeIdentity,
        kind: FileKind,
        linkCount: Int,
        modification: FileTimestamp,
        statusChange: FileTimestamp = .zero,
        size: Int64 = 0,
        flags: UInt32 = 0,
        ownerUserID: UInt32 = UInt32(getuid())
    ) {
        self.deviceID = deviceID
        self.inode = inode
        self.volume = volume
        self.kind = kind
        self.linkCount = linkCount
        self.modification = modification
        self.statusChange = statusChange
        self.size = size
        self.flags = flags
        self.ownerUserID = ownerUserID
    }

    /// Built straight from a `stat` taken with a symlink-free call (`lstat`, or `fstatat` with
    /// `AT_SYMLINK_NOFOLLOW`). The single place the struct is filled in from the kernel.
    init(_ status: stat, volume: VolumeIdentity? = nil) {
        let deviceID = UInt64(bitPattern: Int64(status.st_dev))
        self.init(
            deviceID: deviceID,
            inode: UInt64(status.st_ino),
            volume: volume ?? VolumeIdentity(deviceID: deviceID, uuid: nil),
            kind: FileIdentity.kind(of: status),
            linkCount: Int(status.st_nlink),
            modification: FileTimestamp(status.st_mtimespec),
            statusChange: FileTimestamp(status.st_ctimespec),
            size: Int64(status.st_size),
            flags: status.st_flags,
            ownerUserID: status.st_uid
        )
    }

    /// Same inode on the same device, same type. True across renames.
    public func isSameFile(as other: FileIdentity) -> Bool {
        deviceID == other.deviceID && inode == other.inode && kind == other.kind
    }

    /// Same file *and* untouched. mtime alone is forgeable (`utimes` sets it to anything), so
    /// ctime, size, link count and flags are all part of the comparison. For a directory this
    /// still only proves the directory's own entry list is unchanged, which is why a directory
    /// deletion validates every descendant separately instead of trusting this.
    public func isUnchanged(from other: FileIdentity) -> Bool {
        isSameFile(as: other)
            && modification == other.modification
            && statusChange == other.statusChange
            && size == other.size
            && linkCount == other.linkCount
            && flags == other.flags
    }

    /// ``isUnchanged(from:)`` plus ownership. Ownership is deliberately excluded from
    /// `isUnchanged` (see its doc comment) because most callers only care "is this the same,
    /// untouched object" independent of who owns it. Codex Gate-1 findings #6/#7 need a stricter
    /// question at two specific points — ``CleanService``'s live re-verification of a
    /// ``SelectionReceipt`` between review and execution, and code-sign-clone authorization's
    /// live re-read — where a same-inode object whose owner silently changed between the
    /// reviewed scan and the clean request must never be waved through on identity alone.
    public func isFullyIdentical(to other: FileIdentity) -> Bool {
        isUnchanged(from: other) && ownerUserID == other.ownerUserID
    }

    /// The device/inode pair, in the vocabulary ``SweepPolicy`` speaks.
    public var pathIdentity: PathIdentity {
        PathIdentity(deviceID: deviceID, inode: inode)
    }

    /// True when a regular file has more than one directory entry pointing at it, so its bytes
    /// must be counted once per inode, not once per path. Directories are excluded: their link
    /// count is always at least 2 (`.` plus the parent's entry) and says nothing about sharing.
    public var isHardLinked: Bool { kind == .file && linkCount > 1 }

    /// Capture identity of `url` without following a final symlink.
    ///
    /// Pathname-based, so it is only ever a *capture* or a fail-fast pre-check. The authority
    /// for a mutation is ``OpenDirectory``'s `fstatat` against a descriptor that was opened with
    /// `O_NOFOLLOW`, because a pathname can be re-pointed between this call and the next one.
    public static func read(at url: URL, volume: VolumeIdentity? = nil) throws -> FileIdentity {
        FileIdentity(try lstatPath(url), volume: volume)
    }

    // Explicit coding so a journal written before ctime/size/flags existed still replays: the
    // three new fields decode to their zero value rather than failing the whole record.
    private enum CodingKeys: String, CodingKey {
        case deviceID, inode, volume, kind, linkCount, modification, statusChange, size, flags, ownerUserID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.deviceID = try container.decode(UInt64.self, forKey: .deviceID)
        self.inode = try container.decode(UInt64.self, forKey: .inode)
        self.volume = try container.decode(VolumeIdentity.self, forKey: .volume)
        self.kind = try container.decode(FileKind.self, forKey: .kind)
        self.linkCount = try container.decode(Int.self, forKey: .linkCount)
        self.modification = try container.decode(FileTimestamp.self, forKey: .modification)
        self.statusChange = try container.decodeIfPresent(FileTimestamp.self, forKey: .statusChange) ?? .zero
        self.size = try container.decodeIfPresent(Int64.self, forKey: .size) ?? 0
        self.flags = try container.decodeIfPresent(UInt32.self, forKey: .flags) ?? 0
        // A journal written before this field existed carries no ownership evidence at all: the
        // sentinel is deliberately never a real uid, so an authorization check against a replayed
        // pre-existing record fails closed instead of guessing the current user owned it.
        self.ownerUserID = try container.decodeIfPresent(UInt32.self, forKey: .ownerUserID) ?? .max
    }

    /// Bytes actually occupied on disk, from `st_blocks`. Used as the fallback when the URL
    /// resource value is unavailable (and for symlinks, where the resource value resolves).
    static func allocatedSize(of status: stat) -> Int64 {
        Int64(status.st_blocks) * 512
    }

    static func kind(of status: stat) -> FileKind {
        switch status.st_mode & S_IFMT {
        case S_IFREG: .file
        case S_IFDIR: .directory
        case S_IFLNK: .symbolicLink
        default: .other
        }
    }

    static func lstatPath(_ url: URL) throws -> stat {
        let path = url.withUnsafeFileSystemRepresentation { pointer -> String? in
            pointer.map { String(cString: $0) }
        }
        guard let path else {
            throw FileIdentityError.unrepresentablePath(url)
        }
        var status = stat()
        guard lstat(path, &status) == 0 else {
            throw FileIdentityError.statFailed(url: url, code: errno)
        }
        return status
    }
}

public enum FileIdentityError: Error, Equatable, CustomStringConvertible {
    case unrepresentablePath(URL)
    case statFailed(url: URL, code: Int32)

    /// Distinguishes "it disappeared" from "we were refused" from "the filesystem broke",
    /// which the journal and the UI must report differently.
    public var isNotFound: Bool {
        if case .statFailed(_, let code) = self { return code == ENOENT || code == ENOTDIR }
        return false
    }

    public var isPermissionDenied: Bool {
        if case .statFailed(_, let code) = self { return code == EACCES || code == EPERM }
        return false
    }

    public var description: String {
        switch self {
        case .unrepresentablePath(let url):
            "path is not representable on this filesystem: \(url)"
        case .statFailed(let url, let code):
            "lstat(\(url.path)) failed: \(String(cString: strerror(code))) (\(code))"
        }
    }
}
