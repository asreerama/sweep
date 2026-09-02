import SwiftUI
import SweepUI

/// Onboarding step 3 (PLAN §4/§5 task): the SmartDelete watcher toggle, a "launch at login"
/// toggle, and the standalone menu bar app toggle — all three reusing an existing settings model
/// rather than a copy of its logic (`SentinelSettings`, `LoginItemControl`,
/// `MenuBarLoginItemSettings`, the last of which is also `SettingsView`'s own menu-bar row).
/// Finishing lands in Smart Scan, which is already `AppState.destination`'s default value, so the
/// flow's own completion callback has nothing left to set — see `Screens/OnboardingFlow.swift`.
struct OnboardingFinishStep: View {
    @Bindable private var sentinel = SentinelSettings.shared
    @Bindable private var menuBarLoginItem = MenuBarLoginItemSettings.shared

    @State private var loginItemEnabled = LoginItemControl.isEnabled()
    @State private var loginItemNeedsApproval = LoginItemControl.requiresApproval()
    @State private var loginItemError: String?

    var body: some View {
        VStack(spacing: SweepTokens.s5) {
            Spacer(minLength: SweepTokens.s2)

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SweepTokens.accent.gradient)
                    .frame(width: 72, height: 72)
                Image(systemName: "checkmark")
                    .font(.system(size: 32, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .shadow(color: SweepTokens.accent.opacity(0.28), radius: 16, y: 8)

            VStack(spacing: SweepTokens.s2) {
                Text("You're set up")
                    .font(.system(size: 24, weight: .semibold))
                Text("A couple of optional conveniences, then straight into Smart Scan.")
                    .font(SweepFont.screenSubtitle)
                    .foregroundStyle(.secondary)
            }

            SectionCard {
                VStack(alignment: .leading, spacing: 0) {
                    optionRow(
                        symbol: "trash",
                        title: "Offer cleanup on app removal",
                        detail: "When a .app lands in the Trash, show a quiet panel offering to open the Uninstaller with its leftovers ready to review."
                    ) {
                        Toggle("", isOn: $sentinel.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider().padding(.leading, SweepTokens.s3 + 22 + SweepTokens.s3)

                    optionRow(
                        symbol: "arrow.up.forward.app",
                        title: "Launch Sweep at login",
                        detail: loginItemDetail
                    ) {
                        Toggle("", isOn: loginItemBinding)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }

                    Divider().padding(.leading, SweepTokens.s3 + 22 + SweepTokens.s3)

                    // Menu-app toggle (PLAN task: "a menu-app toggle placeholder note if the
                    // SweepMenu target isn't merged yet" — it now is, see
                    // `Sentinel/MenuBarLoginItemSettings.swift`, so this reuses that real toggle
                    // rather than a placeholder note).
                    optionRow(
                        symbol: "menubar.rectangle",
                        title: "Run the menu bar app on its own",
                        detail: "A separate, lighter-weight process for the menu bar stats, launching at login independent of Sweep itself. Status: \(menuBarLoginItem.statusDescription)."
                    ) {
                        Toggle("", isOn: $menuBarLoginItem.isEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                    }
                }
                .padding(.vertical, SweepTokens.s2)
            }
            .frame(maxWidth: 440)

            if let loginItemError {
                Footnote(loginItemError, symbol: "exclamationmark.triangle")
                    .frame(maxWidth: 440)
            } else if loginItemNeedsApproval {
                Footnote(
                    "Approve Sweep in System Settings \u{2192} General \u{2192} Login Items to finish turning this on.",
                    symbol: "info.circle"
                )
                .frame(maxWidth: 440)
            }

            Spacer(minLength: SweepTokens.s2)
        }
        .padding(.horizontal, SweepTokens.s6)
        .frame(maxWidth: .infinity)
        // Same call `SettingsView` makes on its own appear: reflects whatever `SMAppService`
        // already knows without registering/unregistering anything.
        .task { menuBarLoginItem.refreshStatus() }
    }

    private var loginItemDetail: String {
        "Opens Sweep automatically when you log in, in the background."
    }

    private var loginItemBinding: Binding<Bool> {
        Binding(
            get: { loginItemEnabled },
            set: { newValue in setLoginItem(newValue) }
        )
    }

    private func setLoginItem(_ enabled: Bool) {
        loginItemError = nil
        do {
            try LoginItemControl.setEnabled(enabled)
            loginItemEnabled = LoginItemControl.isEnabled()
            loginItemNeedsApproval = LoginItemControl.requiresApproval()
        } catch {
            loginItemError = "Couldn\u{2019}t change this: \(error.localizedDescription)"
            loginItemEnabled = LoginItemControl.isEnabled()
        }
    }

    @ViewBuilder
    private func optionRow<Control: View>(
        symbol: String, title: String, detail: String, @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(alignment: .top, spacing: SweepTokens.s3) {
            Image(systemName: symbol)
                .font(SweepFont.caption)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 22, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SweepFont.rowTitleEmphasis)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(SweepFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: SweepTokens.s3)
            control()
                .padding(.top, 1)
        }
        .padding(.horizontal, SweepTokens.s3)
        .padding(.vertical, SweepTokens.s3 - 2)
    }
}

#Preview("Finish") {
    OnboardingFinishStep()
        .frame(width: 560, height: 560)
        .background(SweepTokens.ground)
}
