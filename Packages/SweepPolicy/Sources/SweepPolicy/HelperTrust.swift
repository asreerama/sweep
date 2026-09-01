import Foundation

/// Pure trust decisions for `SweepHelper`'s XPC listener. Both functions here are deliberately
/// free of `Security`/`SystemConfiguration` system calls — those live in `SweepHelper` itself
/// (`ConsoleUser.currentConsoleUID()`, `SecRequirementCreateWithString`) — so the actual *decision*
/// logic is testable as a normal user, without root and without a real signing identity, per the
/// task spec: "must also build+test its validation logic as a normal-user unit test."
public enum HelperTrust {
    public enum TrustError: Error, Sendable, Equatable, CustomStringConvertible {
        case malformedLeafHash(String)

        public var description: String {
            switch self {
            case .malformedLeafHash(let hash):
                "refused: \"\(hash)\" is not a SHA-1 leaf certificate hash"
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

    /// The exact designated-requirement language `SecRequirementCreateWithString` needs
    /// (Apple's Code Signing Requirement Language), deliberately with no `anchor`/`identifier`
    /// clause: this must keep trusting Sweep.app across a rebuild that changes nothing but the
    /// binary, and bind to nothing but "signed with this exact certificate" — the one property
    /// `scripts/build-app.sh`'s self-signed local identity actually guarantees stays stable.
    public static func designatedRequirement(leafHash: String) throws -> String {
        guard isValidLeafHash(leafHash) else { throw TrustError.malformedLeafHash(leafHash) }
        return "certificate leaf = H\"\(leafHash)\""
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
