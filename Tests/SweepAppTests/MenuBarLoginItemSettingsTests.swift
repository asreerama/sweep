import ServiceManagement
import XCTest
@testable import SweepApp

// MARK: - Fakes

/// Scripts a login-item registration outcome without a real `SweepMenu` login item embedded in
/// this build — same shape `HelperClientStateMachineTests.swift`'s `FakeHelperService` uses for
/// the privileged helper's `SMAppService.daemon`.
private final class FakeMenuBarLoginItemService: MenuBarLoginItemControlling, @unchecked Sendable {
    private var status: SMAppService.Status
    private(set) var registerCallCount = 0
    private(set) var unregisterCallCount = 0
    var registerError: Error?
    var unregisterError: Error?

    init(status: SMAppService.Status = .notRegistered) {
        self.status = status
    }

    func currentStatus() -> SMAppService.Status { status }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
        status = .enabled
    }

    func unregister() throws {
        unregisterCallCount += 1
        if let unregisterError { throw unregisterError }
        status = .notRegistered
    }
}

private struct StubRegistrationError: Error {}

/// Counts calls to an injected `terminateRunningMenuApp` closure. A plain captured `var` cannot
/// cross into the `@Sendable () -> Void` the real initializer requires; this small `@unchecked
/// Sendable` box is the same trade `FakeHelperService`'s call-count properties above make.
private final class TerminateSpy: @unchecked Sendable {
    private(set) var callCount = 0
    func callAsFunction() { callCount += 1 }
}

/// Pure logic + state-machine behind Settings' menu-bar-app toggle (PLAN §3 module 7 task 3):
/// register/unregister on toggle, terminate-on-disable, default-off, and status reuse — none of
/// it against a real `SMAppService` login item or a live `NSRunningApplication`.
@MainActor
final class MenuBarLoginItemSettingsTests: XCTestCase {

    private func makeDefaults() -> UserDefaults {
        let suiteName = "MenuBarLoginItemSettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    func testDefaultsToDisabledWhenNeverConfigured() {
        let settings = MenuBarLoginItemSettings(
            service: FakeMenuBarLoginItemService(), terminateRunningMenuApp: {}, defaults: makeDefaults()
        )
        XCTAssertFalse(settings.isEnabled)
    }

    func testTogglingOnRegistersAndNeverTerminates() {
        let service = FakeMenuBarLoginItemService()
        let terminateSpy = TerminateSpy()
        let settings = MenuBarLoginItemSettings(
            service: service, terminateRunningMenuApp: terminateSpy.callAsFunction, defaults: makeDefaults()
        )
        settings.isEnabled = true
        XCTAssertEqual(service.registerCallCount, 1)
        XCTAssertEqual(service.unregisterCallCount, 0)
        XCTAssertEqual(terminateSpy.callCount, 0)
        XCTAssertEqual(settings.status, .enabled)
    }

    func testTogglingOffUnregistersAndTerminatesRunningMenuApp() {
        let service = FakeMenuBarLoginItemService()
        let terminateSpy = TerminateSpy()
        let settings = MenuBarLoginItemSettings(
            service: service, terminateRunningMenuApp: terminateSpy.callAsFunction, defaults: makeDefaults()
        )
        settings.isEnabled = true
        settings.isEnabled = false
        XCTAssertEqual(service.unregisterCallCount, 1)
        XCTAssertEqual(terminateSpy.callCount, 1, "turning the toggle off must quit an already-running SweepMenu, not just unregister future launches")
    }

    func testSettingSameValueTwiceIsANoOp() {
        let service = FakeMenuBarLoginItemService()
        let settings = MenuBarLoginItemSettings(service: service, terminateRunningMenuApp: {}, defaults: makeDefaults())
        settings.isEnabled = false // already false — must not call register/unregister at all
        XCTAssertEqual(service.registerCallCount, 0)
        XCTAssertEqual(service.unregisterCallCount, 0)
    }

    func testRegistrationFailureStillRefreshesStatusRatherThanCrashOrHang() {
        let service = FakeMenuBarLoginItemService()
        service.registerError = StubRegistrationError()
        let settings = MenuBarLoginItemSettings(service: service, terminateRunningMenuApp: {}, defaults: makeDefaults())
        settings.isEnabled = true
        XCTAssertEqual(service.registerCallCount, 1)
        // The fake never advances `status` past `.notRegistered` when `register()` throws.
        XCTAssertEqual(settings.status, .notRegistered)
    }

    func testStatusDescriptionReusesSMAppServiceInventoryDescribe() {
        let settings = MenuBarLoginItemSettings(
            service: FakeMenuBarLoginItemService(status: .requiresApproval),
            terminateRunningMenuApp: {},
            defaults: makeDefaults()
        )
        settings.refreshStatus()
        XCTAssertEqual(settings.statusDescription, SMAppServiceInventory.describe(.requiresApproval))
    }

    func testPersistsAcrossInstancesViaInjectedDefaults() {
        let defaults = makeDefaults()
        let first = MenuBarLoginItemSettings(service: FakeMenuBarLoginItemService(), terminateRunningMenuApp: {}, defaults: defaults)
        first.isEnabled = true

        let second = MenuBarLoginItemSettings(
            service: FakeMenuBarLoginItemService(status: .enabled), terminateRunningMenuApp: {}, defaults: defaults
        )
        XCTAssertTrue(second.isEnabled)
    }

    func testBundleIdentifierMatchesBuildMenuScript() {
        // `scripts/build-menu.sh` bakes this exact string into `SweepMenu`'s Info.plist
        // `CFBundleIdentifier`, and it is also what `SMAppService.loginItem(identifier:)` above
        // looks up inside `Contents/Library/LoginItems`. A drift here would make registration
        // silently target a login item that does not exist.
        XCTAssertEqual(MenuBarLoginItemIdentity.bundleIdentifier, "com.aditya.sweep.menu")
    }
}
