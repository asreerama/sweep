import Darwin
import Foundation
import SweepPolicy

/// One item seen by a walk, with everything the scan engine needs to build a candidate.
public struct WalkEntry: Sendable {
    public let url: URL
    public let identity: FileIdentity
    public let parentIdentity: FileIdentity?
    /// On-disk bytes (`totalFileAllocatedSizeKey`, or `st_blocks * 512` when unavailable).
    public let allocatedSize: Int64
    public let contentAccessDate: Date?
    /// Depth below the walk root; the root's immediate children are at 1.
    public let depth: Int
}

/// What the walk should do after visiting an entry.
public enum WalkDirective: Sendable {
    case `continue`
    case skipDescendants
    case stop
}

/// A problem encountered mid-walk. Walks never fail wholesale on a per-item error; they
/// record it and keep going, because one unreadable directory must not lose an entire scan.
public struct WalkIssue: Sendable, Equatable {
    public enum Reason: Sendable, Equatable {
        case unreadable(String)
        case identityUnavailable(String)
        case volumeBoundary
        case policyDenied
    }

    public let url: URL
    public let reason: Reason
}

public struct WalkOptions: Sendable {
    /// Never crossed. Entries on another device are skipped, never descended into.
    public var boundary: VolumeIdentity
    /// Deepest level below the root to visit; `nil` = unlimited.
    public var maximumDepth: Int?
    /// Skip anything ``SweepPolicy/isDeniedLexically(_:)`` refuses, before it is even stat'd
    /// deeply. Producers stay read-only, but scanning a protected area is pointless work and
    /// can materialize cloud placeholders.
    public var honorsPolicyDenylist: Bool
    public var includesDirectories: Bool

    public init(
        boundary: VolumeIdentity,
        maximumDepth: Int? = nil,
        honorsPolicyDenylist: Bool = true,
        includesDirectories: Bool = true
    ) {
        self.boundary = boundary
        self.maximumDepth = maximumDepth
        self.honorsPolicyDenylist = honorsPolicyDenylist
        self.includesDirectories = includesDirectories
    }
}

public struct WalkSummary: Sendable {
    public let issues: [WalkIssue]
    public let stopped: Bool
}

/// Swappable enumeration backend.
///
/// v1 ships the `FileManager.enumerator` implementation Appendix B calls acceptable. The
/// `fts_read` backend (`FTS_PHYSICAL | FTS_XDEV`) lands behind this same protocol later; the
/// scan engine must not learn which one it has.
public protocol VolumeWalker: Sendable {
    /// Synchronous by contract: the scan engine runs it on a dedicated thread, off the
    /// cooperative pool, because directory enumeration blocks.
    func walk(root: URL, options: WalkOptions, visit: (WalkEntry) -> WalkDirective) throws -> WalkSummary
}

public enum WalkError: Error, Equatable, CustomStringConvertible {
    case rootUnreadable(URL, String)
    case rootNotADirectory(URL)
    case rootOnDifferentVolume(URL)

    public var description: String {
        switch self {
        case .rootUnreadable(let url, let reason): "cannot enumerate \(url.path): \(reason)"
        case .rootNotADirectory(let url): "walk root is not a directory: \(url.path)"
        case .rootOnDifferentVolume(let url): "walk root is not on the pinned volume: \(url.path)"
        }
    }
}

/// `FileManager.enumerator` backend with the resource keys prefetched in one batch.
public struct FileManagerVolumeWalker: VolumeWalker {

    /// Prefetched in a single `getattrlistbulk` batch per directory by Foundation. Keeping the
    /// set fixed keeps the per-entry cost predictable.
    public static let prefetchedKeys: [URLResourceKey] = [
        .totalFileAllocatedSizeKey,
        .isDirectoryKey,
        .contentAccessDateKey,
        .fileResourceIdentifierKey,
        .volumeIdentifierKey,
    ]

    public init() {}

