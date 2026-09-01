import XCTest
@testable import SweepPolicy

final class HelperTrustTests: XCTestCase {
    // A real SHA-1 hex digest shape (40 lowercase hex chars) — same shape `codesign -d -r-`
    // printed for this machine's own "Nodu Sim Local Signer" identity while this feature was
    // being built. The test does not depend on that identity existing; it only needs the shape.
    private let validHash = "4cb2d9a0b092a341bd1e96285b5635986fb15c11"

    // MARK: - Hash format validation

    func testValidFortyCharacterHexHashIsAccepted() {
        XCTAssertTrue(HelperTrust.isValidLeafHash(validHash))
    }

    func testUppercaseHexIsAlsoAccepted() {
        XCTAssertTrue(HelperTrust.isValidLeafHash(validHash.uppercased()))
    }

    func testWrongLengthIsRejected() {
        XCTAssertFalse(HelperTrust.isValidLeafHash(String(validHash.dropLast())))
        XCTAssertFalse(HelperTrust.isValidLeafHash(validHash + "0"))
    }

    func testEmptyStringIsRejected() {
        XCTAssertFalse(HelperTrust.isValidLeafHash(""))
    }

    func testNonHexCharactersAreRejected() {
        XCTAssertFalse(HelperTrust.isValidLeafHash("zz" + String(validHash.dropFirst(2))))
    }

    func testCheckedInDevPlaceholderIsRejected() {
        // The exact value `GeneratedHelperTrust` ships with before `scripts/build-app.sh` ever
        // runs — this is the fail-closed guarantee the placeholder exists to prove.
        XCTAssertFalse(HelperTrust.isValidLeafHash("UNSET-PLACEHOLDER-REPLACED-BY-scripts-build-app-sh"))
    }

    // MARK: - App identifier format validation

    func testAppBundleIdentifierIsAccepted() {
        XCTAssertTrue(HelperTrust.isValidAppIdentifier(HelperIdentity.appBundleIdentifier))
    }

    func testEmptyAppIdentifierIsRejected() {
        XCTAssertFalse(HelperTrust.isValidAppIdentifier(""))
    }

    func testAppIdentifierContainingAQuoteIsRejected() {
        // Would otherwise let a malformed value escape the requirement language's double-quoted
        // `identifier "..."` literal.
        XCTAssertFalse(HelperTrust.isValidAppIdentifier("com.aditya.sweep\" or certificate leaf = H\"anything"))
    }

    func testAppIdentifierContainingWhitespaceIsRejected() {
        XCTAssertFalse(HelperTrust.isValidAppIdentifier("com.aditya sweep"))
    }

    func testCheckedInDevIdentifierPlaceholderIsRejected() {
        // The exact value `GeneratedHelperTrust` ships with before `scripts/build-app.sh` ever
        // runs — this must fail closed exactly like the leaf-hash placeholder does.
        XCTAssertFalse(HelperTrust.isValidAppIdentifier("UNSET PLACEHOLDER - REPLACED BY scripts/build-app.sh"))
    }

    // MARK: - Designated requirement string

    /// Codex finding #1 ("caller identity is certificate-wide"): a `certificate leaf`-only
    /// requirement is satisfied by *any* binary this machine's signing cert has signed, since the
    /// same local cert signs more than one tool. This is the regression test — it fails against
    /// the pre-fix implementation, which produced only `certificate leaf = H"…"` with no
    /// identifier clause at all.
    func testDesignatedRequirementContainsTheAppIdentifierClause() throws {
        let requirement = try HelperTrust.designatedRequirement(
            appIdentifier: HelperIdentity.appBundleIdentifier,
            leafHash: validHash
        )
        XCTAssertTrue(requirement.contains("identifier \"\(HelperIdentity.appBundleIdentifier)\""))
    }

    func testDesignatedRequirementIsExactlyTheIdentifierAndCertificateLeafClause() throws {
        let requirement = try HelperTrust.designatedRequirement(
            appIdentifier: HelperIdentity.appBundleIdentifier,
            leafHash: validHash
        )
        XCTAssertEqual(
            requirement,
            "identifier \"\(HelperIdentity.appBundleIdentifier)\" and certificate leaf = H\"\(validHash)\""
        )
    }

    func testDesignatedRequirementCarriesNoAnchorClause() throws {
        let requirement = try HelperTrust.designatedRequirement(appIdentifier: HelperIdentity.appBundleIdentifier, leafHash: validHash)
        XCTAssertFalse(requirement.contains("anchor"))
    }

    /// The exact "certificate-wide" hole the fix closes: two callers signed by the *same*
    /// certificate but with different app identifiers must produce two different, mutually
    /// exclusive requirement strings — proving the identifier is actually load-bearing in the
    /// generated requirement, not merely appended and ignored.
    func testDifferentAppIdentifiersWithTheSameCertificateProduceDifferentRequirements() throws {
        let sweepRequirement = try HelperTrust.designatedRequirement(appIdentifier: "com.aditya.sweep", leafHash: validHash)
        let otherToolRequirement = try HelperTrust.designatedRequirement(appIdentifier: "com.aditya.othertool", leafHash: validHash)

        XCTAssertNotEqual(sweepRequirement, otherToolRequirement)
        XCTAssertFalse(otherToolRequirement.contains("\"com.aditya.sweep\""))
    }

    func testDesignatedRequirementThrowsOnMalformedHash() {
        XCTAssertThrowsError(
            try HelperTrust.designatedRequirement(appIdentifier: HelperIdentity.appBundleIdentifier, leafHash: "not-a-hash")
        ) { error in
            XCTAssertEqual(error as? HelperTrust.TrustError, .malformedLeafHash("not-a-hash"))
        }
    }

    func testDesignatedRequirementThrowsOnMalformedAppIdentifier() {
        XCTAssertThrowsError(
            try HelperTrust.designatedRequirement(appIdentifier: "", leafHash: validHash)
        ) { error in
            XCTAssertEqual(error as? HelperTrust.TrustError, .malformedAppIdentifier(""))
        }
    }

    // MARK: - Console-user authorization

    func testCallerMatchingTheConsoleUserIsAuthorized() {
        XCTAssertTrue(HelperTrust.isAuthorizedCaller(callerUID: 501, consoleUID: 501))
    }

    func testCallerFromADifferentAccountIsRefused() {
        XCTAssertFalse(HelperTrust.isAuthorizedCaller(callerUID: 501, consoleUID: 502))
    }

    func testNoConsoleSessionRefusesEveryCaller() {
        XCTAssertFalse(HelperTrust.isAuthorizedCaller(callerUID: 0, consoleUID: nil))
        XCTAssertFalse(HelperTrust.isAuthorizedCaller(callerUID: 501, consoleUID: nil))
    }
}
