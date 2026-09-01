import Foundation
import Observation

/// The SmartDelete watcher's one setting (PLAN §3 module 5: "Toggle in a minimal Settings scene
/// ... off by default"). A single `UserDefaults` boolean — one setting does not earn a store of
/// its own.
@MainActor
@Observable
final class SentinelSettings {
    static let shared = SentinelSettings()

    private static let key = "SweepSmartDeleteWatcherEnabled"

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.key)
            apply()
        }
    }

    private init() {
        // `bool(forKey:)` defaults to `false` for a key that has never been set — off by default,
        // with no separate "has this ever been configured" bit needed.
        isEnabled = UserDefaults.standard.bool(forKey: Self.key)
    }

    /// Starts or stops `TrashSentinel` to match the persisted setting. Called once at launch and
    /// again on every toggle.
    func apply() {
        if isEnabled {
            TrashSentinel.shared.start()
        } else {
            TrashSentinel.shared.stop()
        }
    }
}
