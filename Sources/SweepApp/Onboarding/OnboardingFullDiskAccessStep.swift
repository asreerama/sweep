import AppKit
import SwiftUI
import SweepSystem
import SweepUI

/// Onboarding step 2 (PLAN §4): Full Disk Access. Plain-language why, the honest "safe modules
/// work without it" line, a live status chip driven by `CapabilityStore`, the System Settings
/// deep link with a manual-path fallback printed underneath it (PLAN §4: "manual System Settings
/// fallback if deep link breaks" — since a broken deep link fails silently from this process's
/// point of view, the fallback text is always shown rather than only after a detected failure),
/// and an auto-advance the moment the capability model actually flips to `.available`.
struct OnboardingFullDiskAccessStep: View {
    /// Called once, the first time the live status settles on `.available` while this step is on
    /// screen. Not called for a status this step merely inherits already-`.available` on
    /// appear — see `body`'s `onAppear` — so re-opening onboarding after FDA was already granted
    /// long ago does not immediately yank the user to step 3 before they can read the screen.
    var onGranted: () -> Void

    @State private var store = CapabilityStore.shared
    @State private var hasAppeared = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: CapabilityStatus { store.status(for: .fullDiskAccess) }

    var body: some View {
        VStack(spacing: SweepTokens.s5) {
            Spacer(minLength: SweepTokens.s2)

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SweepTokens.accent.opacity(0.14))
                    .frame(width: 72, height: 72)
                Image(systemName: "lock.shield")
                    .font(.system(size: 32, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(SweepTokens.accent)
            }

            VStack(spacing: SweepTokens.s2) {
                Text("Full Disk Access")
                    .font(.system(size: 24, weight: .semibold))
                Text("Some of what Sweep can find — Mail, Time Machine, other apps' containers — lives in places macOS protects by default.")
                    .font(SweepFont.screenSubtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 420)

            // The honest line (PLAN §4, verbatim requirement): granting this is not a
            // precondition to use Sweep at all.
            Footnote(
                "Safe modules work without this. Granting it just lets Sweep see everything, not just what any app can already read.",
                symbol: "checkmark.shield"
            )
            .frame(maxWidth: 420)
            .multilineTextAlignment(.leading)

            CapabilityStatusChip(status: status, isRefreshing: store.isRefreshing)

            VStack(spacing: SweepTokens.s2) {
                Button("Open System Settings") { openSystemSettings() }
                    .buttonStyle(.sweepPrimary(minWidth: 200))

                Button("Check again") { Task { await store.refresh() } }
                    .buttonStyle(.sweepQuiet)
                    .opacity(status == .available ? 0 : 1)
                    .disabled(status == .available)

                // Manual fallback (PLAN §4): shown unconditionally, since a broken deep link
                // fails open — this process has no reliable way to detect that System Settings
                // landed on the wrong pane, or failed to open at all.
                Text("If that doesn't open the right pane: System Settings \u{2192} Privacy & Security \u{2192} Full Disk Access, then enable Sweep.")
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
                    .padding(.top, SweepTokens.s1)
            }

            Spacer(minLength: SweepTokens.s2)
        }
        .padding(.horizontal, SweepTokens.s6)
        .frame(maxWidth: .infinity)
        .task {
            store.start()
            await store.refresh()
            // The very first reading this step ever sees does not count as "just granted" — only
            // a later flip does (see `onGranted`'s doc comment).
            hasAppeared = true
        }
        .onChange(of: status) { previous, current in
            guard hasAppeared, previous != .available, current == .available else { return }
            Task {
                // A short, visible beat on the settled "Granted" chip (PLAN §5: motion should be
                // interruptible and legible, never an instant cut) before the flow advances on
                // its own.
                try? await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 700))
                onGranted()
            }
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
    }
}

#Preview("Full Disk Access") {
    OnboardingFullDiskAccessStep(onGranted: {})
        .frame(width: 560, height: 560)
        .background(SweepTokens.ground)
}
