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
}
