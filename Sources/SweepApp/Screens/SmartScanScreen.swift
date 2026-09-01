import SwiftUI
import SweepUI

/// The hero. Idle → scanning → results, one ring, one number.
///
/// Motion continuity (PLAN §5): `scan.phase` (the model's truth) and `displayPhase` (what this
/// screen renders) are deliberately different values. Collapsing them back into one would mean
/// the ring's slot swaps the instant the model says "results" — the "hard cut" this section
/// exists to remove. `displayPhase` lags one beat behind on the scanning→results edge specifically,
/// long enough for `ScanRing` to decelerate and close on its own (`SweepMotion.resultsMorphDelay`),
/// so the ring and hero counter are still the *same* `ScanRing`/`HeroByteCounter` instances
/// (tagged into `heroNamespace`) when the layout morphs them into the results slot, rather than
/// one pair of views disappearing and a different pair fading in.
struct SmartScanScreen: View {
    @Environment(ScanModel.self) private var scan
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let onReviewItems: () -> Void

    /// Non-nil while the Clean flow's sheet is up. Built fresh from `scan` each time the button
    /// is pressed rather than kept around, so a rescan between clean runs can never hand a stale
    /// request to a flow already in flight.
    @State private var cleanFlow: CleanFlowModel?

    /// What this screen is actually showing — see the type doc for why this is not just
    /// `scan.phase` re-read.
    @State private var displayPhase: ScanDisplayPhase = .idle
    @Namespace private var heroNamespace

    private let ringDiameter: CGFloat = 224
    private let resultsRingDiameter: CGFloat = 120

