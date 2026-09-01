import Darwin
import Foundation

extension SweepPolicy {

    /// A symbolic ``SweepPolicy/OperationRoot`` resolved to a real, existing, identity-pinned
    /// directory. Roots come from system APIs and the current user's home; a caller never
    /// supplies one.
    public struct ResolvedRoot: Sendable, Equatable {
        public let root: OperationRoot
        /// `realpath(3)` of the root: symlinks and firmlinks already collapsed.
        public let url: URL
        /// The spelling the system API produced, before resolution — `/var/…` where `url` says
        /// `/private/var/…`. A caller's path is accepted under either spelling and then rewritten
        /// onto `url`, so exactly two known-good routes into the root exist and no others.
        public let requestedURL: URL
        public let identity: PathIdentity

        public init(root: OperationRoot, url: URL, requestedURL: URL, identity: PathIdentity) {
            self.root = root
            self.url = url
            self.requestedURL = requestedURL
            self.identity = identity
        }
    }

    /// Proof that one specific path, with one specific identity, is inside one specific
    /// operation root and clear of every protected area. Only ``authorize(root:resolvedPath:identity:home:)``
    /// can make one, so it cannot be forged by a caller that merely wants a deletion to happen.
    public struct Authorization: Sendable, Equatable {
        public let root: ResolvedRoot
        /// The authorized path, proven symlink-free below the root.
        public let path: URL
        /// Identity of the leaf, confirmed to match what the caller asserted.
        public let identity: PathIdentity
        /// Identity of every directory between the root and the leaf, root-first. The mutation
        /// layer re-walks this chain with file descriptors; policy only proves it existed.
        public let ancestors: [PathIdentity]
    }

    public enum DenialReason: Sendable, Equatable, CustomStringConvertible {
        /// The path is not absolute, or has no usable components.
        case malformedPath(String)
        /// The symbolic root does not resolve to anything on this machine.
        case rootUnavailable(OperationRoot)
        /// The path is the operation root itself. Roots are containers, never targets.
        case rootItself(OperationRoot)
        /// Deny-by-default: nothing outside the requested root is ever authorized.
        case outsideRequestedRoot(path: String, root: String)
        /// A directory between the root and the leaf is a symlink. Refused, never followed.
        case symlinkComponent(path: String, component: String)
        /// A component between the root and the leaf sits on another volume.
        case volumeBoundary(path: String, component: String)
        /// The path, or one of its ancestors, resolves into a protected area.
        case protectedArea(ProtectedArea, path: String)
        /// The path exists but is not the object the caller described.
        case identityMismatch(path: String, expected: PathIdentity, found: PathIdentity)
        case unreadable(path: String, code: Int32)

        public var description: String {
            switch self {
            case .malformedPath(let path):
                "refused: \(path) is not an absolute path"
            case .rootUnavailable(let root):
                "refused: operation root \(root.rawValue) does not resolve on this system"
            case .rootItself(let root):
                "refused: the operation root \(root.rawValue) itself is not a target"
            case .outsideRequestedRoot(let path, let root):
                "refused: \(path) is not under the authorized root \(root)"
            case .symlinkComponent(let path, let component):
                "refused: \(path) descends through the symlink \(component)"
            case .volumeBoundary(let path, let component):
                "refused: \(path) crosses a volume boundary at \(component)"
            case .protectedArea(let area, let path):
                "refused: \(path) resolves into the protected area \(area)"
            case .identityMismatch(let path, let expected, let found):
                "refused: \(path) is \(found), not the \(expected) that was authorized"
            case .unreadable(let path, let code):
                "refused: cannot stat \(path): \(String(cString: strerror(code))) (\(code))"
            }
        }
    }

    public enum Decision: Sendable, Equatable {
        case allowed(Authorization)
        case denied(DenialReason)

        public var isAllowed: Bool {
            if case .allowed = self { return true }
            return false
        }

        public var authorization: Authorization? {
            if case .allowed(let value) = self { return value }
            return nil
        }

        public var denialReason: DenialReason? {
            if case .denied(let reason) = self { return reason }
            return nil
        }
    }

    // MARK: - Root resolution

