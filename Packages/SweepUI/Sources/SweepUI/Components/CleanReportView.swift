import AppKit
import SwiftUI

/// The Clean flow's final state: what freed, what did not go as planned, and how to get it back.
public struct CleanReportState: View {
    private let report: CleanReport
    private let onDone: () -> Void
    /// Shown only when the backend can actually retry (Gate 1 open). Left off, the failures still
    /// explain themselves and offer Reveal / fix-permission, but no dead "Try again" button.
    private let canRetry: Bool
    private let onRetry: (() -> Void)?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false

    public init(
        report: CleanReport,
        onDone: @escaping () -> Void,
        canRetry: Bool = false,
        onRetry: (() -> Void)? = nil
    ) {
        self.report = report
        self.onDone = onDone
        self.canRetry = canRetry
        self.onRetry = onRetry
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

            // Whole-batch guidance + retry: if any failure looks permission-related, name the fix
            // once here and offer to open the exact settings pane, then re-run just the failures.
            if report.failures.contains(where: { Self.isPermissionFailure($0.failureReason) }) {
                Text("Some items are in folders Sweep can't reach yet. Grant Sweep Full Disk Access, then try again.")
                    .font(SweepFont.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: SweepTokens.s2) {
                if report.failures.contains(where: { Self.isPermissionFailure($0.failureReason) }) {
                    Button("Open Full Disk Access") { Self.openFullDiskAccessSettings() }
                        .buttonStyle(.sweepQuiet)
                }
                if canRetry, let onRetry {
                    Button("Try again", action: onRetry)
                        .buttonStyle(.sweepQuiet)
                }
            }
        }
        .padding(.horizontal, SweepTokens.s5)
    }

    private func failureRow(_ outcome: CleanItemOutcome) -> some View {
        HStack(alignment: .top, spacing: SweepTokens.s3 - 2) {
            Image(systemName: Self.isPermissionFailure(outcome.failureReason) ? "lock" : "xmark.circle")
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
                    // The reason as reported, plus a concrete next step when it is a permission
                    // block — never a bare "deletion failed".
                    Text(Self.isPermissionFailure(reason) ? "\(reason). Grant Full Disk Access to remove it." : reason)
                        .font(SweepFont.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: SweepTokens.s3)
            // Reveal in Finder so the user can inspect (or remove) the item themselves. Item ids
            // are absolute paths for every real clean source.
            if outcome.id.hasPrefix("/") {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: outcome.id)])
                } label: {
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Reveal in Finder")
                .padding(.top, 1)
            }
            SizeColumn(byteCount: outcome.byteCount)
        }
        .padding(.horizontal, SweepTokens.s3 - 2)
        .padding(.vertical, SweepTokens.s2)
    }

    /// Heuristic: does this failure reason describe a permission/access block the user can fix by
    /// granting Full Disk Access? Kept on the reason text (rather than a structured status) so it
    /// needs no change to the pinned `CleanBackend`/`CleanService` contract.
    private static func isPermissionFailure(_ reason: String?) -> Bool {
        guard let reason = reason?.lowercased() else { return false }
        return ["permission", "denied", "not permitted", "operation not permitted",
                "access", "full disk", "protected", "privilege"].contains { reason.contains($0) }
    }

    private static func openFullDiskAccessSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
        NSWorkspace.shared.open(url)
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
