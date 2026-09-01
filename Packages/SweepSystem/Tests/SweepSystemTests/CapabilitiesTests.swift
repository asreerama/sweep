import Darwin
import XCTest
@testable import SweepSystem

/// PLAN §4: the capability model must be "pure-function testable with injected probe results."
/// `CapabilityErrno.classify` and `CapabilityAggregator.status(from:)` are exactly that — no
/// filesystem, no TCC state, no async — so every combination below is exercised directly.
final class CapabilitiesTests: XCTestCase {

    // MARK: - errno classification

    func testPermissionErrnosClassifyAsPermissionDenied() {
        XCTAssertEqual(CapabilityErrno.classify(EACCES), .permissionDenied)
        XCTAssertEqual(CapabilityErrno.classify(EPERM), .permissionDenied)
    }

    func testAbsenceAndOtherErrnosClassifyAsInconclusive() {
        // ENOENT/ENOTDIR: the canary just isn't there on this machine — never proof of denial.
        XCTAssertEqual(CapabilityErrno.classify(ENOENT), .inconclusive)
        XCTAssertEqual(CapabilityErrno.classify(ENOTDIR), .inconclusive)
        // Some unrelated errno this probe layer has no business treating as a TCC refusal.
        XCTAssertEqual(CapabilityErrno.classify(EIO), .inconclusive)
        XCTAssertEqual(CapabilityErrno.classify(EINTR), .inconclusive)
    }

    // MARK: - aggregation: every combination PLAN §4 names, plus the shapes it implies

    func testEmptyOutcomesAreUnknown() {
        XCTAssertEqual(CapabilityAggregator.status(from: []), .unknown)
    }

    func testAllInconclusiveIsUnknown() {
        XCTAssertEqual(CapabilityAggregator.status(from: [.inconclusive]), .unknown)
        XCTAssertEqual(CapabilityAggregator.status(from: [.inconclusive, .inconclusive, .inconclusive]), .unknown)
    }

    func testAnySuccessIsAvailable() {
        XCTAssertEqual(CapabilityAggregator.status(from: [.success]), .available)
        XCTAssertEqual(CapabilityAggregator.status(from: [.success, .success]), .available)
        XCTAssertEqual(CapabilityAggregator.status(from: [.inconclusive, .success]), .available)
        XCTAssertEqual(CapabilityAggregator.status(from: [.success, .inconclusive, .inconclusive]), .available)
    }

    func testExplicitDenialWithNoSuccessIsDenied() {
        XCTAssertEqual(CapabilityAggregator.status(from: [.permissionDenied]), .denied)
        XCTAssertEqual(CapabilityAggregator.status(from: [.inconclusive, .permissionDenied]), .denied)
        XCTAssertEqual(CapabilityAggregator.status(from: [.permissionDenied, .permissionDenied, .inconclusive]), .denied)
    }

    /// The one precedence rule that is not obvious from reading the three cases in isolation: a
    /// success from one canary outweighs a denial from another. A partial grant still proves the
    /// capability works at least somewhere, which is what `.available` actually promises callers
    /// (PLAN §4: "any success => available").
    func testSuccessOutweighsDenialWhenBothArePresent() {
        XCTAssertEqual(CapabilityAggregator.status(from: [.permissionDenied, .success]), .available)
        XCTAssertEqual(CapabilityAggregator.status(from: [.success, .permissionDenied, .inconclusive]), .available)
    }

    // MARK: - FullDiskAccessProbe.defaultCanaryPaths: shape and order

    func testDefaultCanaryPathsAreTheThreeDocumentedCanariesInOrder() {
        let paths = FullDiskAccessProbe.defaultCanaryPaths(home: "/Users/probe")
        XCTAssertEqual(paths.count, 3)
        XCTAssertEqual(paths[0], "/Users/probe/Library/Safari/CloudTabs.db")
        XCTAssertEqual(paths[1], "/Library/Preferences/com.apple.TimeMachine.plist")
        XCTAssertEqual(paths[2], "/Users/probe/Library/Containers/com.apple.mail/Info.plist")
    }

    // MARK: - FullDiskAccessProbe.probe(path:): the real syscall path

    func testProbeSucceedsReadingARealReadableFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sweep-capabilities-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "readable")
        try Data("canary".utf8).write(to: file)

        XCTAssertEqual(FullDiskAccessProbe.probe(path: file.path), .success)
    }

    func testProbeIsInconclusiveForAPathThatDoesNotExist() {
        let missing = FileManager.default.temporaryDirectory
            .appending(path: "sweep-capabilities-test-missing-\(UUID().uuidString)")
        XCTAssertEqual(FullDiskAccessProbe.probe(path: missing.path), .inconclusive)
    }

    /// Forces a real `EACCES` at the kernel level (ordinary Unix permissions, standing in for the
    /// TCC-shaped refusal this probe is built to catch — both surface as the same errno, which is
    /// exactly why `CapabilityErrno.classify` cannot and does not try to distinguish them) by
    /// chmod-ing a file to `000`. Skipped when running as root, which bypasses this check
    /// entirely and would otherwise read the file back successfully.
    func testProbeDetectsPermissionDenied() throws {
        try XCTSkipIf(geteuid() == 0, "root bypasses Unix file permissions; cannot force EACCES this way")

        let directory = FileManager.default.temporaryDirectory
            .appending(path: "sweep-capabilities-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let file = directory.appending(path: "locked")
        try Data("canary".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)

        XCTAssertEqual(FullDiskAccessProbe.probe(path: file.path), .permissionDenied)
    }

    // MARK: - Injected FullDiskAccessProbing: the shape `CapabilityStore` (SweepApp) depends on

    func testFullDiskAccessProbingCanBeFakedForInjection() {
        struct FakeProbe: FullDiskAccessProbing {
            let outcomes: [CapabilityProbeOutcome]
            func probeOutcomes() -> [CapabilityProbeOutcome] { outcomes }
        }
        let fake = FakeProbe(outcomes: [.inconclusive, .success])
        XCTAssertEqual(CapabilityAggregator.status(from: fake.probeOutcomes()), .available)
    }
}
