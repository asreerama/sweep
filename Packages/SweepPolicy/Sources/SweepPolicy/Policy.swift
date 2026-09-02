import Foundation

/// Shared authorization policy used identically by the app and the privileged helper.
/// Deny-by-default: an operation may only touch paths under an allowlisted symbolic root,
/// and never anything matching the protected set — checked on resolved file identity,
/// not lexical paths.
///
/// ``authorize(root:resolvedPath:identity:home:)`` is the real decision API. The lexical
/// helpers below it are fast pre-filters used to prune a walk cheaply; they are never the
/// authority for a mutation.
public enum SweepPolicy {

    /// Symbolic roots an operation may be scoped to. The helper derives real paths from
    /// these (plus a validated UID / bundle id); it never accepts caller-selected
    /// absolute paths.
    public enum OperationRoot: String, Codable, CaseIterable, Sendable {
        case userCaches
        case userLogs
        case sandboxedAppCaches
        case xcodeDerivedData
        case xcodeDeviceSupport
        case developerToolCaches
        case homebrewCache
        case browserCaches
        case crashReports
        case trash
        case systemCaches      // helper-only
        case systemLogs        // helper-only
    }

    /// Grounds no operation may ever touch, regardless of tier or root.
    public enum ProtectedArea: CaseIterable, Sendable {
        case documents
        case desktop
        case pictures
        case iCloudDrive
        case cloudStorage      // ~/Library/CloudStorage + File Provider domains
        case photosLibrary
        case mailStore         // ~/Library/Mail/V*
        case sweepItself
        case systemApps
    }

    /// Resolved, identity-pinned location of a protected area for the current user.
    public static func protectedURLs(
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ProtectedArea: [URL]] {
        [
            .documents: [home.appending(path: "Documents")],
            .desktop: [home.appending(path: "Desktop")],
            .pictures: [home.appending(path: "Pictures")],
            .iCloudDrive: [home.appending(path: "Library/Mobile Documents")],
            .cloudStorage: [home.appending(path: "Library/CloudStorage")],
            .photosLibrary: [home.appending(path: "Pictures/Photos Library.photoslibrary")],
            .mailStore: [home.appending(path: "Library/Mail")],
            .sweepItself: sweepItselfURLs(),
            .systemApps: [URL(fileURLWithPath: "/System/Applications")],
        ]
    }

    /// Sweep must never clean Sweep. `Bundle.main` is the running image: the `.app` when
    /// launched normally, the test bundle under `swift test`, the executable's directory for a
    /// bare binary. All three shapes are recorded, plus the enclosing `.app` when the running
    /// bundle is nested inside one.
    public static func sweepItselfURLs(bundle: Bundle = .main) -> [URL] {
        var urls: [URL] = [bundle.bundleURL.standardizedFileURL]
        if let executable = bundle.executableURL?.standardizedFileURL {
            urls.append(executable)
        }
        // Walk out to the enclosing application bundle, if there is one.
        var candidate = bundle.bundleURL.standardizedFileURL
        for _ in 0..<6 {
            let parent = candidate.deletingLastPathComponent()
            if parent.path == candidate.path || parent.path == "/" { break }
            if parent.pathExtension == "app" {
                urls.append(parent)
                break
            }
            candidate = parent
        }
        var seen = Set<String>()
        return urls.filter { seen.insert($0.path).inserted }
    }

    /// Fast lexical pre-filter, used to prune a scan before anything is stat'd.
    ///
    /// It is deliberately *only* a pre-filter: it compares standardized pathnames and can be
    /// defeated by a symlink, a firmlink or a differently-normalized name. Nothing may mutate
    /// the filesystem on the strength of this returning `false`; that requires
    /// ``authorize(root:resolvedPath:identity:home:)``, which resolves identities.
    ///
    /// Call-site note: this convenience re-derives everything per call — the volume's comparison
    /// rule (a syscall), the protected-URL set (Bundle work), and the folded ancestors. Fine for
    /// one-off checks; a walker asking once per enumerated entry must build a ``LexicalDenyList``
    /// per walk instead — measured at ~69 µs/entry here vs ~2 µs there, which made this call 92%
    /// of a bulk walk's wall time.
    public static func isDeniedLexically(
        _ url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        LexicalDenyList(volumeOf: url, home: home).isDenied(url)
    }
}

/// The lexical denylist, prepared once for one volume's comparison rule and one home, so a
/// per-entry query is pure string work: no syscalls, no URL construction, no re-folding of the
/// ancestor set.
///
/// Correctness of the one-rule-per-walk assumption: a scan walk pins its root's volume and never
/// crosses a device boundary (`WalkOptions.boundary`), so every entry it will ever ask about lives
/// on the volume whose comparison rule was captured here. Answers are byte-for-byte identical to
/// ``SweepPolicy/isDeniedLexically(_:home:)`` — that convenience is now implemented on top of this
/// type, and `LexicalDenyListTests` asserts the equivalence over the tricky shapes (case flips,
/// decomposed Unicode, trailing slashes, prefix-but-not-child names).
public struct LexicalDenyList: Sendable {
    private let comparison: NameComparison
    /// Each protected ancestor pre-folded, stored as (exact, exact + "/") so a query is one
    /// equality plus one prefix test — mirroring `NameComparison.isAtOrUnder`'s semantics,
    /// including its trailing-slash trimming, which is applied at build time.
    private let ancestors: [(exact: String, prefix: String)]

    public init(
        volumeOf url: URL,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        let comparison = NameComparison.forVolume(containing: url)
        self.comparison = comparison
        self.ancestors = SweepPolicy.protectedURLs(home: home).values
            .flatMap { $0 }
            .compactMap { protected in
                guard !protected.path.isEmpty else { return nil }
                var folded = comparison.fold(protected.path)
                while folded.count > 1 && folded.hasSuffix("/") { folded.removeLast() }
                return (exact: folded, prefix: folded.hasSuffix("/") ? folded : folded + "/")
            }
    }

    public func isDenied(_ url: URL) -> Bool {
        isDenied(standardizedPath: url.standardizedFileURL.path)
    }

    /// The hot path: `standardizedPath` must already be a standardized filesystem path (walkers
    /// emit these), and the only per-call work is one fold of it plus the ancestor comparisons.
    public func isDenied(standardizedPath: String) -> Bool {
        let folded = comparison.fold(standardizedPath)
        for ancestor in ancestors {
            if folded == ancestor.exact || folded.hasPrefix(ancestor.prefix) { return true }
        }
        return false
    }
}