    /// Real locations a symbolic root can name, before existence filtering. Every entry is
    /// derived from `FileManager`/the current home; none is caller-supplied.
    static func candidateRootURLs(for root: OperationRoot, home: URL) -> [URL] {
        let library = home.appending(path: "Library")
        switch root {
        case .userCaches:
            let system = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
            return system.isEmpty ? [library.appending(path: "Caches")] : system
        case .userLogs:
            return [library.appending(path: "Logs")]
        case .sandboxedAppCaches:
            return [library.appending(path: "Containers")]
        case .xcodeDerivedData:
            return [library.appending(path: "Developer/Xcode/DerivedData")]
        case .xcodeDeviceSupport:
            return [
                library.appending(path: "Developer/Xcode/iOS DeviceSupport"),
                library.appending(path: "Developer/Xcode/watchOS DeviceSupport"),
                library.appending(path: "Developer/Xcode/tvOS DeviceSupport"),
            ]
        case .developerToolCaches:
            // The catalog's developer-group patterns are home-relative (`.npm/_cacache/*`,
            // `.gradle/caches/*`, `Library/Application Support/Code/Cache/*`, ...), so `home`
            // itself must be a candidate root — without it 15 of the 24 developer rules could
            // never match anything (P4-B finding, 2026-09-01). Widening to `home` is bounded by
            // the same layers that bound every root: rules are byte-pinned fixed relative globs
            // (no `..`, no leading `/`), deny-wins exclusions, and `authorize()` still refuses
            // every protected area (Documents, Desktop, CloudStorage, Mail, ...) on resolved
            // identity regardless of root. SwiftPM *configuration* and security state in
            // `~/.swiftpm` stay unreachable: no rule targets them (review finding #13) and the
            // pattern vocabulary cannot escape its glob.
            return [
                home,
                library.appending(path: "Caches/org.swift.swiftpm"),
                library.appending(path: "Developer/CoreSimulator/Caches"),
                home.appending(path: ".cache/org.swift.swiftpm"),
            ]
        case .homebrewCache:
            return [
                library.appending(path: "Caches/Homebrew"),
                URL(fileURLWithPath: "/Library/Caches/Homebrew"),
            ]
        case .browserCaches:
            return [
                library.appending(path: "Caches/com.apple.Safari"),
                library.appending(path: "Caches/Google/Chrome"),
                library.appending(path: "Caches/Firefox"),
                library.appending(path: "Containers/com.apple.Safari/Data/Library/Caches"),
            ]
        case .crashReports:
            return [library.appending(path: "Logs/DiagnosticReports")]
        case .trash:
            return [home.appending(path: ".Trash")]
        case .systemCaches:
            return [URL(fileURLWithPath: "/Library/Caches")]
        case .systemLogs:
            return [
                URL(fileURLWithPath: "/Library/Logs"),
                URL(fileURLWithPath: "/var/log"),
            ]
        }
    }

