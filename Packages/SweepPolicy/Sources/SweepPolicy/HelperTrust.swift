import Foundation

/// Pure trust decisions for `SweepHelper`'s XPC listener. Both functions here are deliberately
/// free of `Security`/`SystemConfiguration` system calls — those live in `SweepHelper` itself
/// (`ConsoleUser.currentConsoleUID()`, `SecRequirementCreateWithString`) — so the actual *decision*
/// logic is testable as a normal user, without root and without a real signing identity, per the
/// task spec: "must also build+test its validation logic as a normal-user unit test."
public enum HelperTrust {
    public enum TrustError: Error, Sendable, Equatable, CustomStringConvertible {
        case malformedLeafHash(String)
        /// Codex finding #1 ("caller identity is certificate-wide"): a `certificate leaf`-only
        /// requirement is satisfied by *any* binary this machine's signing cert has ever signed,
        /// not just Sweep.app. `designatedRequirement` refuses to build a requirement string
        /// around an app identifier that is empty or unsafe to embed in the requirement-language
        /// double-quoted literal, rather than silently degrading to a weaker check.
        case malformedAppIdentifier(String)

        public var description: String {
            switch self {
            case .malformedLeafHash(let hash):
                "refused: \"\(hash)\" is not a SHA-1 leaf certificate hash"
            case .malformedAppIdentifier(let identifier):
                "refused: \"\(identifier)\" is not a valid app bundle identifier for a designated requirement"
            }
        }
    }

    /// `codesign -d -r-` prints a signing cert's leaf fingerprint as 40 lowercase hex digits
    /// (`certificate leaf = H"<hash>"` — verified against this machine's own signing identity
    /// while building `scripts/build-app.sh`). Anything else — empty, wrong length, non-hex —
    /// means the build script's extraction failed or the checked-in dev placeholder
    /// (`GeneratedHelperTrust`) was never overwritten, and the helper must refuse to start rather
    /// than build a designated-requirement string around it.
    public static func isValidLeafHash(_ hash: String) -> Bool {
        hash.count == 40 && hash.allSatisfy(\.isHexDigit)
    }

    /// A reverse-DNS bundle identifier is the only thing that ever needs to sit inside the
    /// requirement language's `identifier "..."` double-quoted literal here, so the accepted
    /// charset is deliberately narrow: letters, digits, `.`, `-`, `_`. Anything else — a quote, a
    /// backslash, whitespace, an empty string — could either break out of the literal or signal
    /// the checked-in dev placeholder was never overwritten by `scripts/build-app.sh`.
    public static func isValidAppIdentifier(_ identifier: String) -> Bool {
        guard !identifier.isEmpty else { return false }
        return identifier.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
    }

    /// The exact designated-requirement language `SecRequirementCreateWithString` needs (Apple's
    /// Code Signing Requirement Language). Binds *two* independent properties of the caller:
    ///
    ///   - `identifier "\(appIdentifier)"` — the connecting process must be Sweep.app itself
    ///     (`HelperIdentity.appBundleIdentifier`), not merely something this machine's signing
    ///     cert happens to have also signed. This is the fix for Codex finding #1
    ///     ("caller identity is certificate-wide"): `scripts/build-app.sh`'s local dev cert signs
    ///     more than one tool on this machine, so `certificate leaf = H"…"` alone is satisfied by
    ///     any of them.
    ///   - `certificate leaf = H"\(leafHash)"` — signed with this exact certificate, which is what
    ///     lets the requirement keep trusting Sweep.app across a rebuild that changes nothing but
    ///     the binary (no `anchor` clause: a self-signed local identity has no trusted anchor to
    ///     bind to; distribution builds would add one).
    ///
    /// Deliberately `appIdentifier` first, `leafHash` second in the parameter list and in the
    /// generated string — mirrors `codesign -d -r-`'s own default designated-requirement ordering
    /// for a bundle with an `Info.plist` (verified against this machine's real `Sweep.app`), so
    /// the string this produces is exactly what `codesign` itself would already say Sweep.app's
    /// requirement is.
    public static func designatedRequirement(appIdentifier: String, leafHash: String) throws -> String {
        guard isValidAppIdentifier(appIdentifier) else { throw TrustError.malformedAppIdentifier(appIdentifier) }
        guard isValidLeafHash(leafHash) else { throw TrustError.malformedLeafHash(leafHash) }
        return "identifier \"\(appIdentifier)\" and certificate leaf = H\"\(leafHash)\""
    }

    /// The caller must be the currently logged-in console (Aqua) user — never a different local
    /// account (fast user switching running a legitimately-signed second copy of Sweep), a
    /// background/daemon session with no console at all, or a caller asserting a UID with no
    /// console session backing it. `consoleUID == nil` (no one is logged into the console right
    /// now) fails closed rather than being treated as "no restriction."
    public static func isAuthorizedCaller(callerUID: uid_t, consoleUID: uid_t?) -> Bool {
        guard let consoleUID else { return false }
        return callerUID == consoleUID
    }
}
