import XCTest
@testable import SweepHelper

/// Pure predicate, no root required — the point of keeping `isRunningAsRoot` injectable.
final class HelperRuntimeGuardTests: XCTestCase {
    func testRootEffectiveUIDPasses() {
        XCTAssertTrue(HelperRuntimeGuard.isRunningAsRoot(effectiveUID: 0))
    }

    func testNonRootEffectiveUIDFails() {
        XCTAssertFalse(HelperRuntimeGuard.isRunningAsRoot(effectiveUID: 501))
        XCTAssertFalse(HelperRuntimeGuard.isRunningAsRoot(effectiveUID: 1))
    }
}
