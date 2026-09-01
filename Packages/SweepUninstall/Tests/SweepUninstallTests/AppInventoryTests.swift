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
}
