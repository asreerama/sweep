import Darwin
import Foundation

extension SweepPolicy {

    /// Proof that one path is inside one root a *caller* resolved from a system API, clear of
    /// every protected area, with an identity matching what the caller asserted. Mirrors
    /// ``Authorization``, minus the tie to a symbolic ``OperationRoot``.
    public struct ExternalAuthorization: Sendable, Equatable {
        /// `realpath(3)` of the caller's root: symlinks and firmlinks already collapsed.
        public let rootURL: URL
        public let rootIdentity: PathIdentity
        /// The authorized path, proven symlink-free below the root.
        public let path: URL
        public let identity: PathIdentity
        /// Identity of every directory between the root and the leaf, root-first.
        public let ancestors: [PathIdentity]
    }

    public enum ExternalRootDecision: Sendable, Equatable {
        case allowed(ExternalAuthorization)
        case denied(DenialReason)

        public var isAllowed: Bool {
            if case .allowed = self { return true }
            return false
        }

        public var authorization: ExternalAuthorization? {
            if case .allowed(let value) = self { return value }
            return nil
        }

        public var denialReason: DenialReason? {
            if case .denied(let reason) = self { return reason }
            return nil
        }
    }

    /// Authorization for a root the *caller* already resolved from a system API, rather than one
    /// of the symbolic ``OperationRoot`` cases a declarative catalog rule can name.
    ///
    /// SweepCore's code-sign-clone detector is the only caller: its root
    /// (`$DARWIN_USER_TEMP_DIR/../X`) is derived per-process via `confstr`, not a fixed catalog
    /// location. It would be wrong to add it to ``OperationRoot`` — that enum is the vocabulary
    /// of the frozen rule schema (`rules/schema.json`, owned outside this package), and no
    /// declarative rule may ever target this root: the detector's per-item "app not running" /
    /// "old enough" predicates cannot be expressed as a catalog glob at all (PLAN.md Appendix A,
    /// "Code-sign clones": "code-driven detector, not glob").
    ///
    /// Every guarantee of ``authorize(root:resolvedPath:identity:home:)`` still holds: the root
    /// is pinned to a device/inode with `realpath`, both the caller's spelling and the resolved
    /// spelling are accepted (so a symlink between `$TMPDIR` and its resolved form does not
    /// produce two different "roots"), every intermediate component between the root and the
    /// leaf is `lstat`'d and refused if it is a symlink or crosses a volume, resolved identities
    /// are checked against the protected-area denylist, and the leaf's identity must equal what
    /// the caller asserted. As with the symbolic-root path, this is a point-in-time answer about
    /// a pathname: the mutation layer must still re-walk the same chain with open file
    /// descriptors before it acts.
    public static func authorize(
        externalRoot root: URL,
        resolvedPath: URL,
        identity: PathIdentity,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> ExternalRootDecision {
        let requestedRootPath = root.standardizedFileURL.path
        guard let realRootPath = realpathOf(requestedRootPath),
              let rootIdentity = PathIdentity.read(at: URL(fileURLWithPath: realRootPath))
        else {
            // No `OperationRoot` to name here (this root is caller-resolved, not symbolic);
            // `malformedPath` carries the same meaning without inventing one.
            return .denied(.malformedPath(requestedRootPath))
        }

        let path = resolvedPath.standardizedFileURL.path
        guard path.hasPrefix("/") else { return .denied(.malformedPath(path)) }
        let pathComponents = path.split(separator: "/").map(String.init)
        let comparison = NameComparison.forVolume(containing: resolvedPath)

        for spelling in [realRootPath, requestedRootPath] {
            let rootComponents = spelling.split(separator: "/").map(String.init)
            guard pathComponents.count > rootComponents.count,
                  zip(pathComponents.prefix(rootComponents.count), rootComponents)
                    .allSatisfy({ comparison.isSame($0, $1) })
            else { continue }

            let relative = Array(pathComponents.dropFirst(rootComponents.count))
            return decideExternal(
                relativeComponents: relative,
                rootComponents: realRootPath.split(separator: "/").map(String.init),
                rootURL: URL(fileURLWithPath: realRootPath, isDirectory: true),
                rootIdentity: rootIdentity,
                assertedIdentity: identity,
                comparison: comparison,
                home: home
            )
        }
        return .denied(.outsideRequestedRoot(path: path, root: realRootPath))
    }

    private static func decideExternal(
        relativeComponents: [String],
        rootComponents: [String],
        rootURL: URL,
        rootIdentity: PathIdentity,
        assertedIdentity: PathIdentity,
        comparison: NameComparison,
        home: URL
    ) -> ExternalRootDecision {
        guard !relativeComponents.isEmpty else {
            // The root itself is a container, never a target — identical rule to the symbolic
            // path (`DenialReason.rootItself`), expressed with `outsideRequestedRoot` here since
            // that case is spelled generically (a `String`, not an `OperationRoot`).
            let rootPath = "/" + rootComponents.joined(separator: "/")
            return .denied(.outsideRequestedRoot(path: rootPath, root: rootPath))
        }

        let fullComponents = rootComponents + relativeComponents
        let fullPath = "/" + fullComponents.joined(separator: "/")
        var ancestors: [PathIdentity] = [rootIdentity]
        var leaf: PathIdentity?

        for index in rootComponents.count..<fullComponents.count {
            let prefixPath = "/" + fullComponents[0...index].joined(separator: "/")
            guard let status = PathIdentity.lstat(prefixPath) else {
                return .denied(.unreadable(path: prefixPath, code: errno))
            }
            let isLeaf = index == fullComponents.count - 1
            let componentIdentity = PathIdentity(status)

            if !isLeaf {
                guard status.st_mode & S_IFMT == S_IFDIR else {
                    return .denied(.symlinkComponent(path: fullPath, component: fullComponents[index]))
                }
                guard componentIdentity.deviceID == rootIdentity.deviceID else {
                    return .denied(.volumeBoundary(path: fullPath, component: fullComponents[index]))
                }
                ancestors.append(componentIdentity)
            } else {
                leaf = componentIdentity
            }
        }

        guard let leaf else { return .denied(.malformedPath(fullPath)) }

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

        return .allowed(ExternalAuthorization(
            rootURL: rootURL,
            rootIdentity: rootIdentity,
            path: URL(fileURLWithPath: fullPath),
            identity: leaf,
            ancestors: ancestors
        ))
    }
}
