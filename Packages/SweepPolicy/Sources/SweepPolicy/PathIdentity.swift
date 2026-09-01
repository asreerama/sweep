import Darwin
import Foundation

/// Device + inode, the only thing that actually names a file.
///
/// `SweepPolicy` deliberately keeps its own minimal identity type instead of importing
/// `SweepCore`'s richer `FileIdentity`: the dependency runs the other way, and policy only
/// ever needs to answer "is this the same object I resolved".
public struct PathIdentity: Sendable, Hashable, Codable, CustomStringConvertible {
    public let deviceID: UInt64
    public let inode: UInt64

    public init(deviceID: UInt64, inode: UInt64) {
        self.deviceID = deviceID
        self.inode = inode
    }

    init(_ status: stat) {
        self.deviceID = UInt64(bitPattern: Int64(status.st_dev))
        self.inode = UInt64(status.st_ino)
    }

    public var description: String { "dev \(deviceID)/ino \(inode)" }

    /// Identity of `url` without following a final symlink. `nil` when it cannot be stat'd.
    public static func read(at url: URL) -> PathIdentity? {
        guard let status = PathIdentity.lstat(url.path) else { return nil }
        return PathIdentity(status)
    }

    static func lstat(_ path: String) -> stat? {
        var status = stat()
        guard path.withCString({ Darwin.lstat($0, &status) }) == 0 else { return nil }
        return status
    }
}

/// Filesystem name comparison that matches how the volume itself compares names.
///
/// APFS is case-insensitive by default and normalizes Unicode, so a purely byte-wise denylist
/// is bypassable with `~/documents` or a decomposed `é`. The volume is asked which rule applies
/// rather than guessed.
public struct NameComparison: Sendable {
    public let isCaseSensitive: Bool

    public init(isCaseSensitive: Bool) {
        self.isCaseSensitive = isCaseSensitive
    }

    /// Asks the volume `url` lives on. Defaults to the safer (case-insensitive) answer when the
    /// volume will not say, because collapsing case can only ever *add* denials.
    public static func forVolume(containing url: URL) -> NameComparison {
        let sensitive = (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]))?
            .volumeSupportsCaseSensitiveNames
        return NameComparison(isCaseSensitive: sensitive ?? false)
    }

    /// Canonical form for comparison: always Unicode-precomposed, lowercased when the volume
    /// folds case.
    public func fold(_ path: String) -> String {
        let precomposed = path.precomposedStringWithCanonicalMapping
        return isCaseSensitive ? precomposed : precomposed.lowercased()
    }

    public func isSame(_ lhs: String, _ rhs: String) -> Bool {
        fold(lhs) == fold(rhs)
    }

    /// True when `path` is `ancestor` itself or sits strictly below it.
    public func isAtOrUnder(_ path: String, ancestor: String) -> Bool {
        let foldedPath = fold(path)
        var foldedAncestor = fold(ancestor)
        while foldedAncestor.count > 1 && foldedAncestor.hasSuffix("/") {
            foldedAncestor.removeLast()
        }
        if foldedPath == foldedAncestor { return true }
        let prefix = foldedAncestor.hasSuffix("/") ? foldedAncestor : foldedAncestor + "/"
        return foldedPath.hasPrefix(prefix)
    }
}

/// `realpath(3)`: fully resolves symlinks and firmlinks. Used only for *roots*, which legally
/// contain symlinks (`/var` → `/private/var`, the Data-volume firmlinks). Paths below a root
/// are validated component-wise instead, where a symlink is a refusal rather than a redirect.
func realpathOf(_ path: String) -> String? {
    guard let buffer = path.withCString({ realpath($0, nil) }) else { return nil }
    defer { free(buffer) }
    return String(cString: buffer)
}
