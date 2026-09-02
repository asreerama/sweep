import SweepCore
import SweepUI
import SwiftUI

/// Empty Trash (PLAN §3 module 1): its own flow, deliberately outside the shared Clean
/// pipeline — never auto-selected, never bundled into a scan's clean, and the only operation
/// in the app that deletes outright instead of moving to the Trash (these files are already
/// there). The sheet is the review; the destructive button re-confirms with the exact
/// count/bytes before `EmptyTrashService.execute` consumes the snapshot.
@MainActor
@Observable
final class EmptyTrashModel {
    private(set) var review: EmptyTrashService.Review?
    private(set) var isReviewing = false
    private(set) var isExecuting = false
    private(set) var report: EmptyTrashService.Report?
    var sheetShown = false
    var confirmShown = false

    private var task: Task<Void, Never>?

    func openReview() {
        sheetShown = true
        refreshReview()
    }

    func refreshReview() {
        task?.cancel()
        isReviewing = true
        review = nil
        report = nil
        task = Task {
            let captured = await Task.detached(priority: .userInitiated) { EmptyTrashService.review() }.value
            guard !Task.isCancelled else { return }
            review = captured
            isReviewing = false
        }
    }

    func execute() {
        guard let review, !isExecuting else { return }
        isExecuting = true
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                EmptyTrashService.execute(review: review)
            }.value
            report = result
            isExecuting = false
        }
    }

    func finish() {
        sheetShown = false
        confirmShown = false
        review = nil
        report = nil
    }
}

struct EmptyTrashSheet: View {
    @Bindable var model: EmptyTrashModel

    /// The review lists at most this many rows — the point is informed consent on count and
    /// bytes, not a scrollable inventory of every discarded file.
    private static let previewRowCap = 8

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let report = model.report {
                reportBody(report)
            } else {
                reviewBody
            }
        }
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
        .onDisappear { model.finish() }
    }

    // MARK: - Review

    @ViewBuilder
    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s2) {
            Text("Empty the Trash?")
                .font(SweepFont.sectionTitle)
            Text("Deletes everything currently in the Trash. This cannot be undone.")
                .font(SweepFont.caption)
                .foregroundStyle(.secondary)
        }
        .padding(SweepTokens.s5)

        Divider()

        Group {
            if model.isReviewing {
                HStack(spacing: SweepTokens.s3) {
                    ProgressView().controlSize(.small)
                    Text("Reading the Trash\u{2026}")
                        .font(SweepFont.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(SweepTokens.s5)
            } else if let review = model.review, !review.isEmpty {
                VStack(alignment: .leading, spacing: SweepTokens.s1) {
                    ForEach(review.items.prefix(Self.previewRowCap), id: \.url) { item in
                        HStack(spacing: SweepTokens.s2) {
                            Image(systemName: "doc")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                                .frame(width: 16)
                            Text(item.name)
                                .font(SweepFont.rowTitle)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer(minLength: SweepTokens.s2)
                            Text(SweepFormat.bytes(item.allocatedSize))
                                .font(SweepFont.monoSmall)
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                        .frame(height: 26)
                    }
                    if review.itemCount > Self.previewRowCap {
                        Text("and \(SweepFormat.count(review.itemCount - Self.previewRowCap)) more")
                            .font(SweepFont.caption)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 24)
                    }
                }
                .padding(SweepTokens.s5)
            } else {
                InventoryEmptyState(symbol: "trash", title: "The Trash is empty")
                    .frame(height: 120)
            }
        }

        Divider()

        HStack(spacing: SweepTokens.s3) {
            if let review = model.review, !review.isEmpty {
                Text("\(SweepFormat.itemCount(review.itemCount)) \u{00B7} \(SweepFormat.bytes(review.totalBytes))")
                    .font(SweepFont.mono)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            Spacer(minLength: SweepTokens.s3)
            Button("Cancel") { model.sheetShown = false }
                .buttonStyle(.sweepQuiet)
                .keyboardShortcut(.cancelAction)
                .disabled(model.isExecuting)
            Button(model.isExecuting ? "Deleting\u{2026}" : "Empty Trash") { model.confirmShown = true }
                .buttonStyle(.sweepDestructive())
                .disabled(model.isExecuting || model.isReviewing || (model.review?.isEmpty ?? true))
        }
        .padding(SweepTokens.s5)
        // The PLAN-mandated second confirmation: the exact count and bytes, restated, with the
        // irreversibility in the message — never a single-click destructive action.
        .confirmationDialog(
            "Permanently delete \(SweepFormat.itemCount(model.review?.itemCount ?? 0)) (\(SweepFormat.bytes(model.review?.totalBytes ?? 0)))?",
            isPresented: $model.confirmShown, titleVisibility: .visible
        ) {
            Button("Delete Forever", role: .destructive) { model.execute() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything moved to the Trash after this review stays untouched. This cannot be undone.")
        }
    }

    // MARK: - Report

    private func reportBody(_ report: EmptyTrashService.Report) -> some View {
        VStack(alignment: .leading, spacing: SweepTokens.s3) {
            HStack(spacing: SweepTokens.s2) {
                Image(systemName: report.refusedCount == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(report.refusedCount == 0 ? SweepTokens.tierSafe : SweepTokens.tierCaution)
                Text(report.refusedCount == 0 ? "Trash emptied" : "Emptied, with exceptions")
                    .font(SweepFont.sectionTitle)
            }
            Text("\(SweepFormat.itemCount(report.deletedCount)) deleted \u{00B7} about \(SweepFormat.bytes(report.freedBytesEstimate)) freed")
                .font(SweepFont.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            ForEach(Array(report.outcomes.filter { $0.result != .deleted }.prefix(6)), id: \.item.url) { outcome in
                HStack(spacing: SweepTokens.s2) {
                    Image(systemName: "xmark.circle")
                        .font(.system(size: 12))
                        .foregroundStyle(SweepTokens.tierCaution)
                    Text(outcome.item.name)
                        .font(SweepFont.rowTitle)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: SweepTokens.s2)
                    Text(refusalCaption(outcome.result))
                        .font(SweepFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if report.lateAdditionsSkipped > 0 {
                Footnote(
                    "\(SweepFormat.itemCount(report.lateAdditionsSkipped)) moved to the Trash after the review \u{2014} left untouched.",
                    symbol: "clock"
                )
            }

            HStack {
                Spacer()
                Button("Done") { model.sheetShown = false }
                    .buttonStyle(.sweepPrimary(minWidth: 96))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(SweepTokens.s5)
    }

    private func refusalCaption(_ result: EmptyTrashService.ItemResult) -> String {
        switch result {
        case .deleted: ""
        case .changedSinceReview: "changed since review; skipped"
        case .vanishedSinceReview: "already gone"
        case .failed(let reason): reason
        }
    }
}
