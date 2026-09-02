import SwiftUI
import SweepUI

/// Developer (module 10, PLAN §3): the rule catalog's `developer` group, relensed per environment.
///
/// Toolbox contract (PLAN §3 IA): nothing is ever preselected, this screen never feeds Smart
/// Scan, and Clean runs through the identical `CleanAdapter`/`CleanFlowContainer` path System
/// Junk uses (Gate 1). Its own `DeveloperScanModel` — not the shared `ScanModel` — is what keeps
/// the "never appear in Smart Scan" half of that contract true by construction.
struct DeveloperScreen: View {
    @State private var model = DeveloperScanModel()

    @State private var query = ""
    @State private var expansion = InventoryExpansion()
    /// Non-nil while the Clean flow's sheet is up — built fresh per press, same reasoning as
    /// `SystemJunkScreen.cleanFlow`.
    @State private var cleanFlow: CleanFlowModel?

    private var visibleGroups: [InventoryGroup] {
        InventoryAggregate.filter(model.environmentGroups, query: query)
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ScreenHeader(
                title: Destination.developer.title,
                subtitle: Destination.developer.subtitle
            ) {
                HStack(spacing: SweepTokens.s2) {
                    if !model.environmentGroups.isEmpty {
                        SweepSearchField(text: $query, prompt: "Filter environments")
                            .frame(width: 240)
                    }
                    if model.isScanning {
                        Button("Stop") { model.cancel() }.buttonStyle(.sweepQuiet)
                    } else {
                        Button(model.phase == .idle ? "Scan" : "Rescan") { model.rescan() }
                            .buttonStyle(.sweepQuiet)
                    }
                }
            }

            Divider()

            body(for: $model)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .onAppear { expansion = .initial(for: model.environmentGroups) }
        .onChange(of: model.environmentGroups) { _, newValue in expansion = .initial(for: newValue) }
        .onDisappear { model.cancel() }
        // Debug-only opt-in (mirrors `SWEEP_UI_STRESS`/`SWEEP_HOME`): lets a screenshot/QA run
        // show populated results without changing the shipped screen's manual "Scan" default —
        // every real launch of Sweep starts this module idle, exactly like System Junk.
        .task {
            guard model.phase == .idle,
                  ProcessInfo.processInfo.environment["SWEEP_TOOLBOX_AUTOSCAN"] != nil
            else { return }
            model.start()
        }
    }

    @ViewBuilder
    private func body(for model: Bindable<DeveloperScanModel>) -> some View {
        switch self.model.phase {
        case .idle:
            InventoryEmptyState(
                symbol: "hammer",
                title: "Ready when you are",
                message: "Scans your installed developer tools — Xcode-adjacent caches live in "
                    + "System Junk; this is npm, JetBrains, editors, Gradle and friends."
            )
        case .scanning:
            scanningState
        case .failed(let message):
            InventoryEmptyState(symbol: "exclamationmark.triangle", title: "Scan could not start", message: message)
        case .results:
            if visibleGroups.isEmpty {
                InventoryEmptyState(
                    symbol: query.isEmpty ? "checkmark.circle" : "magnifyingglass",
                    title: query.isEmpty ? "No developer caches found" : "No matches",
                    message: query.isEmpty
                        ? "Nothing under the developer tools this build knows about needs cleaning."
                        : "Nothing in the results matches \u{201C}\(query)\u{201D}."
                )
            } else {
                InventoryList(groups: visibleGroups, selection: model.selection, expansion: $expansion)
            }
        }
    }

    private var scanningState: some View {
        VStack(spacing: SweepTokens.s5) {
            ScanRing(state: .scanning, diameter: SweepTokens.moduleRingDiameter) {
                HeroByteCounter(byteCount: model.claimedBytes, size: SweepTokens.moduleRingCounterSize)
            }
            Text(model.scanningCaption)
                .font(SweepFont.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            PathTicker(path: model.currentPath, width: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: SweepTokens.s3) {
                Button("Clean") { startClean() }
                    .buttonStyle(.sweepPrimary(minWidth: 108))
                    .disabled(!CleanAdapter.isEnabled || model.selection.selectedCount(in: model.environmentGroups) == 0)
                    .help(CleanAdapter.isEnabled ? "Move the selected items to Trash" : "Cleaning arrives at Gate 1")
                    .accessibilityHint(CleanAdapter.isEnabled ? "" : "Disabled. Cleaning arrives at Gate 1.")
                if !CleanAdapter.isEnabled {
                    GateNotice("Cleaning arrives at Gate 1")
                }
                Spacer(minLength: SweepTokens.s3)
                if model.phase == .results, !model.environmentGroups.isEmpty {
                    Text(selectionSummary)
                        .font(SweepFont.mono)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.vertical, SweepTokens.s3)
            if let note = model.skippedSummary, model.phase == .results {
                Footnote(note, symbol: "info.circle")
                    .padding(.horizontal, SweepTokens.s5)
                    .padding(.bottom, SweepTokens.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.bar)
        .sheet(isPresented: Binding(get: { cleanFlow != nil }, set: { if !$0 { cleanFlow = nil } })) {
            if let cleanFlow {
                CleanFlowContainer(model: cleanFlow, onRescan: { model.rescan() }) { self.cleanFlow = nil }
            }
        }
    }

    private func startClean() {
        let (summary, items) = model.developerCleanRequest()
        guard let context = model.cleanExecutionContext() else { return }
        cleanFlow = CleanFlowModel(
            requestSummary: summary,
            itemIDs: Set(items.map(\.id)),
            backend: CleanAdapter(context: context, items: items)
        )
    }

    private var selectionSummary: String {
        let groups = model.environmentGroups
        let selected = model.selection.selectedCount(in: groups)
        let total = InventoryAggregate.totalItems(groups)
        let bytes = SweepFormat.bytes(model.selection.selectedBytes(in: groups))
        return "\(SweepFormat.count(selected)) of \(SweepFormat.count(total)) selected \u{00B7} \(bytes)"
    }
}
