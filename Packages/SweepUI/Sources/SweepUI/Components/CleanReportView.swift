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

    /// Cap on the failure list's `ScrollView` when a report has failures — the one part of this
    /// sheet that can genuinely run long. A clean report never scrolls at all (see `content`).
    private static let failureListMaxHeight: CGFloat = 380

    public var body: some View {
        VStack(spacing: 0) {
            content
            Divider()
            HStack {
                Spacer()
                Button("Done", action: onDone)
                    .buttonStyle(.sweepPrimary(minWidth: 108))
                    .keyboardShortcut(.defaultAction)
            }
            .padding(SweepTokens.s5)
        }
        .background(backgroundWash)
    }

    /// The report body above the Done bar. A clean report (no failures) lays out directly —
    /// hero, then footnote — so the sheet hugs that content instead of a `ScrollView` padding
    /// out to whatever fixed height the container used to impose, which is what left a dead
    /// blank middle on a report with nothing to list. A report with failures still scrolls,
    /// capped at `failureListMaxHeight`.
    @ViewBuilder
    private var content: some View {
        if report.failures.isEmpty {
            VStack(spacing: SweepTokens.s5) {
                heroBlock
                footnote
            }
            .padding(.bottom, SweepTokens.s5)
        } else {
            ScrollView(.vertical) {
                VStack(spacing: SweepTokens.s5) {
                    heroBlock
                    failuresSection
                    footnote
                }
                .padding(.bottom, SweepTokens.s5)
            }
            .frame(maxHeight: Self.failureListMaxHeight)
        }
    }

    private var heroBlock: some View {
        VStack(spacing: SweepTokens.s2) {
            Image(systemName: report.failures.isEmpty ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 30, weight: .light))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(report.failures.isEmpty ? SweepTokens.accent : SweepTokens.tierCaution)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? false : appeared)
            HeroByteCounter(
                // `freedBytes` is a volume-capacity delta and reads ~0 right after a move to
                // Trash, since the files are still on the same volume — `movedBytes` is what the
                // user actually watched happen, and `max` keeps old previews with an empty
                // `outcomes` array (where `movedBytes` is 0) reading off `freedBytes` instead.
                byteCount: max(report.movedBytes, report.freedBytes),
                size: 44,
                label: "Cleaned up",
                caption: "\(SweepFormat.itemCount(report.succeededCount)) moved to Trash"
            )
        }
        .padding(.top, SweepTokens.s5)
        .padding(.bottom, SweepTokens.s3)
        .frame(maxWidth: .infinity)
        // Success moment polish: one settle-in beat layered on top of the existing checkmark
        // bounce and digit roll, not a second competing flourish — the whole hero scales up from
        // a hair under full size rather than just appearing fully formed. Reduce Motion drops
        // the scale and crossfades in on opacity instead, same substitute every kinetic moment
        // in this app makes.
        .scaleEffect(reduceMotion ? 1 : (appeared ? 1 : 0.96))
        .opacity(reduceMotion ? (appeared ? 1 : 0) : 1)
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: appeared)
        .onAppear { appeared = true }
    }

    private var footnote: some View {
        Footnote(
            "Items went to the Trash, not deleted outright. Space is reclaimed once the Trash "
                + "empties. Restore anything from the Trash to undo.",
            symbol: "arrow.uturn.backward"
        )
        .padding(.horizontal, SweepTokens.s5)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The success wash (PLAN §5 volume-raise, reworked): painted behind the whole sheet rather
    /// than scoped to the header `VStack`'s own background, so it reads as this sheet's ground
    /// and fades naturally into the surface the footnote and failure list sit on, instead of
    /// stopping dead at a frame edge over an otherwise stark white sheet. Off for a report with
    /// failures — amber stays reserved for the tier-badge system and must never look decorative
    /// here, so that case gets the plain ground instead of a tint.
    private var backgroundWash: some View {
        LinearGradient(
            stops: report.failures.isEmpty
                ? [
                    .init(color: SweepTokens.accent.opacity(0.12), location: 0),
                    .init(color: SweepTokens.ground, location: 0.55),
                  ]
                : [.init(color: SweepTokens.ground, location: 0), .init(color: SweepTokens.ground, location: 1)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var failuresSection: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s2) {
            HStack(spacing: SweepTokens.s2 - 2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .medium))
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
                .font(.system(size: 13, weight: .regular))
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
                        .font(.system(size: 13, weight: .medium))
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
        // The new 44 pt row rhythm (Scale v3): a failure's title/reason often wraps to two
        // lines, so this is a floor, not a fixed height — breathing room without clipping a
        // longer reason.
        .frame(minHeight: SweepTokens.inventoryRowHeight)
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
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
}

/// The "Freed 0 B" bug this report guards against: a move to Trash keeps items on the same
/// volume, so `freedBytes` is honestly ~0 even though 57 items just moved. `movedBytes` is what
/// the hero actually leads with.
#Preview("Clean report — moved to Trash, freedBytes ~0") {
    CleanReportState(
        report: CleanReport(
            freedBytes: 0,
            succeededCount: 57,
            outcomes: (1...57).map {
                CleanItemOutcome(id: "\($0)", title: "Item \($0)", byteCount: 4_000_000, status: .succeeded)
            }
        ),
        onDone: {}
    )
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
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
    .frame(width: 460)
    .fixedSize(horizontal: false, vertical: true)
}
