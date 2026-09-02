import SwiftUI
import SweepUI

/// The hero. Idle → scanning → results, one ring, one number.
///
/// Motion continuity (PLAN §5): `scan.phase` (the model's truth) and `displayPhase` (what this
/// screen renders) are deliberately different values. Collapsing them back into one would mean
/// the ring's slot swaps the instant the model says "results" — the "hard cut" this section
/// exists to remove. `displayPhase` lags one beat behind on the scanning→results edge specifically,
/// long enough for `ScanRing` to decelerate and close on its own (`SweepMotion.resultsMorphDelay`).
///
/// There is exactly one `ScanRing`/`HeroByteCounter` call site for the whole screen (`heroRing`,
/// built inside `heroScreen`), and it sits unconditionally above every `displayPhase` branch —
/// never inside an `if`/`switch` that could tear it down and remount it. That used to be the bug:
/// an earlier build instantiated a second, differently-sized `ScanRing` in the `results` branch
/// and bridged the two with `matchedGeometryEffect`. `matchedGeometryEffect` interpolates the
/// *frame* across that swap, but it cannot carry over `ScanRing`'s internal `@State`
/// (`rotationAngle`, `spinTask`, `pulseScale`) — those reset the instant the new instance mounts,
/// which is exactly the moment the scan lands and the ring is mid-deceleration. The reset showed
/// up as a one-frame glitch, plus the hero number's font size (52.6pt scanning → 28.2pt results)
/// jumping instantly because `Text` font size isn't itself animatable. Now the ring only ever
/// changes *parameters* (`diameter`, `state`) on the one instance, and the counter's shrink is a
/// `scaleEffect` on a fixed-size `HeroByteCounter` rather than a re-sized one, so it interpolates
/// on the same curve as the ring instead of popping.
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
    ///
    /// Stored as an *override* over the model's phase, `nil` by default, so the very first body
    /// evaluation — including every time this screen is re-created from scratch on navigation,
    /// since `RootView` keys the detail on `.id(destination)` — already resolves to the correct
    /// phase with no transition to play. Previously this was a plain `@State` seeded at `.idle`:
    /// returning to a finished scan rendered one `.idle` frame and then animated the whole
    /// idle→results morph (ring shrinking and repositioning, footer sliding, completion pulse),
    /// which read as the ring "flying into position" on every visit. With the override left `nil`
    /// at mount, `displayPhase` is `.results` on frame one and nothing animates; only the live
    /// scanning→settling→results choreography (driven by `onChange`) ever sets it.
    @State private var displayPhaseOverride: ScanDisplayPhase?

    private var displayPhase: ScanDisplayPhase { displayPhaseOverride ?? Self.mapped(scan.phase) }

    private static func mapped(_ phase: ScanPhase) -> ScanDisplayPhase {
        switch phase {
        case .idle: .idle
        case .scanning: .scanning
        case .results: .results
        case .failed(let message): .failed(message)
        }
    }

    /// The ring's diameter. The hero holds one confident size across scanning and results rather
    /// than collapsing to a small dot when the scan lands — a shrunk results ring read as "so small
    /// nobody can see it." `HeroByteCounter`'s `size` is computed from this constant.
    private let scanRingDiameter: CGFloat = 240
    private let resultsRingDiameter: CGFloat = 240

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
        .onChange(of: scan.phase) { _, _ in syncDisplayPhase() }
    }

    /// Mirrors `scan.phase` into `displayPhase` — immediately on every edge except
    /// scanning→results, which routes through `.settling` first. Re-entrant: a rescan that lands
    /// mid-settle calls this again with `scan.phase == .scanning`, which reverts `displayPhase`
    /// to `.scanning` right away (still resolved by the same unconditional `heroScreen`, so
    /// nothing unmounts) and the pending delayed flip below no-ops itself via the phase check
    /// when it wakes up — the "everything interruptible" half of PLAN §5's continuity requirement.
    private func syncDisplayPhase() {
        switch scan.phase {
        case .idle: displayPhaseOverride = .idle
        case .scanning: displayPhaseOverride = .scanning
        case .failed(let message): displayPhaseOverride = .failed(message)
        case .results:
            guard displayPhase != .results else { return }
            if reduceMotion {
                displayPhaseOverride = .results
            } else {
                displayPhaseOverride = .settling
                Task {
                    try? await Task.sleep(for: .seconds(SweepMotion.resultsMorphDelay))
                    guard scan.phase == .results, displayPhaseOverride == .settling else { return }
                    displayPhaseOverride = .results
                }
            }
        }
    }

    /// Only the failure screen is a genuine branch swap — it has no ring at all, and a scan
    /// that fails never had one turning yet, so there is no in-flight motion to destroy. Every
    /// other phase resolves to the same `heroScreen` call site.
    @ViewBuilder
    private var content: some View {
        if case .failed(let message) = displayPhase {
            failure(message)
        } else {
            heroScreen
        }
    }

    // MARK: - Hero (ring + counter + phase chrome)
    //
    // One shell for idle/scanning/settling/results: a `ScrollView` so results can grow past the
    // pane without a container swap, holding exactly one `heroRing` and one phase-driven
    // `heroBelow`. Short content (idle, scanning, a small result set) just centers inside it,
    // identically to a fixed VStack.

    private var isSettled: Bool { displayPhase == .settling || displayPhase == .results }
    private var isResults: Bool { displayPhase == .results }

    private var heroDiameter: CGFloat { isResults ? resultsRingDiameter : scanRingDiameter }
    /// The hero counter never changes its own `size`; it shrinks by exactly this factor via
    /// `scaleEffect`, animating on the same curve/timeline as `heroDiameter` instead of jumping
    /// between two discrete font sizes.
    private var heroCounterScale: CGFloat { isResults ? resultsRingDiameter / scanRingDiameter : 1 }

    private var heroRingState: ScanRingState {
        switch displayPhase {
        case .idle, .failed: .idle
        case .scanning: .scanning
        case .settling, .results: .complete
        }
    }

    private var heroScreen: some View {
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    heroRing
                        .padding(.horizontal, SweepTokens.s5)
                        .padding(.top, SweepTokens.s5)
                    heroBelow
                    Color.clear.frame(height: isResults ? SweepTokens.s2 : SweepTokens.s5)
                }
                // Short results sit centred in the pane; long ones scroll from the top. Idle and
                // scanning are always short, so this centers them exactly as a fixed VStack would.
                .frame(maxWidth: .infinity, minHeight: proxy.size.height, alignment: .center)
            }
            .scrollDisabled(!isResults)
        }
    }

    /// The one `ScanRing`/`HeroByteCounter` pair for the entire screen's lifetime. See the type
    /// doc: this call site never sits inside an `if`/`switch` keyed on `displayPhase`, so it is
    /// never torn down and remounted by a phase change — only `heroDiameter`/`heroRingState`/the
    /// counter's own inputs move, and they move on ordinary animatable state.
    private var heroRing: some View {
        ScanRing(state: heroRingState, diameter: heroDiameter, progress: scan.progress) {
            // Idle shows an empty ring (no glyph): the invitation is the Scan button below.
            if displayPhase != .idle {
                HeroByteCounter(
                    // Safe-tier bytes only once the ring lands (PLAN §6b): the counter settles
                    // to the number that is both the hero total and the clean scope, not the raw
                    // scan total scanning was showing a moment before.
                    byteCount: isSettled ? scan.safeBytes : scan.claimedBytes,
                    size: scanRingDiameter * 0.235,
                    label: isSettled ? (scan.wasCancelled ? "Found so far" : "Ready to clean") : nil,
                    caption: isSettled ? scan.safeResultsCaption : scan.scanningCaption
                )
                .scaleEffect(heroCounterScale)
            }
        }
        // A soft accent bloom behind the ring for depth (Palette v2 volume-raise); skipped while
        // idle so an untouched screen stays completely calm.
        .background {
            if displayPhase != .idle {
                Circle()
                    .fill(SweepTokens.heroGlow)
                    .frame(width: heroDiameter * 1.5, height: heroDiameter * 1.5)
                    .allowsHitTesting(false)
            }
        }
    }

    /// Phase-specific chrome below the ring. Safe to branch on `displayPhase` here — none of
    /// this holds animation state that motion continuity depends on; only `heroRing` does.
    @ViewBuilder
    private var heroBelow: some View {
        switch displayPhase {
        case .idle:
            idleBelow
        case .scanning, .settling:
            scanningBelow
        case .results:
            resultsBelow
        case .failed:
            EmptyView()
        }
    }

    private var idleBelow: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: SweepTokens.s6)
            Button("Scan") { scan.start() }
                .buttonStyle(.sweepPrimary)
                .keyboardShortcut(.defaultAction)
            Spacer().frame(height: SweepTokens.s3)
            Text("Reads your caches, logs and developer junk. Nothing is deleted.")
                .font(SweepFont.screenSubtitle)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, SweepTokens.s5)
    }

    private var scanningBelow: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: SweepTokens.s5)
            PathTicker(path: isSettled ? nil : scan.currentPath)
            Spacer().frame(height: SweepTokens.s5)
            Button("Stop") { scan.cancel() }
                .buttonStyle(.sweepQuiet)
                .keyboardShortcut(.cancelAction)
                .disabled(isSettled)
                .opacity(isSettled ? 0 : 1)
        }
        .padding(.horizontal, SweepTokens.s5)
    }

    // MARK: - Results

    /// Everything results shows beneath the (already on-screen, already-shrinking) ring: it
    /// mounts fresh at `.results` and slides/fades in under the live ring rather than the ring
    /// itself ever remounting.
    @ViewBuilder
    private var resultsBelow: some View {
        VStack(spacing: SweepTokens.s5) {
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
        }
        .padding(.top, SweepTokens.s5)
        .transition(.opacity.combined(with: .move(edge: .top)))
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