    public func walk(root: URL, options: WalkOptions, visit: (WalkEntry) -> WalkDirective) throws -> WalkSummary {
        let rootIdentity = try FileIdentity.read(at: root, volume: options.boundary)
        guard rootIdentity.kind == .directory else { throw WalkError.rootNotADirectory(root) }
        guard rootIdentity.deviceID == options.boundary.deviceID else {
            throw WalkError.rootOnDifferentVolume(root)
        }

        let collector = WalkIssueCollector()
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Self.prefetchedKeys,
            options: [],
            errorHandler: { url, error in
                collector.record(WalkIssue(url: url, reason: .unreadable(error.localizedDescription)))
                return true
            }
        ) else {
            throw WalkError.rootUnreadable(root, "enumerator unavailable")
        }

        // Pre-order traversal, so a directory is always seen before its children and this
        // cache is warm by the time a child needs its parent's identity.
        var identityByPath: [String: FileIdentity] = [root.standardizedFileURL.path: rootIdentity]
        var stopped = false

        while let url = enumerator.nextObject() as? URL {
            let depth = enumerator.level

            if options.honorsPolicyDenylist, SweepPolicy.isDeniedLexically(url) {
                collector.record(WalkIssue(url: url, reason: .policyDenied))
                enumerator.skipDescendants()
                continue
            }

            let status: stat
            do {
                status = try FileIdentity.lstatPath(url)
            } catch {
                collector.record(WalkIssue(url: url, reason: .identityUnavailable(String(describing: error))))
                enumerator.skipDescendants()
                continue
            }

            let deviceID = UInt64(bitPattern: Int64(status.st_dev))
            guard deviceID == options.boundary.deviceID else {
                // Mandatory `FTS_XDEV` equivalent: nested mounts are a different volume with
                // a different policy, never part of this walk.
                collector.record(WalkIssue(url: url, reason: .volumeBoundary))
                enumerator.skipDescendants()
                continue
            }

            let kind = FileIdentity.kind(of: status)
            let identity = FileIdentity(
                deviceID: deviceID,
                inode: UInt64(status.st_ino),
                volume: options.boundary,
                kind: kind,
                linkCount: Int(status.st_nlink),
                modification: FileTimestamp(status.st_mtimespec)
            )

            let standardized = url.standardizedFileURL.path
            if kind == .directory { identityByPath[standardized] = identity }
            let parentIdentity = identityByPath[url.deletingLastPathComponent().standardizedFileURL.path]

            let values = try? url.resourceValues(forKeys: Set(Self.prefetchedKeys))
            let allocated: Int64 = if kind == .symbolicLink {
                FileIdentity.allocatedSize(of: status)
            } else {
                values?.totalFileAllocatedSize.map(Int64.init) ?? FileIdentity.allocatedSize(of: status)
            }

            let overDepth = options.maximumDepth.map { depth > $0 } ?? false
            if overDepth {
                enumerator.skipDescendants()
                continue
            }

            let emit = options.includesDirectories || kind != .directory
            var directive = WalkDirective.continue
            if emit {
                directive = visit(WalkEntry(
                    url: url,
                    identity: identity,
                    parentIdentity: parentIdentity,
                    allocatedSize: allocated,
                    contentAccessDate: values?.contentAccessDate,
                    depth: depth
                ))
            }

            switch directive {
            case .continue:
                continue
            case .skipDescendants:
                enumerator.skipDescendants()
            case .stop:
                stopped = true
            }
            if stopped { break }
        }

        return WalkSummary(issues: collector.drain(), stopped: stopped)
    }
}

/// The enumerator's error handler is escaping and may be called from Foundation's own
/// context, so issue collection is lock-guarded.
final class WalkIssueCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var issues: [WalkIssue] = []

    func record(_ issue: WalkIssue) {
        lock.lock()
        defer { lock.unlock() }
        issues.append(issue)
    }

    func drain() -> [WalkIssue] {
        lock.lock()
        defer { lock.unlock() }
        let current = issues
        issues = []
        return current
    }
}
