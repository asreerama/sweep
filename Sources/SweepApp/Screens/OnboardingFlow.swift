import SwiftUI
import SweepUI

/// First-run onboarding (PLAN §4 capability model + §5 design direction). Three steps — welcome,
/// Full Disk Access, menubar/Sentinel/login-item finish — presented as one continuous flow in one
/// window, not three separate screens: a persistent header (progress dots, Skip) and footer
/// (Back, the one primary action) never unmount, and only the content area swaps identity between
/// steps. Same treatment `RootView` already gives module-to-module navigation (PLAN §5: "crossfade
/// + slight vertical drift, never a hard swap") — this flow reuses that exact idiom rather than
/// inventing a second one, since it is the smallest amount of new choreography that still reads
/// as continuous rather than as a wizard slamming between pages.
///
/// Skippable at every step (the header's Skip button is part of the persistent chrome, so it is
/// never out of reach), and re-runnable from `SettingsView` — see `OnboardingLaunchState`.
struct OnboardingFlow: View {
    enum Step: Int, CaseIterable, Equatable {
        case welcome
        case fullDiskAccess
        case finish
    }

    enum Outcome {
        case finished
        case skipped
    }

    /// Called exactly once, however the flow ends. `SweepApp.swift` maps both outcomes onto
    /// `OnboardingLaunchState.markSeen()` — a skip counts as "seen" too, see that type's doc
    /// comment — and dismisses the sheet.
    var onComplete: (Outcome) -> Void

    @State private var step: Step
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `initialStep` is a debug/screenshot-only seam (PLAN §6: "UI work verified by screenshot,
    /// not assertion") — the real call site (`SweepApp.swift`) always relies on the default and
    /// starts at `.welcome`; `Debug/OnboardingSnapshotHarness.swift` is the only other caller,
    /// and only when `SWEEP_ONBOARDING_SNAPSHOTS` is set. Threading it through `init` rather than
    /// an `.onAppear` mutation means the harness gets a fresh, correctly-seeded `step` for every
    /// capture instead of racing a state write against the first frame.
    init(initialStep: Step = .welcome, onComplete: @escaping (Outcome) -> Void) {
        self._step = State(initialValue: initialStep)
        self.onComplete = onComplete
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content
                .id(step)
                .transition(.opacity.combined(with: .offset(y: 6)))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            footer
        }
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: step)
        .frame(width: 580, height: 640)
        .background(SweepTokens.ground)
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome:
            OnboardingWelcomeStep()
        case .fullDiskAccess:
            // Auto-advance (PLAN §4: "auto-advances when probe flips to available") — the step
            // itself owns the timing of the settle beat before calling back.
            OnboardingFullDiskAccessStep(onGranted: advance)
        case .finish:
            OnboardingFinishStep()
        }
    }

    // MARK: - Persistent chrome

    private var header: some View {
        HStack {
            progressDots
            Spacer()
            Button("Skip") { onComplete(.skipped) }
                .buttonStyle(.sweepQuiet)
                .accessibilityHint("Finishes onboarding without changing anything on this step.")
        }
        .padding(.horizontal, SweepTokens.s5)
        .padding(.top, SweepTokens.s4)
        .padding(.bottom, SweepTokens.s2)
    }

    private var progressDots: some View {
        HStack(spacing: SweepTokens.s2 - 2) {
            ForEach(Step.allCases, id: \.self) { candidate in
                Circle()
                    .fill(candidate.rawValue <= step.rawValue ? SweepTokens.accent : SweepTokens.hairline)
                    .frame(width: 6, height: 6)
            }
        }
        .animation(SweepMotion.row, value: step)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    private var footer: some View {
        HStack {
            if step != .welcome {
                Button {
                    back()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.sweepQuiet)
            }
            Spacer()
            Button(primaryLabel) { primaryAction() }
                .buttonStyle(.sweepPrimary(minWidth: 148))
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, SweepTokens.s5)
        .padding(.vertical, SweepTokens.s4)
    }

    private var primaryLabel: String {
        switch step {
        case .welcome, .fullDiskAccess: "Continue"
        case .finish: "Start Smart Scan"
        }
    }

    private func primaryAction() {
        switch step {
        case .welcome, .fullDiskAccess: advance()
        case .finish: onComplete(.finished)
        }
    }

    // MARK: - Step machine

    private func advance() {
        guard let next = Step(rawValue: step.rawValue + 1) else {
            onComplete(.finished)
            return
        }
        step = next
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }
}

#Preview("Onboarding") {
    OnboardingFlow(onComplete: { _ in })
}
