import SwiftUI
import SweepUI

/// Onboarding step 1 (PLAN §4/§5 task): what Sweep is, what it never touches, the trash-first
/// promise. No controls beyond the flow's own persistent Continue/Skip chrome — this step is
/// entirely plain-language reassurance, on purpose, before step 2 asks for anything.
struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: SweepTokens.s5) {
            Spacer(minLength: SweepTokens.s3)

            // Brand mark: the same "wind" glyph the menubar item and Dock icon already carry
            // (`MenuBarStats`, `SweepApp.swift`'s `MenuBarExtra`), badged the way `ModuleIcon`
            // badges every module symbol — one recognizable identity, not a new one invented for
            // this screen alone.
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(SweepTokens.accent.gradient)
                    .frame(width: 72, height: 72)
                Image(systemName: "wind")
                    .font(.system(size: 34, weight: .medium))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white)
            }
            .shadow(color: SweepTokens.accent.opacity(0.28), radius: 16, y: 8)

            VStack(spacing: SweepTokens.s2) {
                Text("Welcome to Sweep")
                    .font(.system(size: 24, weight: .semibold))
                Text("An instrument for keeping your Mac clean, not a black box that guesses.")
                    .font(SweepFont.screenSubtitle)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            OnboardingFactRow(
                symbol: "trash",
                title: "Trash first, always",
                detail: "Sweep moves things to the Trash and shows you what it found before anything leaves your Mac. Nothing is deleted outright."
            )
            OnboardingFactRow(
                symbol: "hand.raised",
                title: "Never your files",
                detail: "Documents, Photos, and anything synced to iCloud or another cloud drive are outside every rule Sweep scans with — not hidden behind a setting, never touched at all."
            )
            OnboardingFactRow(
                symbol: "eye",
                title: "Nothing runs unreviewed",
                detail: "Every scan is read-only until you press Clean. You always see the full list before it moves anywhere."
            )

            Spacer(minLength: SweepTokens.s3)
        }
        .padding(.horizontal, SweepTokens.s6)
        .frame(maxWidth: .infinity)
    }
}

/// One plain-language reassurance line: symbol, a short title, one sentence of detail. Reused
/// across onboarding rather than the module screens' `InventoryRow`/`GroupHeader` — those carry
/// selection/size/tier machinery this step has no use for.
struct OnboardingFactRow: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: SweepTokens.s3) {
            Image(systemName: symbol)
                .font(.system(size: 16, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(SweepTokens.accent)
                .frame(width: 22, height: 22)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(SweepFont.rowTitleEmphasis)
                    .foregroundStyle(.primary)
                Text(detail)
                    .font(SweepFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("Welcome") {
    OnboardingWelcomeStep()
        .frame(width: 560, height: 520)
        .background(SweepTokens.ground)
}
