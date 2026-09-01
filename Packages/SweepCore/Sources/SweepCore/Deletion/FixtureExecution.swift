import Darwin
import Foundation

public enum FixtureExecutionError: Error, Equatable, CustomStringConvertible {
    case rootOutsideTemporaryDirectory(path: String, temporaryDirectory: String)
    case rootIsNotADirectory(path: String)
    case cannotCreateRoot(reason: String)
    case pathOutsideFixtureRoot(path: String, fixtureRoot: String)
    case itemUnreadable(path: String, reason: String)

    public var description: String {
        switch self {
        case .rootOutsideTemporaryDirectory(let path, let temporary):
            "refused: \(path) is not under \(temporary); fixture roots are disposable by construction"
        case .rootIsNotADirectory(let path):
            "refused: \(path) is not a directory"
        case .cannotCreateRoot(let reason):
            "cannot create a fixture root: \(reason)"
        case .pathOutsideFixtureRoot(let path, let root):
            "refused: \(path) is not under the fixture root \(root)"
        case .itemUnreadable(let path, let reason):
            "cannot read \(path): \(reason)"
        }
    }
}

/// The only way to reach deletion from outside `SweepCore`.
///
/// Before this existed, `DeletionCoordinator.init` and `DeletionMode.fixtureOnly(root:)` were
/// public, so any caller could hand the coordinator `/` or `~` and hand it items that asserted
/// their own `tier: .safe`. That is a live-deletion capability with extra steps, and it walked
/// straight past both release gates (review finding #1).
///
/// Now the package owns the root. A session either creates a fresh disposable directory under
/// `NSTemporaryDirectory()`, or adopts an existing one that is *already* under it; nothing else
/// is accepted. Plans can only be built from paths inside that root, and the items are
/// constructed here from a live `lstat`, so a caller cannot assert an identity either.
///
/// This is test support. Real plans arrive in Gate 1 through the rule-authorization pipeline.
public enum FixtureExecution {

    /// Creates a fresh disposable root under `NSTemporaryDirectory()` and returns a session that
    /// owns it.
    public static func makeSession(label: String = "fixture") throws -> Session {
        let root = temporaryDirectory
            .appending(path: "SweepFixture-\(sanitized(label))-\(UUID().uuidString)", directoryHint: .isDirectory)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        } catch {
            throw FixtureExecutionError.cannotCreateRoot(reason: error.localizedDescription)
        }
        return try Session(adopting: root, ownsRoot: true)
    }

    /// Adopts a directory a test already created, refusing anything that is not under
    /// `NSTemporaryDirectory()`.
    ///
    /// The check is on the *resolved* path, so a symlink under the temporary directory pointing
    /// at the home directory is refused rather than followed.
    public static func makeSession(adopting root: URL) throws -> Session {
        try Session(adopting: root, ownsRoot: false)
    }

    /// A disposable fixture root plus the coordinator anchored to it.
    public final class Session {
        public let root: URL
        private let ownsRoot: Bool

        init(adopting root: URL, ownsRoot: Bool) throws {
            let requested = root.standardizedFileURL.path
            guard let resolved = realpathOf(requested) else {
                throw FixtureExecutionError.cannotCreateRoot(reason: "cannot resolve \(requested)")
            }
            guard let temporary = realpathOf(FixtureExecution.temporaryDirectory.path) else {
                throw FixtureExecutionError.cannotCreateRoot(reason: "cannot resolve the temporary directory")
            }
            let prefix = temporary.hasSuffix("/") ? temporary : temporary + "/"
            guard resolved.hasPrefix(prefix) else {
                throw FixtureExecutionError.rootOutsideTemporaryDirectory(
                    path: resolved,
                    temporaryDirectory: temporary
                )
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: resolved, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                throw FixtureExecutionError.rootIsNotADirectory(path: resolved)
            }

            self.root = URL(fileURLWithPath: resolved, isDirectory: true)
            self.ownsRoot = ownsRoot
        }

        deinit {
            if ownsRoot {
                try? FileManager.default.removeItem(at: root)
            }
        }

        /// A journal inside the fixture root, so nothing outside it is written either.
        public func makeJournal(named name: String = "journal.jsonl") async throws -> WALJournal {
            try await WALJournal(url: root.appending(path: name))
        }

        public func makeCoordinator(journal: WALJournal) throws -> DeletionCoordinator {
            try DeletionCoordinator(mode: .fixtureOnly(root: root), journal: journal)
        }

        /// Builds a plan from paths inside the root. Identity is read here, from the filesystem;
        /// the caller supplies only *which* paths and *what* to do with them.
        public func makePlan(
            paths: [URL],
            action: DeletionAction,
            tier: Tier,
            ruleID: String? = nil,
            operationID: UUID = UUID()
        ) throws -> DeletionPlan {
            let volume = try? VolumeIdentity.read(at: root)
            let items: [DeletionItem] = try paths.map { url in
                guard DeletionCoordinator.isStrictlyContained(url, in: root) else {
                    throw FixtureExecutionError.pathOutsideFixtureRoot(path: url.path, fixtureRoot: root.path)
                }
                let identity: FileIdentity
                let parentIdentity: FileIdentity?
                do {
                    identity = try FileIdentity.read(at: url, volume: volume)
                    parentIdentity = try FileIdentity.read(at: url.deletingLastPathComponent(), volume: volume)
                } catch {
                    throw FixtureExecutionError.itemUnreadable(
                        path: url.path,
                        reason: String(describing: error)
                    )
                }
                let allocated = (try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?
                    .totalFileAllocatedSize
                return DeletionItem(
                    url: url,
                    identity: identity,
                    parentIdentity: parentIdentity,
                    action: action,
                    tier: tier,
                    allocatedSize: Int64(allocated ?? 0),
                    ruleID: ruleID
                )
            }
            return DeletionPlan(operationID: operationID, items: items)
        }
    }

    /// The directory every fixture root must live under.
    public static var temporaryDirectory: URL {
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
    }

    private static func sanitized(_ label: String) -> String {
        let allowed = label.unicodeScalars.filter {
            CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_"
        }
        let cleaned = String(String.UnicodeScalarView(allowed))
        return cleaned.isEmpty ? "fixture" : String(cleaned.prefix(40))
    }
}
