import SwiftUI
import SweepUI

/// Minimal Settings scene (PLAN §3 module 5): the SmartDelete watcher's one toggle, off by
/// default. Nothing else lives here yet — a settings surface for onboarding/FDA state arrives
/// with the P5 wave.
struct SettingsView: View {
    @Bindable private var settings = SentinelSettings.shared

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
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
    }
}
