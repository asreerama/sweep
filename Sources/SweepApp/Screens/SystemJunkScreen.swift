import SwiftUI
import SweepUI

/// System Junk review: the inventory-view template over the scan's rule groups.
///
/// Search, group sections, per-item rows, per-group select-all — all live, all terminating at
/// the same Gate 1 notice, because nothing in this build can delete anything.
struct SystemJunkScreen: View {
    @Environment(ScanModel.self) private var scan

    @State private var query = ""
    @State private var collapsed: Set<String> = []

    private var visibleGroups: [InventoryGroup] {
        InventoryAggregate.filter(scan.ruleGroups, query: query)
    }

    var body: some View {
        @Bindable var scan = scan

        VStack(spacing: 0) {
            ScreenHeader(
                title: Destination.systemJunk.title,
                subtitle: Destination.systemJunk.subtitle
            ) {
                HStack(spacing: SweepTokens.s2) {
                    if !scan.ruleGroups.isEmpty {
                        SweepSearchField(text: $query, prompt: "Filter paths")
                            .frame(width: 200)
                    }
                    if scan.isScanning {
                        Button("Stop") { scan.cancel() }.buttonStyle(.sweepQuiet)
                    } else {
                        Button(scan.ruleGroups.isEmpty ? "Scan" : "Rescan") { scan.rescan() }
                            .buttonStyle(.sweepQuiet)
                    }
                }
            }

            Divider()

            body(for: $scan)
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // A sibling, not a `safeAreaInset`: an action bar rows can scroll underneath reads
            // as a clipped list, and the last row of a size-ordered list is exactly the row a
            // user checks last.
            footer
        }
    }

    @ViewBuilder
    private func body(for scan: Bindable<ScanModel>) -> some View {
        switch self.scan.phase {
        case .idle:
            InventoryEmptyState(
                symbol: "trash",
                title: "No scan yet",
                message: "Run a scan to list everything the rule catalog claims under the caches, logs and developer roots it can read."
            )
        case .scanning:
            scanningState
        case .failed(let message):
            InventoryEmptyState(symbol: "exclamationmark.triangle", title: "Scan could not start", message: message)
        case .results:
            if visibleGroups.isEmpty {
                InventoryEmptyState(
                    symbol: query.isEmpty ? "checkmark.circle" : "magnifyingglass",
                    title: query.isEmpty ? "Nothing to clean" : "No matches",
                    message: query.isEmpty
                        ? "No rule claimed anything under the roots this build can read."
                        : "Nothing in the results matches \u{201C}\(query)\u{201D}."
                )
            } else {
                InventoryList(groups: visibleGroups, selection: scan.selection, collapsed: $collapsed)
            }
        }
    }

    private var scanningState: some View {
        VStack(spacing: SweepTokens.s4) {
            ScanRing(state: .scanning, diameter: 96) {
                HeroByteCounter(byteCount: scan.claimedBytes, size: 22)
            }
            Text(scan.scanningCaption)
                .font(SweepFont.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            PathTicker(path: scan.currentPath, width: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: SweepTokens.s3) {
                Button("Clean") {}
                    .buttonStyle(.sweepPrimary(minWidth: 108))
                    .disabled(true)
                    .help("Cleaning arrives at Gate 1")
                    .accessibilityHint("Disabled. Cleaning arrives at Gate 1.")
                GateNotice("Cleaning arrives at Gate 1")
                Spacer(minLength: SweepTokens.s3)
                if scan.phase == .results, !scan.ruleGroups.isEmpty {
                    Text(selectionSummary)
                        .font(SweepFont.mono)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.vertical, SweepTokens.s3)
            if let note = scan.skippedSummary, scan.phase == .results {
                Footnote(note, symbol: "info.circle")
                    .padding(.horizontal, SweepTokens.s5)
                    .padding(.bottom, SweepTokens.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.bar)
    }

    private var selectionSummary: String {
        let groups = scan.ruleGroups
        let selected = scan.selection.selectedCount(in: groups)
        let total = InventoryAggregate.totalItems(groups)
        let bytes = SweepFormat.bytes(scan.selection.selectedBytes(in: groups))
        return "\(SweepFormat.count(selected)) of \(SweepFormat.count(total)) selected \u{00B7} \(bytes)"
    }
}
