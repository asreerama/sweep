import Foundation

/// A read-only finding. Feature packages produce these and never touch `FileManager` for
/// writes; only ``DeletionCoordinator`` consumes them for mutation.
public struct ScanCandidate: Sendable, Hashable, Codable, Identifiable {
    public let url: URL
    public let identity: FileIdentity
    public let parentIdentity: FileIdentity?
    /// On-disk bytes for this path. For a hard-linked inode this is the full size of the
    /// inode, which is why aggregation deduplicates by inode instead of summing candidates.
    public let allocatedSize: Int64
    public let contentAccessDate: Date?
    /// Rule that claimed this path, when the scan was rule-driven.
    public let ruleID: String?

    public var id: String { "\(identity.deviceID):\(identity.inode):\(url.path)" }

    public init(
        url: URL,
        identity: FileIdentity,
        parentIdentity: FileIdentity? = nil,
        allocatedSize: Int64,
        contentAccessDate: Date? = nil,
        ruleID: String? = nil
    ) {
        self.url = url
        self.identity = identity
        self.parentIdentity = parentIdentity
        self.allocatedSize = allocatedSize
        self.contentAccessDate = contentAccessDate
        self.ruleID = ruleID
    }

    init(entry: WalkEntry, ruleID: String?) {
        self.init(
            url: entry.url,
            identity: entry.identity,
            parentIdentity: entry.parentIdentity,
            allocatedSize: entry.allocatedSize,
            contentAccessDate: entry.contentAccessDate,
            ruleID: ruleID
        )
    }
}

/// Running totals for a scan. Bytes count regular files only, each inode once: APFS clones
/// and hard links otherwise inflate a total by an arbitrary factor.
public struct ScanTotals: Sendable, Hashable, Codable {
    public var fileCount: Int = 0
    public var directoryCount: Int = 0
    public var otherCount: Int = 0
    /// Paths whose inode was already counted (hard links).
    public var duplicateInodeCount: Int = 0
    public var allocatedBytes: Int64 = 0

    public var itemCount: Int { fileCount + directoryCount + otherCount }

    public init() {}
}

public struct ScanProgress: Sendable, Hashable {
    public let itemsSeen: Int
    public let allocatedBytes: Int64
    public let currentPath: String?
}

public struct ScanSummary: Sendable {
    public let scanID: UUID
    public let totals: ScanTotals
    public let issues: [WalkIssue]
    public let duration: TimeInterval
    public let cancelled: Bool
}

/// Full result including candidates. Streaming consumers should read ``ScanEvent`` instead of
/// materializing this for very large trees.
public struct ScanResult: Sendable {
    public let summary: ScanSummary
    public let candidates: [ScanCandidate]

    public var totals: ScanTotals { summary.totals }
    public var allocatedBytes: Int64 { summary.totals.allocatedBytes }
}

public enum ScanEvent: Sendable {
    case started(scanID: UUID, root: URL)
    case candidate(ScanCandidate)
    case progress(ScanProgress)
    case finished(ScanSummary)
}

/// What the scan looks at. Roots are absolute URLs the caller already resolved from a
/// ``SweepPolicy/OperationRoot``; the scan engine does no path guessing of its own.
public struct ScanRequest: Sendable {
    public var roots: [URL]
    public var maximumDepth: Int?
    public var includesDirectories: Bool
    public var honorsPolicyDenylist: Bool
    /// Emit only items whose modification time is at least this old.
    public var minimumAge: TimeInterval?
    /// Stamped onto every candidate, for rule-driven scans.
    public var ruleID: String?
    /// Items between progress events. Progress is throttled; candidates are not.
    public var progressInterval: Int

    public init(
        roots: [URL],
        maximumDepth: Int? = nil,
        includesDirectories: Bool = true,
        honorsPolicyDenylist: Bool = true,
        minimumAge: TimeInterval? = nil,
        ruleID: String? = nil,
        progressInterval: Int = 256
    ) {
        self.roots = roots
        self.maximumDepth = maximumDepth
        self.includesDirectories = includesDirectories
        self.honorsPolicyDenylist = honorsPolicyDenylist
        self.minimumAge = minimumAge
        self.ruleID = ruleID
        self.progressInterval = progressInterval
    }
}

public enum ScanError: Error, CustomStringConvertible {
    case noRoots
    case rootUnavailable(URL, String)

    public var description: String {
        switch self {
        case .noRoots: "scan request has no roots"
        case .rootUnavailable(let url, let reason): "scan root unavailable: \(url.path) (\(reason))"
        }
    }
}