    /// The subset of ``candidateRootURLs(for:home:)`` that exists right now, each collapsed with
    /// `realpath(3)` and pinned to the device/inode it resolved to.
    public static func resolvedRoots(
        for root: OperationRoot,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [ResolvedRoot] {
        var seen = Set<String>()
        var results: [ResolvedRoot] = []
        for candidate in candidateRootURLs(for: root, home: home) {
            guard let real = realpathOf(candidate.path) else { continue }
            guard let identity = PathIdentity.read(at: URL(fileURLWithPath: real)) else { continue }
            guard seen.insert(real).inserted else { continue }
            results.append(ResolvedRoot(
                root: root,
                url: URL(fileURLWithPath: real),
                requestedURL: candidate.standardizedFileURL,
                identity: identity
            ))
        }
        return results
    }

    // MARK: - The decision

    /// Operation-scoped authorization. Deny-by-default in every direction:
    ///
    /// 1. The symbolic root is resolved from system APIs and pinned to a device/inode.
    /// 2. `resolvedPath` must sit strictly under one of those real roots, compared the way the
    ///    volume compares names (case-folded and Unicode-precomposed on a case-insensitive volume).
    /// 3. Every directory between root and leaf is `lstat`'d: a symlink is a refusal, not a
    ///    redirect, and a device change is a refusal.
    /// 4. The protected-area denylist is applied to the *resolved identities* of the leaf and
    ///    every ancestor, so a firmlink, an alias or a re-cased name cannot smuggle a path in.
    /// 5. The leaf's identity must equal the identity the caller asserted.
    ///
    /// This is a point-in-time answer about a pathname. It is necessary, not sufficient: the
    /// mutation layer must still re-walk the same chain with open file descriptors, because a
    /// pathname can be re-pointed between this call and the syscall that acts on it.
    public static func authorize(
        root: OperationRoot,
        resolvedPath: URL,
        identity: PathIdentity,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Decision {
        let path = resolvedPath.standardizedFileURL.path
        guard path.hasPrefix("/") else { return .denied(.malformedPath(path)) }
        let pathComponents = path.split(separator: "/").map(String.init)
        guard !pathComponents.isEmpty else { return .denied(.malformedPath(path)) }

        let roots = resolvedRoots(for: root, home: home)
        guard !roots.isEmpty else { return .denied(.rootUnavailable(root)) }

        let comparison = NameComparison.forVolume(containing: resolvedPath)
        var sawRootItself = false

        for resolved in roots {
            let spellings = [resolved.url.path, resolved.requestedURL.path]
            for spelling in spellings {
                let rootComponents = spelling.split(separator: "/").map(String.init)
                guard pathComponents.count >= rootComponents.count else { continue }
                let prefix = Array(pathComponents.prefix(rootComponents.count))
                guard zip(prefix, rootComponents).allSatisfy({ comparison.isSame($0, $1) }) else { continue }
                if pathComponents.count == rootComponents.count {
                    sawRootItself = true
                    continue
                }
                // Rebuild on the *resolved* root, so the descent below never re-crosses the
                // symlink or firmlink that separated the two spellings.
                return decide(
                    relativeComponents: Array(pathComponents.dropFirst(rootComponents.count)),
                    resolvedRoot: resolved,
                    assertedIdentity: identity,
                    comparison: comparison,
                    home: home
                )
            }
        }

        if sawRootItself { return .denied(.rootItself(root)) }
        return .denied(.outsideRequestedRoot(path: path, root: roots.map(\.url.path).joined(separator: ", ")))
    }

    private static func decide(
        relativeComponents: [String],
        resolvedRoot: ResolvedRoot,
        assertedIdentity: PathIdentity,
        comparison: NameComparison,
        home: URL
    ) -> Decision {
        let rootComponents = resolvedRoot.url.path.split(separator: "/").map(String.init)
        let pathComponents = rootComponents + relativeComponents
        let rootComponentCount = rootComponents.count
        let fullPath = "/" + pathComponents.joined(separator: "/")
        var ancestors: [PathIdentity] = [resolvedRoot.identity]
        var leaf: PathIdentity?

        // Component-wise descent. Every intermediate component must be a real directory on the
        // root's volume; a symlink anywhere in the chain ends the walk.
        for index in rootComponentCount..<pathComponents.count {
            let prefixPath = "/" + pathComponents[0...index].joined(separator: "/")
            guard let status = PathIdentity.lstat(prefixPath) else {
                return .denied(.unreadable(path: prefixPath, code: errno))
            }
            let isLeaf = index == pathComponents.count - 1
            let identity = PathIdentity(status)

            if !isLeaf {
                if status.st_mode & S_IFMT == S_IFLNK {
                    return .denied(.symlinkComponent(path: fullPath, component: pathComponents[index]))
                }
                guard status.st_mode & S_IFMT == S_IFDIR else {
                    return .denied(.symlinkComponent(path: fullPath, component: pathComponents[index]))
                }
                guard identity.deviceID == resolvedRoot.identity.deviceID else {
                    return .denied(.volumeBoundary(path: fullPath, component: pathComponents[index]))
                }
                ancestors.append(identity)
            } else {
                leaf = identity
            }
        }

        guard let leaf else { return .denied(.malformedPath(fullPath)) }

        // Protected areas, checked against resolved identities as well as resolved pathnames.
        if let violation = protectedAreaViolation(
            path: fullPath,
            identities: ancestors + [leaf],
            comparison: comparison,
            home: home
        ) {
            return .denied(.protectedArea(violation, path: fullPath))
        }

        guard leaf == assertedIdentity else {
            return .denied(.identityMismatch(path: fullPath, expected: assertedIdentity, found: leaf))
        }

        return .allowed(Authorization(
            root: resolvedRoot,
            path: URL(fileURLWithPath: fullPath),
            identity: leaf,
            ancestors: ancestors
        ))
    }

    /// Denylist check on resolved identities *and* resolved pathnames. Either hit is a refusal:
    /// the identity check catches firmlinks and aliases, the pathname check catches a protected
    /// area that does not exist yet and therefore has no identity to compare.
    static func protectedAreaViolation(
        path: String,
        identities: [PathIdentity],
        comparison: NameComparison,
        home: URL
    ) -> ProtectedArea? {
        let identitySet = Set(identities)
        for (area, urls) in protectedURLs(home: home) {
            for protected in urls where !protected.path.isEmpty {
                guard let real = realpathOf(protected.path) else {
                    // Not present on this machine: fall back to the lexical form so a protected
                    // area that has not been created yet still cannot be created-and-cleaned.
                    if comparison.isAtOrUnder(path, ancestor: protected.standardizedFileURL.path) {
                        return area
                    }
                    continue
                }
                if comparison.isAtOrUnder(path, ancestor: real) { return area }
                if let identity = PathIdentity.read(at: URL(fileURLWithPath: real)),
                   identitySet.contains(identity) {
                    return area
                }
            }
        }
        return nil
    }
}
