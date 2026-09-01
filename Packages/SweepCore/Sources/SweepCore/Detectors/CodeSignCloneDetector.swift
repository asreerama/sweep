import Darwin
import Foundation

/// Finds stale `.code_sign_clone` directories under `<DARWIN_USER_TEMP_DIR>/../X` (PLAN.md §3
/// System Junk, Appendix A "Code-sign clones").
///
/// Read-only, like every other feature-package producer (PLAN.md §2 "Safety layer"): this type
/// only detects. Deletion of anything it finds goes through ``DeletionCoordinator`` like any
/// other candidate, once wrapped back into a plan.
///
/// Current user only in v1 (PLAN.md §3): `X` is resolved from *this process's* Darwin user
/// temp directory, so clones left by other accounts are out of scope until the P4 helper can
/// read them with elevated privilege.
public struct CodeSignCloneDetector: Sendable {

    /// Suffix macOS appends to a bundle id when it clones the app bundle into `X`.
    public static let cloneSuffix = ".code_sign_clone"
    /// Appendix A: "require age > 10 minutes (directory mtime)".
    public static let defaultMinimumAge: TimeInterval = 10 * 60

    public enum DetectorError: Error, Equatable, CustomStringConvertible {
        case darwinUserTempDirUnavailable(status: Int32)

        public var description: String {
            switch self {
            case .darwinUserTempDirUnavailable(let status):
                "confstr(_CS_DARWIN_USER_TEMP_DIR) returned no usable path (status \(status))"
            }
        }
    }

    /// Whether the app owning `bundleIdentifier` is currently running. Injected so this package
    /// never links AppKit directly to answer that question; see the `canImport(AppKit)`
    /// extension below for the default a real caller gets for free.
    private let isRunning: @Sendable (String) -> Bool
    private let now: @Sendable () -> Date
    private let minimumAge: TimeInterval

    public init(
        isRunning: @escaping @Sendable (String) -> Bool,
        now: @escaping @Sendable () -> Date = Date.init,
        minimumAge: TimeInterval = CodeSignCloneDetector.defaultMinimumAge
    ) {
        self.isRunning = isRunning
        self.now = now
        self.minimumAge = minimumAge
    }

    /// Resolves the real `X` directory and scans it. The only entry point a production caller
    /// uses.
    public func scan() throws -> [CodeSignCloneCandidate] {
        try scan(directory: Self.resolveCloneDirectory())
    }

    /// Scans an arbitrary directory shaped like the real `X`. Package-visible so tests exercise
    /// the full suffix/age/running logic against a disposable fixture tree without the
    /// production path ever accepting a caller-supplied directory (PLAN.md §2: producers derive
    /// their roots, they do not take one from a caller).
    func scan(directory: URL) throws -> [CodeSignCloneCandidate] {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return []
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        let cutoff = now().addingTimeInterval(-minimumAge)
        var candidates: [CodeSignCloneCandidate] = []

        for entry in entries {
            guard let bundleIdentifier = Self.bundleIdentifier(forCloneNamed: entry.lastPathComponent) else {
                continue
            }
            guard let identity = try? FileIdentity.read(at: entry), identity.kind == .directory else {
                continue
            }
            guard identity.modification.date < cutoff else { continue }
            guard !isRunning(bundleIdentifier) else { continue }

            let parentIdentity = try? FileIdentity.read(at: directory)
            let scanCandidate = ScanCandidate(
                url: entry,
                identity: identity,
                parentIdentity: parentIdentity,
                allocatedSize: Self.apparentAllocatedSize(of: entry),
                contentAccessDate: nil,
                ruleID: nil
            )
            candidates.append(CodeSignCloneCandidate(candidate: scanCandidate, bundleIdentifier: bundleIdentifier))
        }

        return candidates
    }

    /// Strips ``cloneSuffix`` from a directory name, `nil` when the name is not a clone (does
    /// not carry the suffix, or is nothing but the suffix).
    static func bundleIdentifier(forCloneNamed name: String) -> String? {
        guard name.hasSuffix(cloneSuffix) else { return nil }
        let bundleIdentifier = String(name.dropLast(cloneSuffix.count))
        return bundleIdentifier.isEmpty ? nil : bundleIdentifier
    }

    /// Recursive sum of `totalFileAllocatedSize` across every file in the clone, falling back to
    /// `FileIdentity.allocatedSize(of:)` (`st_blocks * 512`) exactly the way
    /// ``FileManagerVolumeWalker`` does when the resource value is unavailable. Deliberately not
    /// deduplicated by inode against anything outside this one clone: see
    /// ``CodeSignCloneCandidate/sizeIsCoWApparent``.
    static func apparentAllocatedSize(of root: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
            options: [],
            errorHandler: nil
        ) else {
            return 0
        }

        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let status = try? FileIdentity.lstatPath(url), FileIdentity.kind(of: status) == .file else {
                continue
            }
            let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
            total += values?.totalFileAllocatedSize.map(Int64.init) ?? FileIdentity.allocatedSize(of: status)
        }
        return total
    }

    /// `<DARWIN_USER_TEMP_DIR>/../X`. `confstr` reports `.../<h1>/<h2>/T/`; `X` is `T`'s
    /// sibling under `<h2>`.
    static func resolveCloneDirectory() throws -> URL {
        let bufferSize = confstr(_CS_DARWIN_USER_TEMP_DIR, nil, 0)
        guard bufferSize > 0 else {
            throw DetectorError.darwinUserTempDirUnavailable(status: errno)
        }
        var buffer = [Int8](repeating: 0, count: bufferSize)
        let written = confstr(_CS_DARWIN_USER_TEMP_DIR, &buffer, buffer.count)
        guard written > 0, written <= buffer.count else {
            throw DetectorError.darwinUserTempDirUnavailable(status: errno)
        }
        let path = buffer.withUnsafeBufferPointer { pointer -> String in
            String(cString: pointer.baseAddress!)
        }
        let temporaryDirectory = URL(fileURLWithPath: path, isDirectory: true)
        return temporaryDirectory.standardizedFileURL
            .deletingLastPathComponent()
            .appendingPathComponent("X", isDirectory: true)
    }
}

#if canImport(AppKit)
import AppKit

extension CodeSignCloneDetector {
    /// The default a real caller gets for free: running state answered by
    /// `NSRunningApplication`, kept out of the primary initializer so nothing that only wants
    /// the closure-injected form pays for linking AppKit.
    public static func appKitIsRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }

    /// Convenience matching the primary initializer, with ``appKitIsRunning`` as the running
    /// check.
    public init(
        now: @escaping @Sendable () -> Date = Date.init,
        minimumAge: TimeInterval = CodeSignCloneDetector.defaultMinimumAge
    ) {
        self.init(isRunning: CodeSignCloneDetector.appKitIsRunning, now: now, minimumAge: minimumAge)
    }
}
#endif
