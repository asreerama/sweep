import XCTest
@testable import SweepApp

/// Pure hand-off decision behind the in-app `MenuBarExtra`'s `isInserted` binding (PLAN §3 module
/// 7, the P4-B split): none of this touches `NSWorkspace` — every case is an injected list of
/// running bundle identifiers.
final class MenuBarHandoffLogicTests: XCTestCase {
    func testShowsInAppMenuBarWhenStandaloneMenuAppIsNotRunning() {
        XCTAssertTrue(MenuBarHandoffLogic.shouldShowInAppMenuBar(runningBundleIdentifiers: []))
        XCTAssertTrue(MenuBarHandoffLogic.shouldShowInAppMenuBar(runningBundleIdentifiers: ["com.aditya.sweep"]))
    }

    func testHidesInAppMenuBarWhenStandaloneMenuAppIsRunning() {
        XCTAssertFalse(MenuBarHandoffLogic.shouldShowInAppMenuBar(
            runningBundleIdentifiers: ["com.aditya.sweep.menu"]
        ))
    }

    func testHidesInAppMenuBarRegardlessOfOtherRunningApps() {
        XCTAssertFalse(MenuBarHandoffLogic.shouldShowInAppMenuBar(
            runningBundleIdentifiers: ["com.apple.finder", "com.aditya.sweep", "com.aditya.sweep.menu", "com.apple.dock"]
        ))
    }

    func testBundleIdentifierMatchIsExactNotPrefix() {
        // A bundle id that merely starts with the same string (a hypothetical
        // "com.aditya.sweep.menu.beta") must never be mistaken for the real thing.
        XCTAssertTrue(MenuBarHandoffLogic.shouldShowInAppMenuBar(
            runningBundleIdentifiers: ["com.aditya.sweep.menu.beta"]
        ))
    }

    func testPinnedBundleIdentifierMatchesBuildMenuScript() {
        // `scripts/build-menu.sh` bakes this exact string into `SweepMenu`'s Info.plist
        // `CFBundleIdentifier`; a drift between the two would make the hand-off silently never
        // trigger.
        XCTAssertEqual(MenuBarHandoffLogic.menuAppBundleIdentifier, "com.aditya.sweep.menu")
    }
}
