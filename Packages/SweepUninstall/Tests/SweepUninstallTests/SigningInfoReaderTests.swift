import XCTest
@testable import SweepUninstall

/// Coverage for `SigningInfoReader.readVerified(at:)` (Codex Gate-U finding #1): the one, full
/// `SecStaticCodeCheckValidity` call `read(at:)` deliberately never performs.
final class SigningInfoReaderTests: XCTestCase {
    private let fileManager = FileManager.default

    func testUnsignedBundleHasNoVerifiedSigningInfo() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent("SigningInfoReader-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let bundle = try Self.makeBundle(at: root.appendingPathComponent("Unsigned.app"), bundleID: "com.example.unsigned")

        // Never ad-hoc signed: either `SecStaticCodeCreateWithPath` itself fails to see a
        // signature worth validating, or validity check fails outright.
        let verified = SigningInfoReader.readVerified(at: bundle)
        XCTAssertTrue(verified == nil || verified?.isValiditySealed == false)
    }

    /// Ad-hoc signing (`codesign -s -`) needs no real certificate, so this is portable across any
    /// Mac with the Xcode command line tools — no dependency on a real signing identity being
    /// installed.
    func testAdHocSignedBundlePassesValidityAndDefaultsIdentifierToBundleID() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent("SigningInfoReader-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let bundle = try Self.makeBundle(at: root.appendingPathComponent("Signed.app"), bundleID: "com.example.signed")
        try Self.adHocSign(bundle)

        let verified = try XCTUnwrap(SigningInfoReader.readVerified(at: bundle))
        XCTAssertTrue(verified.isValiditySealed)
        XCTAssertEqual(verified.signingIdentifier, "com.example.signed")
        XCTAssertNil(verified.teamIdentifier, "ad-hoc signing carries no team identifier")
        XCTAssertFalse(verified.isAppleSigned)
    }

    /// Modifying a sealed resource after signing must invalidate the signature end to end — the
    /// exact tampering `read(at:)`'s cheap header-only parse can never detect.
    func testTamperingAfterSigningInvalidatesValiditySeal() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent("SigningInfoReader-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }
        let bundle = try Self.makeBundle(at: root.appendingPathComponent("Tampered.app"), bundleID: "com.example.tampered")
        try Self.adHocSign(bundle)

        // Confirm it validated cleanly before tampering.
        XCTAssertEqual(SigningInfoReader.readVerified(at: bundle)?.isValiditySealed, true)

        // Overwrite the sealed executable after signing.
        let executable = bundle.appendingPathComponent("Contents/MacOS/Tampered")
        try Data("#!/bin/sh\necho tampered\n".utf8).write(to: executable)

        let verified = SigningInfoReader.readVerified(at: bundle)
        XCTAssertEqual(verified?.isValiditySealed, false, "a sealed resource modified after signing must fail validity")
    }

    // MARK: - Helpers

    @discardableResult
    private static func makeBundle(at bundleURL: URL, bundleID: String) throws -> URL {
        let contents = bundleURL.appendingPathComponent("Contents")
        let macOS = contents.appendingPathComponent("MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let name = bundleURL.deletingPathExtension().lastPathComponent

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": bundleID,
            "CFBundleName": name,
            "CFBundleExecutable": name,
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))

        let executable = macOS.appendingPathComponent(name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        return bundleURL
    }

    private static func adHocSign(_ bundleURL: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-s", "-", "--force", bundleURL.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw XCTSkip("codesign unavailable or failed in this environment: \(message)")
        }
    }
}
