import XCTest
@testable import SweepUninstall

final class AppInventoryTests: XCTestCase {
    func testScanFindsRealInstalledApps() {
        let apps = AppInventory.scan()
        XCTAssertGreaterThan(apps.count, 0, "expected at least one installed app under /Applications or ~/Applications on this machine")

        for app in apps {
            XCTAssertFalse(app.name.isEmpty, "\(app.bundlePath.path) should have a non-empty display name")
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.bundlePath.path))
        }

        let withBundleID = apps.filter { $0.bundleIdentifier != nil }
        XCTAssertGreaterThan(withBundleID.count, 0, "expected most discovered apps to expose a CFBundleIdentifier")
    }

    /// Per spec: soft, conditional check — only asserts when the real system state makes the
    /// assertion meaningful, never a hard requirement (macOS has relocated system apps between
    /// releases; PLAN.md notes Pearcleaner issue #533 as a real instance of this).
    func testFindsSafariOrFinderWhenPresentInScannedDirectories() throws {
        let fileManager = FileManager.default
        let candidateSystemApps = ["/Applications/Safari.app", "/Applications/Finder.app"]
        let present = candidateSystemApps.first { fileManager.fileExists(atPath: $0) }
        guard let present else {
            throw XCTSkip("Neither Safari.app nor Finder.app present in /Applications on this machine")
        }

        let apps = AppInventory.scan()
        XCTAssertTrue(apps.contains { $0.bundlePath.path == present })
    }

    func testScanIsDepthLimitedAndNeverDescendsIntoADiscoveredBundle() {
        let apps = AppInventory.scan()
        let paths = apps.map(\.bundlePath.path)
        for path in paths {
            XCTAssertFalse(
                paths.contains { $0 != path && path.hasPrefix($0 + "/") },
                "\(path) should not be nested inside another discovered .app bundle"
            )
        }
    }

    func testDefaultApplicationsDirectoriesIncludesSystemAndUserApplications() {
        let dirs = AppInventory.defaultApplicationsDirectories()
        XCTAssertTrue(dirs.contains(URL(fileURLWithPath: "/Applications")))
        XCTAssertTrue(dirs.contains(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")))
    }

    // MARK: - Completeness signal (Codex Gate-U finding #1)

    /// A root that simply does not exist (most machines have no `~/Applications`) must never, on
    /// its own, make the scan report itself incomplete — there is nothing hidden behind a
    /// directory that was never there.
    func testCompletenessStaysTrueWhenARootSimplyDoesNotExist() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppInventoryCompleteness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let realApplications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: realApplications, withIntermediateDirectories: true)
        let missingApplications = root.appendingPathComponent("DoesNotExist")

        let scan = AppInventory.scanReportingCompleteness(directories: [realApplications, missingApplications])
        XCTAssertTrue(scan.isComplete, "a root that never existed must not mark the scan incomplete")
    }

    /// A root that DOES exist but cannot be listed (permission denied) must mark the scan
    /// incomplete: some other installed app could be sitting inside it, invisible to this scan.
    func testCompletenessBecomesFalseWhenAnExistingRootCannotBeEnumerated() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppInventoryCompleteness-\(UUID().uuidString)")
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: root.path)

        let scan = AppInventory.scanReportingCompleteness(directories: [root])
        XCTAssertFalse(scan.isComplete, "a root that exists but cannot be enumerated must mark the scan incomplete")
    }

    /// A root that exists but fails the real-directory identity check (a symlink standing in for
    /// the applications root) must also mark the scan incomplete, not merely be skipped silently.
    func testCompletenessBecomesFalseWhenARootIsASymlinkInsteadOfARealDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppInventoryCompleteness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let realTarget = root.appendingPathComponent("RealTarget")
        try FileManager.default.createDirectory(at: realTarget, withIntermediateDirectories: true)
        let symlinkRoot = root.appendingPathComponent("Applications")
        try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: realTarget)

        let scan = AppInventory.scanReportingCompleteness(directories: [symlinkRoot])
        XCTAssertFalse(scan.isComplete, "an applications root that is itself a symlink must mark the scan incomplete")
    }

    func testCompleteScanOfARealReadableRootStaysComplete() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppInventoryCompleteness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let scan = AppInventory.scanReportingCompleteness(directories: [root])
        XCTAssertTrue(scan.isComplete)
        XCTAssertTrue(scan.apps.isEmpty)
    }
}
