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

    // MARK: - Designated requirement string

    func testDesignatedRequirementIsExactlyTheCertificateLeafClause() throws {
        let requirement = try HelperTrust.designatedRequirement(leafHash: validHash)
        XCTAssertEqual(requirement, "certificate leaf = H\"\(validHash)\"")
    }

    func testDesignatedRequirementCarriesNoAnchorOrIdentifierClause() throws {
        let requirement = try HelperTrust.designatedRequirement(leafHash: validHash)
        XCTAssertFalse(requirement.contains("anchor"))
        XCTAssertFalse(requirement.contains("identifier"))
    }

    func testDesignatedRequirementThrowsOnMalformedHash() {
        XCTAssertThrowsError(try HelperTrust.designatedRequirement(leafHash: "not-a-hash")) { error in
            XCTAssertEqual(error as? HelperTrust.TrustError, .malformedLeafHash("not-a-hash"))
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
