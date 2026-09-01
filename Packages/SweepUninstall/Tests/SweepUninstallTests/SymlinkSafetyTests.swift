import XCTest
@testable import SweepUninstall

/// Regression coverage for finding #10 in the adversarial review: `RootWalker` and
/// `AppInventory` previously used `FileManager.fileExists(atPath:isDirectory:)`, which follows
/// symlinks, then recursed via `contentsOfDirectory` — so a symlinked directory planted inside a
/// search root could make content physically located anywhere else on disk surface as if it were
/// found under that root (and, for an exact bundle-id name, auto-selectable).
final class SymlinkSafetyTests: XCTestCase {
    private let fileManager = FileManager.default

    func testRootWalkerNeverRecursesThroughASymlinkedDirectory() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent("SweepUninstallSymlinkFixture-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("home")
        let systemLaunchDaemons = root.appendingPathComponent("LaunchDaemons")
        try fileManager.createDirectory(at: systemLaunchDaemons, withIntermediateDirectories: true)

        let appSupport = home.appendingPathComponent("Library/Application Support")
        try fileManager.createDirectory(at: appSupport, withIntermediateDirectories: true)

        // The dangerous setup finding #10 describes: a directory physically OUTSIDE the search
        // root (standing in for e.g. ~/Documents) that legitimately contains an exact-bundle-id
        // named folder...
        let outside = root.appendingPathComponent("Outside")
        try fileManager.createDirectory(at: outside.appendingPathComponent("com.example.foo"), withIntermediateDirectories: true)

        // ...reachable only by following a symlink planted INSIDE the search root.
        let symlinkPath = appSupport.appendingPathComponent("InnocentLookingLink")
        try fileManager.createSymbolicLink(at: symlinkPath, withDestinationURL: outside)

        let entries = RootWalker.entries(
            in: .applicationSupport,
            homeDirectory: home,
            systemLaunchDaemonsDirectory: systemLaunchDaemons,
            fileManager: fileManager
        )

        XCTAssertFalse(
            entries.contains { $0.url.lastPathComponent == "com.example.foo" },
            "the walker must never recurse through a symlinked directory to discover an item physically outside the search root"
        )
        // The symlink itself may legitimately be reported as a leaf entry — removing a symlink
        // never touches its target, so only recursing *through* it is unsafe.
        XCTAssertTrue(entries.contains { $0.url.lastPathComponent == "InnocentLookingLink" })

        // End-to-end: the physically-outside folder must never surface as a leftover candidate
        // for any app, matched or not.
        let candidates = LeftoverMatcher.candidates(
            for: LeftoverFixture.fooApp,
            roots: [.applicationSupport],
            homeDirectory: home,
            systemLaunchDaemonsDirectory: systemLaunchDaemons,
            receipts: EmptyPkgutilReceiptsProvider(),
            fileManager: fileManager
        )
        XCTAssertFalse(candidates.contains { $0.url.path.hasSuffix("Outside/com.example.foo") })
    }

    func testRootWalkerRefusesASearchRootThatIsItselfASymlink() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent("SweepUninstallSymlinkRootFixture-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let home = root.appendingPathComponent("home")
        let systemLaunchDaemons = root.appendingPathComponent("LaunchDaemons")
        try fileManager.createDirectory(at: systemLaunchDaemons, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: home.appendingPathComponent("Library"), withIntermediateDirectories: true)

        let outside = root.appendingPathComponent("Outside")
        try fileManager.createDirectory(at: outside.appendingPathComponent("com.example.foo"), withIntermediateDirectories: true)

        // `~/Library/Application Support` itself is a symlink to a directory outside the fixture.
        let appSupportPath = home.appendingPathComponent("Library/Application Support")
        try fileManager.createSymbolicLink(at: appSupportPath, withDestinationURL: outside)

        let entries = RootWalker.entries(
            in: .applicationSupport,
            homeDirectory: home,
            systemLaunchDaemonsDirectory: systemLaunchDaemons,
            fileManager: fileManager
        )
        XCTAssertTrue(entries.isEmpty, "a search root that is itself a symlink must never be walked")
    }

    func testAppInventoryNeverRecursesThroughASymlinkedSubdirectory() throws {
        let root = fileManager.temporaryDirectory.appendingPathComponent("SweepUninstallAppInventorySymlinkFixture-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let applications = root.appendingPathComponent("Applications")
        try fileManager.createDirectory(at: applications, withIntermediateDirectories: true)

        let outside = root.appendingPathComponent("Outside")
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let evilApp = outside.appendingPathComponent("Evil.app")
        try Self.writeMinimalAppBundle(at: evilApp, bundleID: "com.evil.app", name: "Evil")

        // A vendor-style subfolder directly under /Applications that is actually a symlink
        // pointing outside the configured Applications directory entirely.
        let symlinkPath = applications.appendingPathComponent("VendorFolder")
        try fileManager.createSymbolicLink(at: symlinkPath, withDestinationURL: outside)

        let apps = AppInventory.scan(directories: [applications], fileManager: fileManager)
        XCTAssertFalse(
            apps.contains { $0.bundlePath.path == evilApp.path },
            "AppInventory must never recurse through a symlinked subdirectory to discover .app bundles outside the configured Applications directory"
        )
    }

    func testAppInventoryStillFindsARealAppOneVendorFolderLevelDeep() throws {
        // Sanity check that the fix didn't also break the legitimate, non-symlink case the
        // depth-1 recursion exists for (e.g. `/Applications/JetBrains Toolbox`-style nesting).
        let root = fileManager.temporaryDirectory.appendingPathComponent("SweepUninstallAppInventoryRealFixture-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: root) }

        let applications = root.appendingPathComponent("Applications")
        let vendorFolder = applications.appendingPathComponent("VendorFolder")
        let realApp = vendorFolder.appendingPathComponent("Real.app")
        try Self.writeMinimalAppBundle(at: realApp, bundleID: "com.real.app", name: "Real")

        let apps = AppInventory.scan(directories: [applications], fileManager: fileManager)
        XCTAssertTrue(apps.contains { $0.bundlePath.path == realApp.path })
    }

    /// Writes a minimal but real `.app` bundle (`Contents/Info.plist`, the structure
    /// `Bundle(url:)` actually expects) so a test's assertion depends on `AppInventory` genuinely
    /// resolving — or correctly refusing to reach — the bundle, rather than passing vacuously
    /// because a malformed fixture made `readAppInfo` return `nil` either way.
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
