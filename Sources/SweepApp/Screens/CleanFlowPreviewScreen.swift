import SwiftUI
import SweepUI

/// Debug harness, reachable only when `SWEEP_UI_STRESS` is set (same gate as `ListStressScreen`).
///
/// The Clean flow's confirm/progress/report states only ever appear behind `CleanAdapter.isEnabled`
/// (false until Fable flips Gate 1), so there is no path through the shipping UI that reaches them
/// today. This renders the same `SweepUI` views — `CleanConfirmSheet`, `CleanProgressState`,
/// `CleanReportState` — against synthetic data, so the flow can be reviewed and screenshotted
/// ahead of the flip rather than asserted to work from reading the component source.
enum CleanFlowPreviewPhase: String, CaseIterable, Identifiable {
    case confirm
    case running
    case reportClean
    case reportWithFailures
    case failed

    var id: String { rawValue }

    var label: String {
        switch self {
        case .confirm: "Confirm"
        case .running: "Progress"
        case .reportClean: "Report"
        case .reportWithFailures: "Report (failures)"
        case .failed: "Failed"
        }
    }
}

struct CleanFlowPreviewScreen: View {
    @Binding var phase: CleanFlowPreviewPhase

    private let summary = CleanRequestSummary(
        itemCount: 18_204,
        totalBytes: 9_810_000_000,
        volumes: [
            CleanVolume(id: "1", name: "Macintosh HD", itemCount: 18_190, byteCount: 9_760_000_000),
            CleanVolume(id: "2", name: "DevSSD", itemCount: 14, byteCount: 50_000_000),
        ]
    )

    private let progress = CleanProgressUpdate(
        remainingBytes: 3_400_000_000,
        remainingItems: 6_120,
        currentItemCaption: "~/Library/Caches/Google/Chrome/Default/Cache_Data/f_0002a1"
    )

    private let cleanReport = CleanReport(freedBytes: 9_760_000_000, succeededCount: 18_190, outcomes: [])

    private let reportWithFailures = CleanReport(
        freedBytes: 9_200_000_000,
        succeededCount: 18_150,
        outcomes: [
            CleanItemOutcome(
                id: "1", title: "com.example.LockedCache", byteCount: 482_000_000,
                status: .failed(reason: "In use by a running app")
            ),
            CleanItemOutcome(
                id: "2", title: "18.4 (22E240)", byteCount: 3_120_000_000,
                status: .failed(reason: "Changed since scan; skipped for safety")
            ),
        ]
    )

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                title: Destination.cleanFlowPreview.title,
                subtitle: Destination.cleanFlowPreview.subtitle
            ) {
                Picker("", selection: $phase) {
                    ForEach(CleanFlowPreviewPhase.allCases) { phase in
                        Text(phase.label).tag(phase)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 420)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(SweepTokens.ground)
            Footnote(
                "Debug-only: the real flow starts from Smart Scan / System Junk once CleanAdapter.isEnabled flips.",
                symbol: "hand.raised"
            )
            .padding(SweepTokens.s4)
        }
    }

    @ViewBuilder
    private var content: some View {
        // Every case gets the same symmetric-spacer centering: a plain `.frame(alignment:)` on a
        // `.fixedSize` (or otherwise self-sizing) child measured badly here — this debug screen
        // swaps totally different view types under one Picker, and that combination is not how
        // the real flow ever hosts these views (a native `.sheet()` negotiates the confirm
        // sheet's size directly with AppKit). Spacers on both sides is the more robust pattern
        // for "center this, however tall it turns out to be" in a plain VStack.
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            switch phase {
            case .confirm:
                CleanConfirmSheet(summary: summary, onCancel: {}, onClean: {})
            case .running:
                CleanProgressState(update: progress, totalBytes: summary.totalBytes)
            case .reportClean:
                CleanReportState(report: cleanReport, onDone: {})
                    .frame(width: 460, height: 480)
            case .reportWithFailures:
                CleanReportState(report: reportWithFailures, onDone: {})
                    .frame(width: 460, height: 480)
            case .failed:
                VStack(spacing: SweepTokens.s4) {
                    InventoryEmptyState(
                        symbol: "exclamationmark.triangle",
                        title: "Clean could not finish",
                        message: "Gate 1 has not been opened in this build; live cleaning is disabled."
                    )
                    Button("Done") {}.buttonStyle(.sweepQuiet)
                }
                .padding(SweepTokens.s5)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
