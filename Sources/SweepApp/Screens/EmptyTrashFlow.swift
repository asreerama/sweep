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
    /// Sizes streamed in AFTER the sheet is already up (user-directed: the sheet must never sit
    /// on a spinner while hundreds of trashed trees are measured). Keyed by entry name; an entry
    /// with no value yet renders a placeholder. The consent `execute` binds to is the identity
    /// snapshot, which is complete the moment `review` is set — sizes are informational.
    private(set) var sizeByName: [String: Int64] = [:]
    private(set) var isSizing = false
    var sheetShown = false
    var confirmShown = false

    private var task: Task<Void, Never>?

    var totalKnownBytes: Int64 {
        sizeByName.values.reduce(0, +)
    }

    /// Largest-first once sizes are known; still-unsized entries sink below sized ones in their
    /// original (directory) order, so the list settles from the top down as measuring proceeds.
    var displayItems: [EmptyTrashService.ReviewedItem] {
        guard let review else { return [] }
        return review.items.sorted { (sizeByName[$0.name] ?? -1) > (sizeByName[$1.name] ?? -1) }
    }

    func openReview() {
        sheetShown = true
        refreshReview()
    }

    func refreshReview() {
        task?.cancel()
        isReviewing = true
        review = nil
        report = nil
        sizeByName = [:]
        task = Task {
            // The identity snapshot is one lstat per entry — effectively instant even for a
            // heaving Trash — so the sheet renders its rows in the same beat it opens.
            let captured = await Task.detached(priority: .userInitiated) { EmptyTrashService.snapshot() }.value
            guard !Task.isCancelled else { return }
            review = captured
            isReviewing = false

            isSizing = true
            defer { isSizing = false }
            for item in captured.items {
                guard !Task.isCancelled else { return }
                let size = await Task.detached(priority: .utility) { EmptyTrashService.allocatedSize(of: item) }.value
                guard !Task.isCancelled else { return }
                sizeByName[item.name] = size
            }
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
        task?.cancel()
        sheetShown = false
        confirmShown = false
        review = nil
        report = nil
        sizeByName = [:]
        isSizing = false
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
                    ForEach(model.displayItems.prefix(Self.previewRowCap), id: \.url) { item in
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
                            if let size = model.sizeByName[item.name] {
                                Text(SweepFormat.bytes(size))
                                    .font(SweepFont.monoSmall)
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                    .fixedSize()
                            } else {
                                Text("\u{2026}")
                                    .font(SweepFont.monoSmall)
                                    .foregroundStyle(.tertiary)
                                    .fixedSize()
                            }
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
            // Layout contract: the two buttons are atoms and never compress — the count text is
            // the flexible run that truncates instead. (The first cut had this exactly backwards
            // and the Cancel button rendered as "C…".)
            if let review = model.review, !review.isEmpty {
                Text(footerSummary(review))
                    .font(SweepFont.mono)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: SweepTokens.s3)
            Button("Cancel") { model.sheetShown = false }
                .buttonStyle(.sweepQuiet)
                .keyboardShortcut(.cancelAction)
                .disabled(model.isExecuting)
                .fixedSize()
            Button(model.isExecuting ? "Deleting\u{2026}" : "Empty Trash") { model.confirmShown = true }
                .buttonStyle(.sweepDestructive())
                .disabled(model.isExecuting || model.isReviewing || (model.review?.isEmpty ?? true))
                .fixedSize()
        }
        .padding(SweepTokens.s5)
        // The PLAN-mandated second confirmation: the exact count and bytes, restated, with the
        // irreversibility in the message — never a single-click destructive action.
        .confirmationDialog(
            "Permanently delete \(SweepFormat.itemCount(model.review?.itemCount ?? 0)) (\(confirmBytesText))?",
            isPresented: $model.confirmShown, titleVisibility: .visible
        ) {
            Button("Delete Forever", role: .destructive) { model.execute() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Anything moved to the Trash after this review stays untouched. This cannot be undone.")
        }
    }

    /// "988 items · 16.2 GB", with a trailing ellipsis while sizes are still streaming in — the
    /// number only ever grows, so showing the running total beats hiding it behind a spinner.
    private func footerSummary(_ review: EmptyTrashService.Review) -> String {
        var text = "\(SweepFormat.itemCount(review.itemCount)) \u{00B7} \(SweepFormat.bytes(model.totalKnownBytes))"
        if model.isSizing { text += "\u{2026}" }
        return text
    }

    private var confirmBytesText: String {
        model.isSizing
            ? "at least \(SweepFormat.bytes(model.totalKnownBytes))"
            : SweepFormat.bytes(model.totalKnownBytes)
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
