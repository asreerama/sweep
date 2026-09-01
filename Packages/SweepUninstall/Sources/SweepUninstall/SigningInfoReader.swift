import Foundation
import Security

/// Cheap, read-only signing facts about a bundle.
public struct SigningInfo: Sendable, Hashable {
    public let teamIdentifier: String?
    public let signingIdentifier: String?
    /// Heuristic only: the leaf certificate's subject summary mentions "Apple". This is
    /// NOT a trust decision (no chain validation is performed) — it exists purely to help
    /// classify "is this plausibly a system/Apple app" during inventory display, never as a
    /// security check.
    public let isAppleSigned: Bool
}

/// Reads code-signing identity via `SecStaticCode` without performing full validation.
///
/// `SecStaticCodeCheckValidity` hashes every file in the bundle to verify the signature end
/// to end — far too slow to run per app during a full-disk inventory scan. `SecCodeCopySigningInformation`
/// with `.signingInformation` only parses the already-embedded signature blob header, which is
/// cheap and sufficient for identity/team-id display purposes.
public enum SigningInfoReader {
    public static func read(at bundleURL: URL) -> SigningInfo? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else { return nil }

        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF)
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else { return nil }

        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signingIdentifier = info[kSecCodeInfoIdentifier as String] as? String

        var isAppleSigned = false
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            let summary = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
            isAppleSigned = summary.contains("Apple")
        }

        return SigningInfo(teamIdentifier: teamIdentifier, signingIdentifier: signingIdentifier, isAppleSigned: isAppleSigned)
    }

    /// Full, expensive validation: unlike ``read(at:)``, this also calls
    /// `SecStaticCodeCheckValidity`, which hashes every sealed resource in the bundle end to end.
    /// Never safe to call per-app during a full-disk inventory scan (see ``read(at:)``'s own doc
    /// comment) — this exists for the one-app-at-a-time Gate U uninstall-authorization path only
    /// (Codex Gate-U finding #1), where a single bundle's signature is worth the cost because an
    /// exact-bundle-id leftover match is otherwise indistinguishable from a planted app that
    /// merely set the same `CFBundleIdentifier` string.
    public static func readVerified(at bundleURL: URL) -> VerifiedSigningInfo? {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode)
        guard createStatus == errSecSuccess, let code = staticCode else { return nil }

        var infoCF: CFDictionary?
        let infoStatus = SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF)
        guard infoStatus == errSecSuccess, let info = infoCF as? [String: Any] else { return nil }

        let teamIdentifier = info[kSecCodeInfoTeamIdentifier as String] as? String
        let signingIdentifier = info[kSecCodeInfoIdentifier as String] as? String

        var isAppleSigned = false
        if let certs = info[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first {
            let summary = (SecCertificateCopySubjectSummary(leaf) as String?) ?? ""
            isAppleSigned = summary.contains("Apple")
        }

        // The one call `read(at:)` deliberately skips: hashes every file sealed by the signature
        // and confirms none of them changed since signing. `errSecSuccess` here is the only
        // acceptable outcome — anything else (a modified resource, a missing seal, no signature
        // at all) means this bundle's contents cannot be vouched for.
        let validityStatus = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: 0), nil)

        return VerifiedSigningInfo(
            teamIdentifier: teamIdentifier,
            signingIdentifier: signingIdentifier,
            isAppleSigned: isAppleSigned,
            isValiditySealed: validityStatus == errSecSuccess
        )
    }
}

/// The result of a full, expensive signature validation (``SigningInfoReader/readVerified(at:)``)
/// — never produced by the cheap ``SigningInfoReader/read(at:)`` used during inventory scanning.
public struct VerifiedSigningInfo: Sendable, Hashable {
    public let teamIdentifier: String?
    public let signingIdentifier: String?
    public let isAppleSigned: Bool
    /// `true` only when `SecStaticCodeCheckValidity` returned `errSecSuccess`: every sealed
    /// resource in the bundle still hashes to what the signature says it should. `false` for an
    /// unsigned bundle, an ad-hoc/broken seal, or a bundle whose contents were modified after
    /// signing.
    public let isValiditySealed: Bool
}
