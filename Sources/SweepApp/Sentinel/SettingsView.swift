import AppKit
import SwiftUI
import SweepUI

/// Minimal Settings scene (PLAN §3 module 5): the SmartDelete watcher's one toggle, off by
/// default, plus onboarding's re-entry point (PLAN §4/§5 task: "re-runnable from Settings").
struct SettingsView: View {
    @Bindable private var settings = SentinelSettings.shared
    @Bindable private var menuBarLoginItem = MenuBarLoginItemSettings.shared

    var body: some View {
        Form {
            Section {
                Toggle("Offer to clean up leftovers when an app is moved to the Trash", isOn: $settings.isEnabled)
                Text("Watches \u{7E}/.Trash. When a .app lands there, Sweep shows a quiet panel offering to open the Uninstaller with that app's leftovers ready to review \u{2014} nothing is ever deleted from the offer itself.")
                    .font(SweepFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("SmartDelete")
            }

            Section {
                Toggle("Run the menu bar app on its own (separate, lighter-weight process)", isOn: $menuBarLoginItem.isEnabled)
                Text("Sweep's menu bar stats normally run inside Sweep itself. Turning this on registers a small standalone menu bar app that launches at login and keeps showing stats even when Sweep is closed \u{2014} Sweep's own menu bar item steps aside automatically while it's running. Status: \(menuBarLoginItem.statusDescription).")
                    .font(SweepFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Menu Bar")
            }

            Section {
                Button("Show Onboarding Again\u{2026}") { showOnboardingAgain() }
                Text("Replays the welcome, Full Disk Access, and menu bar/login-item steps shown on first launch.")
                    .font(SweepFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Onboarding")
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
        .task { menuBarLoginItem.refreshStatus() }
    }

    /// `OnboardingLaunchState.shared` is the same singleton the main window's `.sheet` binds to
    /// (`SweepApp.swift`) — flipping `isPresented` here is observed there directly. Bringing the
    /// main window forward first is what actually makes the sheet visible: if it is closed (or
    /// merely behind Settings), toggling the flag alone would leave the sheet attached to a
    /// window nothing is looking at. Window selection mirrors `SnapshotHarness.mainWindow()`
    /// exactly (largest titled window) rather than matching on `id`/`identifier`, since that is
    /// this codebase's already-proven way to pick "the main window" out of a window list that
    /// also contains this very Settings window.
    private func showOnboardingAgain() {
        OnboardingLaunchState.shared.presentManually()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows
            .filter { $0.styleMask.contains(.titled) }
            .max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }?
            .makeKeyAndOrderFront(nil)
    }
}
