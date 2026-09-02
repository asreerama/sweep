import SwiftUI
import SweepUI

/// Maintenance (module 8, PLAN §3): three privileged-adjacent operations as cards, each
/// preview-first — tapping "Run" always opens a sheet showing the exact command before anything
/// executes, the same discipline `HomebrewScreen`'s `BrewCommandPreviewSheet` uses for its own
/// mutations. Registration is lazy: nothing here calls into `SMAppService.register()` until the
/// user actually confirms a run that needs the helper (`MaintenanceModel.run`).
struct MaintenanceScreen: View {
    @State private var model = MaintenanceModel()
    @State private var pendingKind: MaintenanceOperationKind?

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: Destination.maintenance.title, subtitle: Destination.maintenance.subtitle)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: SweepTokens.s5) {
                    if MaintenanceHelperPresentation.showsBanner(for: model.helper.state) {
                        helperStatusSection
                    }
                    ForEach(MaintenanceOperationKind.allCases) { kind in
                        card(for: kind)
                    }
                }
                .padding(SweepTokens.s5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task { await model.onAppear() }
        .sheet(item: $pendingKind) { kind in
            MaintenancePreviewSheet(
                title: kind.title,
                commandText: model.previewText(for: kind),
                needsApprovalNote: !model.isHelperReady && !kind.hasUserLevelFallback,
                onCancel: { pendingKind = nil },
                onConfirm: {
                    pendingKind = nil
                    Task { await model.run(kind) }
                }
            )
        }
    }

    // MARK: - Helper status

    /// Shown for every state except the quiet common cases (`.notRegistered` before first use,
    /// `.ready` once connected) — an approval walkthrough while waiting, a plain refusal note when
    /// incompatible, a retry when something failed.
    private var helperStatusSection: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: SweepTokens.s3) {
                HStack(spacing: SweepTokens.s2 + 2) {
                    Image(systemName: helperStatusSymbol)
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(helperStatusIsBusy ? .secondary : SweepTokens.tierCaution)
                    Text(MaintenanceHelperPresentation.statusLine(for: model.helper.state))
                        .font(SweepFont.rowTitleEmphasis)
                        .foregroundStyle(.primary)
                    if helperStatusIsBusy {
                        ProgressView().controlSize(.small)
                    }
                    Spacer()
                }
                if case .requiresApproval = model.helper.state {
                    HStack(spacing: SweepTokens.s3) {
                        Button("Open Login Items Settings") { model.helper.openApprovalSettings() }
                            .buttonStyle(.sweepPrimary(minWidth: 0))
                        Button("I Approved It \u{2014} Check Again") {
                            Task { await model.helper.refreshFromCurrentStatus() }
                        }
                        .buttonStyle(.sweepQuiet)
                    }
                }
                if case .unavailable = model.helper.state {
                    Button("Try Again") { Task { await model.helper.requestAccess() } }
                        .buttonStyle(.sweepQuiet)
                }
            }
            .padding(SweepTokens.s4)
        }
    }

    private var helperStatusIsBusy: Bool {
        switch model.helper.state {
        case .registering, .handshaking: true
        default: false
        }
    }

    private var helperStatusSymbol: String {
        switch model.helper.state {
        case .requiresApproval: "lock.shield"
        case .incompatible: "exclamationmark.triangle"
        case .unavailable: "xmark.circle"
        default: "hourglass"
        }
    }

    // MARK: - Cards

    private func card(for kind: MaintenanceOperationKind) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: SweepTokens.s3) {
                HStack(alignment: .top, spacing: SweepTokens.s3) {
                    // Same icon-chip register as the Homebrew rows (scale v3): a bare 18 pt glyph
                    // next to a 16 pt title read as an afterthought; the chip gives each card the
                    // same visual anchor every other card surface in the app carries.
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(SweepTokens.accent.opacity(0.12))
                        .frame(width: 38, height: 38)
                        .overlay {
                            Image(systemName: kind.symbol)
                                .font(.system(size: 17, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(SweepTokens.accent)
                        }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(kind.title)
                            .font(SweepFont.sectionTitle)
                            .foregroundStyle(.primary)
                        Text(kind.explanation)
                            .font(SweepFont.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }

                controls(for: kind)

                Text(model.previewText(for: kind))
                    .font(SweepFont.monoSmall)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
                    .lineLimit(nil)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(SweepTokens.s3)
                    .background {
                        RoundedRectangle(cornerRadius: SweepTokens.rowRadius, style: .continuous)
                            .fill(SweepTokens.ground)
                    }

                HStack(spacing: SweepTokens.s3) {
                    Button(runButtonTitle(for: kind)) { pendingKind = kind }
                        .buttonStyle(.sweepQuiet)
                        .disabled(model.runState(for: kind) == .running)
                    statusView(for: kind)
                    Spacer()
                }
            }
            .padding(SweepTokens.s4)
        }
    }

    private func runButtonTitle(for kind: MaintenanceOperationKind) -> String {
        if !model.isHelperReady, !kind.hasUserLevelFallback {
            return "Preview\u{2026}"
        }
        return "Run\u{2026}"
    }

    @ViewBuilder
    private func controls(for kind: MaintenanceOperationKind) -> some View {
        switch kind {
        case .flushDNS:
            EmptyView()
        case .reindexSpotlight:
            if model.volumeOptions.isEmpty {
                Footnote("No mounted volumes were readable.", symbol: "externaldrive")
            } else {
                Picker("Volume", selection: $model.selectedVolumePath) {
                    ForEach(model.volumeOptions) { option in
                        Text(option.displayName).tag(option.id)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 220, alignment: .leading)
            }
        case .thinSnapshots:
            Picker("Urgency", selection: $model.selectedUrgency) {
                ForEach(MaintenanceUrgencyLevel.allCases) { level in
                    Text(level.label).tag(level.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 320)
        }
    }

    @ViewBuilder
    private func statusView(for kind: MaintenanceOperationKind) -> some View {
        switch model.runState(for: kind) {
        case .idle:
            EmptyView()
        case .running:
            ProgressView().controlSize(.small)
        case .succeeded(let detail):
            Footnote(firstLine(of: detail), symbol: "checkmark.circle")
        case .failed(let reason):
            Label {
                Text(firstLine(of: reason)).font(SweepFont.caption)
            } icon: {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 13))
            }
            .foregroundStyle(SweepTokens.tierExpert)
        }
    }

    private func firstLine(of text: String) -> String {
        text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
    }
}

/// Preview-first confirmation, shared by every card — mirrors `HomebrewScreen`'s
/// `BrewCommandPreviewSheet`: nothing runs until "Confirm" is pressed, and the exact command is
/// always on screen before that happens.
private struct MaintenancePreviewSheet: View {
    let title: String
    let commandText: String
    let needsApprovalNote: Bool
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SweepTokens.s1 + 2) {
                // Dialog register (scale v3): sheets speak `sectionTitle`, never the 28 pt
                // screen title — same decision as `CleanConfirmSheet`.
                Text(title)
                    .font(SweepFont.sectionTitle)
                    .foregroundStyle(.primary)
                Text("Preview \u{2014} nothing runs until you confirm.")
                    .font(SweepFont.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.top, SweepTokens.s5)
            .padding(.bottom, SweepTokens.s4)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SweepTokens.s3) {
                    Text(commandText)
                        .font(SweepFont.mono)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if needsApprovalNote {
                        Footnote(
                            "This confirms first, then asks for one-time approval in Login Items if it hasn\u{2019}t been granted yet.",
                            symbol: "lock.shield"
                        )
                    }
                }
                .padding(SweepTokens.s4)
            }
            .frame(maxHeight: 220)
            .background(SweepTokens.ground)

            Divider()
            HStack(spacing: SweepTokens.s3) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .buttonStyle(.sweepQuiet)
                    .keyboardShortcut(.cancelAction)
                Button("Confirm", action: onConfirm)
                    .buttonStyle(.sweepPrimary(minWidth: 108))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(SweepTokens.s5)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
    }
}
