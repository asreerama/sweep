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

    // MARK: - Completeness signal (Codex Gate-U finding A, second re-check loop)

    /// An existing `.app`-extensioned entry that `Bundle(url:)` refuses outright (here: a plain
    /// regular file sitting at a `.app` path, which `Bundle(url:)` empirically returns `nil` for
    /// on this platform — unlike a malformed `Info.plist`, which `Bundle` tolerates as an empty
    /// dictionary) must never be silently dropped: before the fix, the final `compactMap` over
    /// discovered bundle URLs dropped it with `isComplete` staying `true`, which meant Gate U
    /// could never tell "no other app is here" apart from "an app is here and we could not read
    /// it."
    func testCompletenessBecomesFalseWhenAnAppBundleCannotBeFullyRead() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppInventoryCompleteness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        // A readable, well-formed sibling, so the test also proves the broken entry does not take
        // down the rest of the scan with it.
        let goodApp = applications.appendingPathComponent("Good.app")
        try Self.writeMinimalAppBundle(at: goodApp, bundleID: "com.example.good", name: "Good")

        // Present, `.app`-extensioned, but a plain regular file rather than a real bundle
        // directory — `Bundle(url:)` returns `nil` for this, so `readAppInfo` returns `nil`,
        // exactly the "encountered but cannot be fully turned into an InstalledApp at all" case.
        let brokenApp = applications.appendingPathComponent("Broken.app")
        try Data("not a bundle".utf8).write(to: brokenApp)

        let scan = AppInventory.scanReportingCompleteness(directories: [applications])
        XCTAssertFalse(scan.isComplete, "an .app that could not be turned into an InstalledApp must mark the scan incomplete, not be silently skipped")
        XCTAssertTrue(scan.apps.contains { $0.bundlePath.path == goodApp.path }, "a genuinely readable sibling must still be reported")
        XCTAssertFalse(scan.apps.contains { $0.bundlePath.path == brokenApp.path }, "the unreadable bundle itself is never fabricated into a listed app")
    }

    /// A bundle whose `Info.plist` parses but carries no `CFBundleIdentifier` is still listed
    /// (existing contract: `InstalledApp.bundleIdentifier` is optional precisely for this case),
    /// but it can never be exact-bundle-id matched by `LeftoverMatcher` — so the scan that
    /// contains it must not claim to be a complete, bundle-id-resolved picture either.
    func testCompletenessBecomesFalseWhenAnAppHasNoReadableBundleIdentifier() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AppInventoryCompleteness-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let applications = root.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)

        let noIDApp = applications.appendingPathComponent("NoIdentifier.app")
        let contents = noIDApp.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleName</key>
            <string>NoIdentifier</string>
        </dict>
        </plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)

        let scan = AppInventory.scanReportingCompleteness(directories: [applications])
        XCTAssertFalse(scan.isComplete, "an app with no readable CFBundleIdentifier must mark the scan incomplete")
        let listed = try XCTUnwrap(scan.apps.first { $0.bundlePath.path == noIDApp.path })
        XCTAssertNil(listed.bundleIdentifier, "still listed, per InstalledApp's own documented contract")
    }

    /// Writes a minimal but real `.app` bundle (`Contents/Info.plist`), mirroring
    /// `SymlinkSafetyTests`' own private helper of the same shape.
    private static func writeMinimalAppBundle(at bundleURL: URL, bundleID: String, name: String) throws {
        let contents = bundleURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(bundleID)</string>
            <key>CFBundleName</key>
            <string>\(name)</string>
        </dict>
        </plist>
        """
        try plist.write(to: contents.appendingPathComponent("Info.plist"), atomically: true, encoding: .utf8)
    }
}
