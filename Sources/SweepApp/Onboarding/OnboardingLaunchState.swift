import Foundation
import Observation

/// First-run detection for the onboarding sheet (PLAN §4/§5 task: "shown once, never blocks the
/// main window", "re-runnable from Settings").
///
/// One `UserDefaults` boolean, same shape as `SentinelSettings`' own single-setting store: once
/// the flow has finished or been skipped a single time, it never presents itself automatically
/// again on a later launch. `SettingsView`'s "Show onboarding again" is the only other way back
/// in, and goes through `presentManually()` rather than touching the persisted flag at all — a
/// deliberate re-run must never look, to a later launch, like the user had never seen onboarding.
@MainActor
@Observable
final class OnboardingLaunchState {
    static let shared = OnboardingLaunchState()

    private static let hasCompletedKey = "SweepOnboardingHasCompletedFirstRun"

    /// What `SweepApp.swift`'s `.sheet(isPresented:)` binds to. Distinct from the persisted flag:
    /// this is "is the sheet on screen right now", which also has to flip back to `false` when
    /// the user dismisses a manually-triggered re-run that never touches `hasCompletedKey` again.
    private(set) var isPresented: Bool

    private let defaults: UserDefaults

    /// `defaults` is injectable so tests can point this at an ephemeral suite instead of the
    /// real `UserDefaults.standard` — see `OnboardingLaunchStateTests`.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.isPresented = Self.shouldPresentAutomatically(
            hasCompletedBefore: defaults.bool(forKey: Self.hasCompletedKey)
        )
    }

    /// Pure first-run rule, pulled out of `init` specifically so it is testable without
    /// constructing a `UserDefaults` at all: present automatically exactly once, on the launch
    /// before the flag is ever set.
    static func shouldPresentAutomatically(hasCompletedBefore: Bool) -> Bool {
        !hasCompletedBefore
    }

    /// Called when the flow finishes or is skipped — both count as "seen" (PLAN task: "Skippable
    /// at every step"; a skip must not re-nag on the next launch). Persists the flag so no future
    /// launch of this instance, or a fresh one, presents automatically again.
    func markSeen() {
        defaults.set(true, forKey: Self.hasCompletedKey)
        isPresented = false
    }

    /// `SettingsView`'s re-entry point. Does not touch the persisted flag — a deliberate re-run
    /// says nothing about whether a *future* launch should present automatically.
    func presentManually() {
        isPresented = true
    }

    /// The sheet's own dismiss path (Cmd-W, clicking outside, etc., on a manually-triggered
    /// re-run) when it hasn't otherwise called `markSeen()`. Idempotent with `markSeen()`.
    func dismiss() {
        isPresented = false
    }

    /// The `Binding` `SweepApp.swift`'s `.sheet(isPresented:)` is built from: SwiftUI needs a
    /// two-way binding for that modifier (it writes `false` back itself on an outside dismiss),
    /// but `isPresented`'s setter is intentionally `private(set)` everywhere else so no other
    /// call site can flip it without going through `presentManually()`/`markSeen()`/`dismiss()`
    /// and their own bookkeeping.
    func setPresented(_ presented: Bool) {
        if presented {
            presentManually()
        } else {
            dismiss()
        }
    }
}
