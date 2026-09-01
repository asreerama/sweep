import XCTest
@testable import SweepMenu

/// "Open Sweep" pins the exact `sweep://` scheme `AppState.handleOpenURL`
/// (`Sources/SweepApp/Shell/AppState.swift`) listens on — a regression guard against the literal
/// string silently drifting between the two targets, since nothing else ties them together.
final class MenuQuickActionsTests: XCTestCase {
    func testOpenSweepURLUsesTheSweepScheme() {
        XCTAssertEqual(MenuQuickActions.openSweepURL.scheme, "sweep")
    }

    func testOpenSweepURLHasNoHostOrPath() {
        // No destination past the root today (see the doc comment on `MenuQuickActions`); this
        // pins that "just open/activate the app" stays the behavior until a real deep link is
        // added deliberately.
        XCTAssertNil(MenuQuickActions.openSweepURL.host)
        XCTAssertTrue(MenuQuickActions.openSweepURL.path.isEmpty)
    }
}
