import SwiftUI

/// The Clean flow's final state: what freed, what did not go as planned, and how to get it back.
public struct CleanReportState: View {
    private let report: CleanReport
    private let onDone: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    public init(report: CleanReport, onDone: @escaping () -> Void) {
        self.report = report
        self.onDone = onDone
    }

    public var body: some View {
        VStack(spacing: 0) {
            ScrollView(.vertical) {
                VStack(spacing: SweepTokens.s5) {
                    VStack(spacing: SweepTokens.s2) {
                        Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 30, weight: .light))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(report.failures.isEmpty ? SweepTokens.accent : SweepTokens.tierCaution)
                            .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : appeared)
                        HeroByteCounter(
                            byteCount: report.freedBytes,
                            size: 44,
                            label: "Freed",
                            caption: SweepFormat.itemCount(report.succeededCount)
                        )
                    }
                    .padding(.top, SweepTokens.s5)
                    .padding(.bottom, SweepTokens.s3)
                    .frame(maxWidth: .infinity)
                    .background {
                        // Soft accent wash (PLAN §5 volume-raise): a success report reads warmer
                        // than a bare white card without becoming a colored screen — the wash
                        // fades out entirely for a report with failures, since amber stays
                        // reserved for the tier-badge system and must never look decorative here.
                        if report.failures.isEmpty {
                            RadialGradient(
                                colors: [SweepTokens.accent.opacity(0.16), SweepTokens.accent.opacity(0)],
                                center: .center, startRadius: 0, endRadius: 160
                            )
                        }
                    }
                    .onAppear { appeared = true }

                    if !report.failures.isEmpty {
                        failuresSection
                    }

                    Footnote(
                        "Everything went to Trash, not deleted outright. Restore any item from "
                            + "the Trash before it is emptied to undo this.",
                        symbol: "arrow.uturn.backward"
                    )
                    .padding(.horizontal, SweepTokens.s5)
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Color.clear.frame(height: SweepTokens.s2)
                }
            }

            Divider()
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.sweepPrimary(minWidth: 108))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(SweepTokens.s5)
        }
    }

    private var failuresSection: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s2) {
            HStack(spacing: SweepTokens.s2 - 2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SweepTokens.tierCaution)
                Text("\(SweepFormat.count(report.failures.count)) could not be cleaned")
                    .font(SweepFont.sectionTitle)
                    .foregroundStyle(.primary)
            }
            SectionCard {
                ForEach(Array(report.failures.enumerated()), id: \.element.id) { index, outcome in
                    if index > 0 { Divider() }
                    failureRow(outcome)
                }
            }
        }
        .padding(.horizontal, SweepTokens.s5)
    }

    private func failureRow(_ outcome: CleanItemOutcome) -> some View {
        HStack(alignment: .top, spacing: SweepTokens.s3 - 2) {
            Image(systemName: "xmark.circle")
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(SweepTokens.tierCaution)
                .frame(width: 17, alignment: .center)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(outcome.title)
                    .font(SweepFont.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let reason = outcome.failureReason {
                    Text(reason)
                        .font(SweepFont.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: SweepTokens.s3)
            SizeColumn(byteCount: outcome.byteCount)
        }
        .padding(.horizontal, SweepTokens.s3 - 2)
        .padding(.vertical, SweepTokens.s2)
    }
}

#Preview("Clean report — clean") {
    CleanReportState(
        report: CleanReport(freedBytes: 9_760_000_000, succeededCount: 18_190, outcomes: []),
        onDone: {}
    )
    .frame(width: 560, height: 420)
}

#Preview("Clean report — with failures") {
    CleanReportState(
        report: CleanReport(
            freedBytes: 9_200_000_000,
            succeededCount: 18_150,
            outcomes: [
                CleanItemOutcome(
                    id: "1", title: "com.example.LockedCache",
                    byteCount: 482_000_000,
                    status: .failed(reason: "In use by a running app")
                ),
                CleanItemOutcome(
                    id: "2", title: "18.4 (22E240)",
                    byteCount: 3_120_000_000,
                    status: .failed(reason: "Changed since scan; skipped for safety")
                ),
            ]
        ),
        onDone: {}
    )
    .frame(width: 560, height: 480)
}
