import AppKit
import Foundation
import Observation
import ServiceManagement

/// `SweepMenu`'s bundle identifier (PLAN §3 module 7, the P4-B split). Pinned here and, separately,
/// in `MenuBarHandoffLogic` (Shell/MenuBarStats.swift) — two literals rather than one shared
/// constant because the two live in different concerns (hand-off detection vs. login-item
/// registration) that happen to agree on the same string; `scripts/build-menu.sh`'s
/// `CFBundleIdentifier` is the one place that actually has to match both, and each file's own test
/// pins its copy against drifting from it.
enum MenuBarLoginItemIdentity {
    static let bundleIdentifier = "com.aditya.sweep.menu"
}

/// Everything `MenuBarLoginItemSettings` needs from `SMAppService`, behind a protocol so tests can
/// script status/registration outcomes without a real login-item helper embedded in this build —
/// same shape `Maintenance/HelperClient.swift`'s `HelperServiceControlling` already uses for the
/// privileged helper's own `SMAppService.daemon`.
protocol MenuBarLoginItemControlling: Sendable {
    func currentStatus() -> SMAppService.Status
    func register() throws
    func unregister() throws
}

/// `SMAppService.loginItem(identifier:)` — distinct from `Onboarding/LoginItemControl.swift`'s
/// `SMAppService.mainApp` (which launches Sweep itself at login): this registers the *embedded*
/// helper app at `Sweep.app/Contents/Library/LoginItems/Sweep Menu.app` (put there by
/// `scripts/build-menu.sh`, which also re-signs the outer bundle afterward — nested items must be
/// signed before the bundle that contains them is sealed) so the standalone `SweepMenu` process
/// can launch on its own, independent of whether the main app is running.
struct SMAppServiceMenuBarLoginItemControl: MenuBarLoginItemControlling, @unchecked Sendable {
    private let service = SMAppService.loginItem(identifier: MenuBarLoginItemIdentity.bundleIdentifier)

    func currentStatus() -> SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func unregister() throws { try service.unregister() }
}

/// Settings' menu-bar-app toggle (PLAN §3 module 7 task 3), off by default, beside
/// `SentinelSettings`'s SmartDelete one. Registers/unregisters `SweepMenu` as a login item on
/// toggle, and — since a login item can already be running from a previous login when the user
/// turns it off — terminates the live process too: `MenuBarHandoff` (Shell/MenuBarStats.swift)
/// only ever hands the in-app menubar *back*, it never reaches out and quits the standalone one.
@MainActor
@Observable
final class MenuBarLoginItemSettings {
    static let shared = MenuBarLoginItemSettings()

    private static let key = "SweepMenuBarLoginItemEnabled"

    private(set) var status: SMAppService.Status = .notRegistered

    var isEnabled: Bool {
        didSet {
            guard oldValue != isEnabled else { return }
            defaults.set(isEnabled, forKey: Self.key)
            apply()
        }
    }

    private let service: any MenuBarLoginItemControlling
    private let terminateRunningMenuApp: @Sendable () -> Void

    /// `service`/`terminateRunningMenuApp`/`defaults` are injectable so tests can script
    /// registration outcomes and observe the terminate call without a real login item or a live
    /// `NSRunningApplication` (`MenuBarLoginItemSettingsTests`).
    init(
        service: any MenuBarLoginItemControlling = SMAppServiceMenuBarLoginItemControl(),
        terminateRunningMenuApp: @escaping @Sendable () -> Void = MenuBarLoginItemSettings.terminateLiveMenuApp,
        defaults: UserDefaults = .standard
    ) {
        self.service = service
        self.terminateRunningMenuApp = terminateRunningMenuApp
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: Self.key)
        status = service.currentStatus()
    }

    private let defaults: UserDefaults

    /// Reflects whatever `SMAppService` already knows (a prior session's approval, a since-revoked
    /// one) without registering/unregistering anything — safe to call on every Settings appearance.
    func refreshStatus() {
        status = service.currentStatus()
    }

    /// Human-readable status, reusing `StartupItemsScreen.swift`'s own `SMAppService.Status`
    /// mapping (`SMAppServiceInventory.describe`) rather than a second copy of the same four cases.
    var statusDescription: String {
        SMAppServiceInventory.describe(status)
    }

    private func apply() {
        do {
            if isEnabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // Registration/unregistration failures (already-registered, approval revoked
            // mid-session, launchd hiccups) are surfaced only as a stale `status` read below —
            // there is no dedicated error row here the way `OnboardingFinishStep` has one, since
            // this toggle's own `statusDescription` already reflects reality on every refresh.
        }
        if !isEnabled {
            terminateRunningMenuApp()
        }
        refreshStatus()
    }

    nonisolated static func terminateLiveMenuApp() {
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: MenuBarLoginItemIdentity.bundleIdentifier) {
            app.terminate()
        }
    }
}
