import SwiftUI
import SweepUI

/// The hero. Idle → scanning → results, one ring, one number.
struct SmartScanScreen: View {
    @Environment(ScanModel.self) private var scan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onReviewItems: () -> Void

    private let ringDiameter: CGFloat = 224

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                title: Destination.smartScan.title,
                subtitle: Destination.smartScan.subtitle
            ) {
                if scan.phase == .results {
                    Button("Rescan") { scan.rescan() }
                        .buttonStyle(.sweepQuiet)
                }
            }

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            // A sibling, not a `safeAreaInset`: an action bar that rows can scroll underneath
            // reads as a clipped list, and the last row of a size-ordered list is exactly the
            // row a user checks last.
            if scan.phase == .results {
                resultsFooter
            }
        }
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: scan.phase)
    }

    @ViewBuilder
    private var content: some View {
        switch scan.phase {
        case .idle:
            idle
        case .scanning:
            scanning
        case .results:
            results
        case .failed(let message):
            failure(message)
        }
    }

    // MARK: - Idle

    private var idle: some View {
        VStack(spacing: 0) {
            Spacer(minLength: SweepTokens.s5)
            ScanRing(state: .idle, diameter: ringDiameter) {
                Image(systemName: "sparkles")
                    .font(.system(size: 30, weight: .light))
                    .foregroundStyle(.quaternary)
            }
            Spacer().frame(height: SweepTokens.s6)
            Button("Scan") { scan.start() }
                .buttonStyle(.sweepPrimary)
                .keyboardShortcut(.defaultAction)
            Spacer().frame(height: SweepTokens.s3)
            Text("Reads your caches, logs and developer junk. Nothing is deleted.")
                .font(SweepFont.screenSubtitle)
                .foregroundStyle(.secondary)
            Spacer(minLength: SweepTokens.s5)
        }
        .padding(.horizontal, SweepTokens.s5)
    }

    // MARK: - Scanning

    private var scanning: some View {
        VStack(spacing: 0) {
            Spacer(minLength: SweepTokens.s5)
            ScanRing(state: .scanning, diameter: ringDiameter) {
                HeroByteCounter(
                    byteCount: scan.claimedBytes,
                    size: 52,
                    caption: scan.scanningCaption
                )
            }
            Spacer().frame(height: SweepTokens.s5)
            PathTicker(path: scan.currentPath)
            Spacer().frame(height: SweepTokens.s5)
            Button("Stop") { scan.cancel() }
                .buttonStyle(.sweepQuiet)
                .keyboardShortcut(.cancelAction)
            Spacer(minLength: SweepTokens.s5)
        }
        .padding(.horizontal, SweepTokens.s5)
    }

    // MARK: - Results

    private var results: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: SweepTokens.s5) {
                    ScanRing(state: .complete, diameter: ringDiameter) {
                        HeroByteCounter(
                            byteCount: scan.claimedBytes,
                            size: 52,
                            label: scan.wasCancelled ? "Found so far" : "Found",
                            caption: scan.resultsCaption
                        )
                    }
                    .padding(.top, SweepTokens.s5)

                    if scan.summaryGroups.isEmpty {
                        InventoryEmptyState(
                            symbol: "checkmark.circle",
                            title: "Nothing to clean",
                            message: "No rule in the catalog claimed anything under the roots this build can read."
                        )
                        .frame(height: 160)
                    } else {
                        SectionCard {
                            ForEach(Array(scan.summaryGroups.enumerated()), id: \.element.id) { index, group in
                                if index > 0 { Divider() }
                                InventoryRow(
                                    symbol: group.symbol,
                                    title: group.title,
                                    detail: SweepFormat.itemCount(group.itemCount),
                                    detailIsPath: false,
                                    sizeValue: group.sizeValue,
                                    sizeUnit: group.sizeUnit,
                                    tier: group.tier,
                                    emphasis: .summary
                                )
                            }
                        }
                        .padding(.horizontal, SweepTokens.s5)
                    }

                    if let note = scan.skippedSummary {
                        Footnote(note, symbol: "info.circle")
                            .padding(.horizontal, SweepTokens.s5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Color.clear.frame(height: SweepTokens.s2)
                }
                // Short results sit centred in the pane; long ones scroll from the top.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
        }
    }

    private var resultsFooter: some View {
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
                if !scan.ruleGroups.isEmpty {
                    Button("Review items") { onReviewItems() }
                        .buttonStyle(.sweepQuiet)
                }
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.vertical, SweepTokens.s3)
        }
        .background(.bar)
    }

    // MARK: - Failure

    private func failure(_ message: String) -> some View {
        VStack(spacing: SweepTokens.s4) {
            InventoryEmptyState(
                symbol: "exclamationmark.triangle",
                title: "Scan could not start",
                message: message
            )
            Button("Try again") { scan.rescan() }
                .buttonStyle(.sweepQuiet)
        }
        .padding(SweepTokens.s5)
    }
}
