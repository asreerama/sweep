import Darwin
import Foundation

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

    public init(
        deviceID: UInt64,
        inode: UInt64,
        volume: VolumeIdentity,
        kind: FileKind,
        linkCount: Int,
        modification: FileTimestamp
    ) {
        self.deviceID = deviceID
        self.inode = inode
        self.volume = volume
        self.kind = kind
        self.linkCount = linkCount
        self.modification = modification
    }

    /// Same inode on the same device, same type. True across renames.
    public func isSameFile(as other: FileIdentity) -> Bool {
        deviceID == other.deviceID && inode == other.inode && kind == other.kind
    }

    /// Same file *and* untouched: mtime and link count both unchanged. Anything else is a
    /// refusal at delete time.
    public func isUnchanged(from other: FileIdentity) -> Bool {
        isSameFile(as: other) && modification == other.modification && linkCount == other.linkCount
    }

    /// True when a regular file has more than one directory entry pointing at it, so its bytes
    /// must be counted once per inode, not once per path. Directories are excluded: their link
    /// count is always at least 2 (`.` plus the parent's entry) and says nothing about sharing.
    public var isHardLinked: Bool { kind == .file && linkCount > 1 }

    /// Capture identity of `url` without following a final symlink.
    public static func read(at url: URL, volume: VolumeIdentity? = nil) throws -> FileIdentity {
        let status = try lstatPath(url)
        let deviceID = UInt64(bitPattern: Int64(status.st_dev))
        return FileIdentity(
            deviceID: deviceID,
            inode: UInt64(status.st_ino),
            volume: volume ?? VolumeIdentity(deviceID: deviceID, uuid: nil),
            kind: kind(of: status),
            linkCount: Int(status.st_nlink),
            modification: FileTimestamp(status.st_mtimespec)
        )
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
