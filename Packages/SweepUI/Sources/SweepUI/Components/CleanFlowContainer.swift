import SwiftUI

/// Hosts one ``CleanFlowModel`` through confirm → running → report, as the content of a sheet.
///
/// The phase switch is one `.animation(_:value:)` on `model.phase`, the same state-driven
/// pattern `SmartScanScreen` uses for idle → scanning → results: no `withAnimation` chain across
/// the transition, so a state arriving mid-transition retargets it instead of queuing behind it.
/// Reduce Motion drops straight to a crossfade.
public struct CleanFlowContainer: View {
    private let model: CleanFlowModel
    private let onDismiss: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(model: CleanFlowModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
    }

    public var body: some View {
        Group {
            switch model.phase {
            case .confirm(let summary):
                CleanConfirmSheet(
                    summary: summary,
                    onCancel: onDismiss,
                    onClean: { model.confirmClean() }
                )
            case .running(let update):
                CleanProgressState(update: update, totalBytes: model.requestSummary.totalBytes)
                    .frame(width: 420, height: 420)
            case .report(let report):
                // Width only, height content-driven: a clean report is short (hero + one
                // footnote line) and a fixed height here used to leave it stranded in a 300 pt
                // blank middle. `CleanReportState` caps its own failure list's `ScrollView`, so
                // this never grows unbounded when a report does have a long failure list.
                CleanReportState(
                    report: report,
                    onDone: onDismiss,
                    canRetry: model.isBackendEnabled,
                    onRetry: { model.retryFailed() }
                )
                .frame(width: 460)
                .fixedSize(horizontal: false, vertical: true)
            case .failed(let message):
                failure(message)
                    .frame(width: 420, height: 320)
            }
        }
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: phaseTag)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: SweepTokens.s4) {
            InventoryEmptyState(symbol: "exclamationmark.triangle", title: "Clean could not finish", message: message)
            Button("Done", action: onDismiss)
                .buttonStyle(.sweepQuiet)
        }
        .padding(SweepTokens.s5)
    }

    /// `CleanFlowPhase` carries payloads, so it cannot be `Equatable` cheaply enough to hand
    /// straight to `.animation(value:)`; this is the discriminator the transition actually keys
    /// off, which is what "retargetable" means for a phase switch — the identity, not the data.
    private var phaseTag: Int {
        switch model.phase {
        case .confirm: 0
        case .running: 1
        case .report: 2
        case .failed: 3
        }
    }
}