    private enum ScanDisplayPhase: Equatable {
        case idle
        case scanning
        /// The model already says `.results`; the ring is still in the scanning slot, playing
        /// its own decelerate-and-close choreography before the layout morphs.
        case settling
        case results
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                title: Destination.smartScan.title,
                subtitle: Destination.smartScan.subtitle
            ) {
                if displayPhase == .results {
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
            if displayPhase == .results {
                resultsFooter
            }
        }
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: displayPhase)
        .onAppear { syncDisplayPhase(immediate: true) }
        .onChange(of: scan.phase) { _, _ in syncDisplayPhase(immediate: false) }
    }

    /// Mirrors `scan.phase` into `displayPhase` — immediately on every edge except
    /// scanning→results, which routes through `.settling` first. Re-entrant: a rescan that lands
    /// mid-settle calls this again with `scan.phase == .scanning`, which reverts `displayPhase`
    /// to `.scanning` right away (same branch as `.settling`, so nothing unmounts) and the
    /// pending delayed flip below no-ops itself via the phase check when it wakes up — the
    /// "everything interruptible" half of PLAN §5's continuity requirement.
    private func syncDisplayPhase(immediate: Bool) {
        switch scan.phase {
        case .idle: displayPhase = .idle
        case .scanning: displayPhase = .scanning
        case .failed(let message): displayPhase = .failed(message)
        case .results:
            guard displayPhase != .results else { return }
            if immediate || reduceMotion {
                displayPhase = .results
            } else {
                displayPhase = .settling
                Task {
                    try? await Task.sleep(for: .seconds(SweepMotion.resultsMorphDelay))
                    guard scan.phase == .results, displayPhase == .settling else { return }
                    displayPhase = .results
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch displayPhase {
        case .idle:
            idle
        case .scanning, .settling:
            scanning(ringComplete: displayPhase == .settling)
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
            .matchedGeometryEffect(id: "hero-ring", in: heroNamespace)
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

    // MARK: - Scanning / settling
    //
    // One layout for both: `ringComplete` only changes what `ScanRing` and `HeroByteCounter` are
    // showing, never which branch of `content` is active, so the transition between them is
    // whatever `ScanRing`'s own decelerate-and-close choreography does — no outer content swap
    // to interrupt it.

    private func scanning(ringComplete: Bool) -> some View {
        VStack(spacing: 0) {
            Spacer(minLength: SweepTokens.s5)
            ScanRing(state: ringComplete ? .complete : .scanning, diameter: ringDiameter) {
                HeroByteCounter(
                    // Safe-tier bytes only once the ring lands (PLAN §6b): the counter settles
                    // to the number that is both the hero total and the clean scope, not the raw
                    // scan total scanning was showing a moment before.
                    byteCount: ringComplete ? scan.safeBytes : scan.claimedBytes,
                    size: ringDiameter * 0.235,
                    label: ringComplete ? (scan.wasCancelled ? "Found so far" : "Ready to clean") : nil,
                    caption: ringComplete ? scan.safeResultsCaption : scan.scanningCaption
                )
            }
            .matchedGeometryEffect(id: "hero-ring", in: heroNamespace)
            Spacer().frame(height: SweepTokens.s5)
            PathTicker(path: ringComplete ? nil : scan.currentPath)
            Spacer().frame(height: SweepTokens.s5)
            Button("Stop") { scan.cancel() }
                .buttonStyle(.sweepQuiet)
                .keyboardShortcut(.cancelAction)
                .disabled(ringComplete)
                .opacity(ringComplete ? 0 : 1)
            Spacer(minLength: SweepTokens.s5)
        }
        .padding(.horizontal, SweepTokens.s5)
    }

    // MARK: - Results

    private var results: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: SweepTokens.s5) {
                    ScanRing(state: .complete, diameter: resultsRingDiameter) {
                        HeroByteCounter(
                            byteCount: scan.safeBytes,
                            size: resultsRingDiameter * 0.235,
                            label: scan.wasCancelled ? "Found so far" : "Ready to clean",
                            caption: scan.safeResultsCaption
                        )
                    }
                    .matchedGeometryEffect(id: "hero-ring", in: heroNamespace)
                    .padding(.top, SweepTokens.s5)

                    if scan.summaryGroups.isEmpty {
                        InventoryEmptyState(
                            symbol: "checkmark.circle",
                            title: "You're all clear",
                            message: "Nothing under the roots this build can read needs attention right now."
                        )
                        .frame(height: 160)
                    } else {
                        if scan.safeSummaryGroups.isEmpty {
                            InventoryEmptyState(
                                symbol: "checkmark.circle",
                                title: "Nothing safe to clean automatically",
                                message: "Everything found is worth a second look first — see Needs review below."
                            )
                            .frame(height: 120)
                        } else {
                            summaryCard(scan.safeSummaryGroups)
                                .padding(.horizontal, SweepTokens.s5)
                        }

                        if !scan.needsReviewGroups.isEmpty {
                            needsReview
                        }
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

    private func summaryCard(_ groups: [InventoryGroup]) -> some View {
        SectionCard {
            ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                if index > 0 { Divider() }
                InventoryRow(
                    symbol: group.symbol,
                    title: group.title,
                    detail: ScanService.friendlySubtitle(forSummaryGroupID: group.id)
                        ?? SweepFormat.itemCount(group.itemCount),
                    detailIsPath: false,
                    sizeValue: group.sizeValue,
                    sizeUnit: group.sizeUnit,
                    tier: group.tier,
                    emphasis: .summary
                )
                .staggeredEntrance(index)
            }
        }
    }

    /// Caution-tier findings: real, visible, and structurally separated from the clean scope
    /// above. Never contributes to `safeBytes`/`safeItemCount` and never gets a select-all —
    /// Smart Scan does not auto-select outside the safe tier (PLAN §3).
    private var needsReview: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s2) {
            HStack(spacing: SweepTokens.s2 - 2) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(SweepTokens.tierCaution)
                Text("Needs review")
                    .font(SweepFont.sectionTitle)
                    .foregroundStyle(.primary)
            }
            Text("Found, but not part of the safe-tier clean above. Review these in System Junk.")
                .font(SweepFont.caption)
                .foregroundStyle(.secondary)
            summaryCard(scan.needsReviewGroups)
        }
        .padding(.horizontal, SweepTokens.s5)
    }

    private var resultsFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: SweepTokens.s3) {
                Button("Clean") { startClean() }
                    .buttonStyle(.sweepPrimary(minWidth: 108))
                    .disabled(!CleanAdapter.isEnabled || scan.safeSummaryGroups.isEmpty)
                    .help(CleanAdapter.isEnabled ? "Move the safe-tier items to Trash" : "Cleaning arrives at Gate 1")
                    .accessibilityHint(CleanAdapter.isEnabled ? "" : "Disabled. Cleaning arrives at Gate 1.")
                if !CleanAdapter.isEnabled {
                    GateNotice("Cleaning arrives at Gate 1")
                }
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
        .sheet(isPresented: Binding(get: { cleanFlow != nil }, set: { if !$0 { cleanFlow = nil } })) {
            if let cleanFlow {
                CleanFlowContainer(model: cleanFlow) { self.cleanFlow = nil }
            }
        }
    }

    /// Only reachable once `CleanAdapter.isEnabled` is true (the button above is disabled until
    /// then), but built the same way regardless — the flow behind the gate is real, not a stub
    /// that gets swapped out later.
    private func startClean() {
        let (summary, items) = scan.smartScanCleanRequest()
        guard let context = scan.cleanExecutionContext() else { return }
        cleanFlow = CleanFlowModel(
            requestSummary: summary,
            itemIDs: Set(items.map(\.id)),
            backend: CleanAdapter(context: context, items: items)
        )
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
