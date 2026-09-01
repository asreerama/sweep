import XCTest
@testable import SweepApp

/// First-run flag logic (PLAN §4/§5 task). `shouldPresentAutomatically` is tested directly as a
/// pure function; the rest exercises `OnboardingLaunchState` against an ephemeral `UserDefaults`
/// suite, never `.standard`, so this suite cannot bleed into (or be polluted by) a real run's
/// persisted onboarding state.
@MainActor
final class OnboardingLaunchStateTests: XCTestCase {

    private func ephemeralDefaults() -> UserDefaults {
        let suiteName = "com.sweep.tests.onboarding.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    // MARK: - Pure rule

    func testShouldPresentAutomaticallyIsExactlyTheNegationOfHasCompletedBefore() {
        XCTAssertTrue(OnboardingLaunchState.shouldPresentAutomatically(hasCompletedBefore: false))
        XCTAssertFalse(OnboardingLaunchState.shouldPresentAutomatically(hasCompletedBefore: true))
    }

    // MARK: - First launch ever

    func testFirstLaunchPresentsAutomatically() {
        let state = OnboardingLaunchState(defaults: ephemeralDefaults())
        XCTAssertTrue(state.isPresented)
    }

    // MARK: - markSeen: persists, never shows again, whether finished or skipped

    func testMarkSeenDismissesAndPersists() {
        let defaults = ephemeralDefaults()
        let state = OnboardingLaunchState(defaults: defaults)
        XCTAssertTrue(state.isPresented)

        state.markSeen()
        XCTAssertFalse(state.isPresented)

        // A fresh instance over the same defaults — the next real launch of the app — must not
        // present automatically again.
        let relaunched = OnboardingLaunchState(defaults: defaults)
        XCTAssertFalse(relaunched.isPresented)
    }

    // MARK: - Settings re-entry: independent of the persisted flag

    func testPresentManuallyShowsItAgainWithoutClearingThePersistedFlag() {
        let defaults = ephemeralDefaults()
        let state = OnboardingLaunchState(defaults: defaults)
        state.markSeen()
        XCTAssertFalse(state.isPresented)

        state.presentManually()
        XCTAssertTrue(state.isPresented)

        // Dismissing a manual re-run (without finishing/skipping it again) must not un-persist
        // "seen" — a later real launch still should not auto-present.
        state.dismiss()
        XCTAssertFalse(state.isPresented)
        let relaunched = OnboardingLaunchState(defaults: defaults)
        XCTAssertFalse(relaunched.isPresented)
    }

    // MARK: - setPresented: the two-way binding shape `.sheet(isPresented:)` needs

    func testSetPresentedRoutesThroughPresentManuallyAndDismiss() {
        let defaults = ephemeralDefaults()
        let state = OnboardingLaunchState(defaults: defaults)
        state.markSeen()

        state.setPresented(true)
        XCTAssertTrue(state.isPresented)

        state.setPresented(false)
        XCTAssertFalse(state.isPresented)
        // Matches `dismiss()`'s contract: does not re-open the "show automatically" door.
        XCTAssertFalse(OnboardingLaunchState(defaults: defaults).isPresented)
    }
}
