import SweepSystem
import SweepUninstall
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
    /// Routes to the Uninstaller for the "Also found: leftovers from uninstalled apps" card —
    /// Smart Scan surfaces the finding, the Uninstaller owns review and removal.
    let onReviewOrphans: () -> Void

    /// Non-nil while the Clean flow's sheet is up. Built fresh from `scan` each time the button
    /// is pressed rather than kept around, so a rescan between clean runs can never hand a stale
    /// request to a flow already in flight.
    @State private var cleanFlow: CleanFlowModel?
    @State private var orphanFind = OrphanFindModel()
    @State private var emptyTrash = EmptyTrashModel()

    /// Pause ambient idle motion (breathing bloom, aurora drift) with the same occlusion switch
    /// that stops the scan sweep — nothing breathes where nobody can see it.
    @Environment(\.sweepAnimationsEnabled) private var animationsEnabled

    /// The idle hero's disk gauge: free/total for the volume the scan would clean, read once per
    /// mount off the main actor. `nil` until it lands (microseconds — statfs-level work), during
    /// which the ring shows its empty track and the counter stays hidden; the gauge arc then
    /// draws in and the free-space number rolls up, which is the idle screen's entrance beat.
    @State private var disk: DiskGauge?

    private struct DiskGauge: Equatable {
        let freeBytes: Int64
        let totalBytes: Int64
        let usedFraction: Double
        let volumeName: String
    }

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
    // Scale v3: the scanning hero owns an otherwise-empty pane and earns real presence; results
    // keep a step down so the result list still gets the room. (An earlier 120 pt results ring
    // was rejected as "so small nobody can see it" — never shrink below ~240.)
    private let scanRingDiameter: CGFloat = 300
    private let resultsRingDiameter: CGFloat = 260

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
                HStack(spacing: SweepTokens.s2) {
                    // PLAN §3 module 1: Empty Trash is its own explicitly irreversible flow —
                    // never part of the scan's clean, reachable regardless of scan phase.
                    Button("Empty Trash\u{2026}") { emptyTrash.openReview() }
                        .buttonStyle(.sweepQuiet)
                    if displayPhase == .results {
                        Button("Rescan") { scan.rescan() }
                            .buttonStyle(.sweepQuiet)
                    }
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
        .task {
            let home = scan.homeURL
            let stats = await Task.detached(priority: .utility) { DiskStatsReader.read(volumeURL: home) }.value
            guard let stats, stats.totalBytes > 0 else { return }
            // Animated assignment so the counter fades in on the same beat the gauge arc draws.
            withAnimation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout) {
                disk = DiskGauge(
                    freeBytes: Int64(stats.availableBytes),
                    totalBytes: Int64(stats.totalBytes),
                    usedFraction: Double(stats.totalBytes - stats.availableBytes) / Double(stats.totalBytes),
                    volumeName: stats.volumeName
                )
            }
        }
        .onChange(of: scan.phase) { _, newPhase in
            syncDisplayPhase()
            if newPhase == .results { orphanFind.refresh() }
        }
        .sheet(isPresented: Bindable(emptyTrash).sheetShown) {
            EmptyTrashSheet(model: emptyTrash)
        }
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
    /// The one number the hero shows per phase. Idle is the disk gauge's free space — the ring
    /// finally says something before a scan runs; scanning is the raw claimed total; settled is
    /// safe-tier bytes only (PLAN §6b): the counter lands on the number that is both the hero
    /// total and the clean scope, not the raw scan total scanning was showing a moment before.
    /// One call site, parameters only, same continuity rule as the ring itself — starting a scan
    /// rolls the free-space figure down to the climbing claimed total on the counter's own
    /// spring, never a remount.
    private var heroCounterBytes: Int64 {
        if displayPhase == .idle { return disk?.freeBytes ?? 0 }
        return isSettled ? scan.safeBytes : scan.claimedBytes
    }

    private var heroCounterLabel: String? {
        if displayPhase == .idle { return "Free" }
        return isSettled ? (scan.wasCancelled ? "Found so far" : "Ready to clean") : nil
    }

    private var heroCounterCaption: String? {
        if displayPhase == .idle {
            guard let disk else { return nil }
            return "of \(SweepFormat.bytes(disk.totalBytes)) \u{00B7} \(disk.volumeName)"
        }
        return isSettled ? scan.safeResultsCaption : scan.scanningCaption
    }

    private var heroRing: some View {
        ScanRing(
            state: heroRingState,
            diameter: heroDiameter,
            progress: scan.progress,
            // The idle ring is a live gauge of the volume the scan would clean, not an empty
            // track (user-directed: the untouched hero read as "a dud... nothing the user can
            // understand"). Passed only at idle so the scan arc's own 0→1 story stays untouched.
            idleFraction: displayPhase == .idle ? disk?.usedFraction : nil
        ) {
            // Hidden (not absent) until the gauge lands, so the counter never remounts across
            // the idle→scanning edge — see the type doc's one-call-site rule.
            HeroByteCounter(
                byteCount: heroCounterBytes,
                size: scanRingDiameter * 0.235,
                label: heroCounterLabel,
                caption: heroCounterCaption
            )
            .scaleEffect(heroCounterScale)
            .opacity(displayPhase == .idle && disk == nil ? 0 : 1)
        }
        // Two ambient layers behind the ring, both hue-family-only (no second color story):
        // the aurora — two big soft radial washes drifting on a slow autoreversing cycle — and
        // the accent bloom, which breathes at idle and holds steady once real progress owns the
        // motion. The aurora fades out at results so the cards land on a calm ground.
        .background {
            ZStack {
                AuroraBackdrop(drifting: !isResults && animationsEnabled && !reduceMotion)
                    .opacity(isResults ? 0 : 1)
                HeroBloom(
                    diameter: heroDiameter * 1.5,
                    breathing: displayPhase == .idle && animationsEnabled && !reduceMotion
                )
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

    /// The idle invitation (user-directed rebuild: the old empty-ring-plus-button hero "looks
    /// like a dud"). Now: the gauge ring above says what the disk holds, the hero CTA carries the
    /// gradient, the coverage chips say in module color what a scan actually looks at, and the
    /// recall line says what the last one found. All of it is true content, none of it padding.
    private var idleBelow: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: SweepTokens.s6)
            Button("Scan") { scan.start() }
                .buttonStyle(.sweepHero)
                .keyboardShortcut(.defaultAction)
            Spacer().frame(height: SweepTokens.s3 + 2)
            Text("Reads your caches, logs and developer junk. Nothing is deleted.")
                .font(SweepFont.screenSubtitle)
                .foregroundStyle(.secondary)
            Spacer().frame(height: SweepTokens.s6)
            idleCoverage
            if let recall = scan.lastScanRecall, displayPhase == .idle {
                Spacer().frame(height: SweepTokens.s4 + 4)
                lastScanLine(recall)
            }
        }
        .padding(.horizontal, SweepTokens.s5)
    }

    /// What Smart Scan covers, as three module-hued chips — the same wayfinding colors the
    /// sidebar teaches, so "Caches & logs is the blue module, Developer junk the lavender one"
    /// reads before the first scan ever runs.
    private static let coverage: [(symbol: String, title: String, caption: String)] = [
        ("bubbles.and.sparkles", "Caches & logs", "App and system leftovers"),
        ("chevron.left.forwardslash.chevron.right", "Developer junk", "Old builds and caches"),
        ("app.dashed", "App leftovers", "Files from deleted apps"),
    ]

    private var idleCoverage: some View {
        HStack(spacing: SweepTokens.s3) {
            ForEach(Array(Self.coverage.enumerated()), id: \.offset) { index, entry in
                CoverageChip(symbol: entry.symbol, title: entry.title, caption: entry.caption)
                    .staggeredEntrance(index)
            }
        }
    }

    private static let recallFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    private func lastScanLine(_ recall: ScanModel.LastScanRecall) -> some View {
        HStack(spacing: SweepTokens.s1 + 2) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 12, weight: .medium))
            Text("Last scan found \(SweepFormat.bytes(recall.safeBytes)) ready to clean \u{00B7} \(Self.recallFormatter.localizedString(for: recall.finishedAt, relativeTo: .now))")
                .font(SweepFont.caption)
        }
        .foregroundStyle(.tertiary)
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
                    title: "Nothing to clean",
                    message: "Nothing in the folders Sweep can read needs attention right now."
                )
                .frame(height: 160)
            } else {
                if scan.safeSummaryGroups.isEmpty {
                    InventoryEmptyState(
                        symbol: "checkmark.circle",
                        title: "Nothing safe to clean automatically",
                        message: "Everything found needs a closer look first. See Needs review below."
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

            alsoFound

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
                    .font(.system(size: 13, weight: .medium))
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

    /// The pass the rule catalog cannot express (user-directed: "Smart Scan is currently the
    /// same as System Junk scan"): files left behind by apps that are no longer installed,
    /// found by the Uninstaller's own orphan matcher. Read-only pointer here — per-item
    /// evidence, selection and removal stay in the Uninstaller's orphan mode.
    @ViewBuilder
    private var alsoFound: some View {
        if orphanFind.isSearching || (orphanFind.finding?.count ?? 0) > 0 {
            VStack(alignment: .leading, spacing: SweepTokens.s2) {
                HStack(spacing: SweepTokens.s2 - 2) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("Also found")
                        .font(SweepFont.sectionTitle)
                        .foregroundStyle(.primary)
                }
                SectionCard {
                    HStack(spacing: SweepTokens.s3) {
                        ModuleIcon(symbol: "app.dashed", diameter: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Leftovers from uninstalled apps")
                                .font(SweepFont.rowTitleEmphasis)
                                .lineLimit(1)
                            Text(orphanCaption)
                                .font(SweepFont.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: SweepTokens.s3)
                        if orphanFind.isSearching {
                            ProgressView().controlSize(.small)
                        } else if let finding = orphanFind.finding {
                            SizeColumn(byteCount: finding.totalBytes, font: SweepFont.monoEmphasis, emphasized: true)
                            Button("Review") { onReviewOrphans() }
                                .buttonStyle(.sweepQuiet)
                        }
                    }
                    .padding(SweepTokens.s4)
                }
            }
            .padding(.horizontal, SweepTokens.s5)
        }
    }

    private var orphanCaption: String {
        if orphanFind.isSearching { return "Checking for files apps left behind\u{2026}" }
        guard let finding = orphanFind.finding else { return "" }
        let sample = finding.sampleBundleIDs.joined(separator: ", ")
        let count = "\(SweepFormat.count(finding.count)) \(finding.count == 1 ? "item" : "items")"
        return sample.isEmpty ? count : "\(count) \u{00B7} \(sample)"
    }

    private var resultsFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: SweepTokens.s3) {
                Button("Clean") { startClean() }
                    .buttonStyle(.sweepPrimary(minWidth: 108))
                    .disabled(!CleanAdapter.isEnabled || scan.safeSummaryGroups.isEmpty)
                    .help(CleanAdapter.isEnabled ? "Move the safe-tier items to Trash" : "Cleaning is not available in this build")
                    .accessibilityHint(CleanAdapter.isEnabled ? "" : "Disabled. Cleaning is not available in this build.")
                if !CleanAdapter.isEnabled {
                    GateNotice("Cleaning is not available in this build")
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
                CleanFlowContainer(model: cleanFlow, onRescan: { scan.rescan() }) { self.cleanFlow = nil }
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

// MARK: - Ambient hero layers (idle volume-raise)

/// The accent halo behind the hero ring. While `breathing` it swells and dims on a slow
/// autoreversing ease — ambient, sub-perceptual-speed motion, the idle screen's pulse; otherwise
/// it holds the same static bloom scanning and results always had. The repeating animation is
/// keyed off `swell` and replaced with an instant one on stop, so occlusion
/// (`sweepAnimationsEnabled`) genuinely halts the render-thread work rather than hiding it.
private struct HeroBloom: View {
    let diameter: CGFloat
    let breathing: Bool

    @State private var swell = false
    /// Read so appearance flips re-evaluate this body: `SweepTokens.adaptive` colors resolve at
    /// body-run time and are not themselves live-reactive (see the token's doc) — without a
    /// tracked `colorScheme` dependency, a subtree with no changing state keeps its launch
    /// appearance. Same mechanism `SectionCard` relies on.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Circle()
            .fill(SweepTokens.heroGlow)
            .frame(width: diameter, height: diameter)
            .scaleEffect(breathing ? (swell ? 1.08 : 0.94) : 1)
            // The bloom carries a touch more presence on a dark ground, where 14% accent barely
            // registers against near-black.
            .opacity((breathing ? (swell ? 1 : 0.55) : 1) * (colorScheme == .dark ? 1 : 0.9))
            .allowsHitTesting(false)
            .onAppear { sync() }
            .onChange(of: breathing) { _, _ in sync() }
    }

    private func sync() {
        if breathing {
            withAnimation(.easeInOut(duration: 3.4).repeatForever(autoreverses: true)) { swell = true }
        } else {
            // Replacing the repeatForever with a zero-duration animation is what cancels it.
            withAnimation(.linear(duration: 0)) { swell = false }
        }
    }
}

/// Two large, soft radial washes — accent and its violet neighbour — drifting slowly behind the
/// hero on an autoreversing cycle. Radial gradients that fade to clear, not blurred shapes: the
/// wash look with zero per-frame blur cost. Same hue family as everything else kinetic; at these
/// opacities it tints the ground rather than competing with the ring.
private struct AuroraBackdrop: View {
    let drifting: Bool

    @State private var drift = false
    /// Tracked appearance dependency — see `HeroBloom`. Also real tuning: the washes need a few
    /// more points of opacity to register on the dark ground.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let strength = colorScheme == .dark ? 1.25 : 1.0
        ZStack {
            RadialGradient(
                colors: [SweepTokens.accent.opacity(0.14 * strength), .clear],
                center: .center, startRadius: 12, endRadius: 250
            )
            .frame(width: 520, height: 520)
            .offset(x: drift ? -170 : -100, y: drift ? -70 : -140)

            RadialGradient(
                colors: [SweepTokens.accentViolet.opacity(0.12 * strength), .clear],
                center: .center, startRadius: 12, endRadius: 270
            )
            .frame(width: 560, height: 560)
            .offset(x: drift ? 180 : 110, y: drift ? 90 : 150)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .onAppear { sync() }
        .onChange(of: drifting) { _, _ in sync() }
    }

    private func sync() {
        if drifting {
            withAnimation(.easeInOut(duration: 11).repeatForever(autoreverses: true)) { drift = true }
        } else {
            withAnimation(.linear(duration: 0)) { drift = false }
        }
    }
}

/// One "what a scan covers" chip: module icon in its hue, title, plain-language one-liner, with
/// the app's standard hover lift. A card the user can read, not a decoration.
private struct CoverageChip: View {
    let symbol: String
    let title: String
    let caption: String

    @State private var hovering = false
    /// Tracked appearance dependency — see `HeroBloom`. This was the visible failure: chips with
    /// no changing state rendered their launch appearance's card color into the other appearance.
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: SweepTokens.s3) {
            ModuleIcon(symbol: symbol, diameter: 34)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.primary)
                Text(caption)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
        }
        .padding(.vertical, SweepTokens.s3)
        .padding(.horizontal, SweepTokens.s4)
        .background {
            RoundedRectangle(cornerRadius: SweepTokens.cornerRadius, style: .continuous)
                .fill(SweepTokens.cardBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: SweepTokens.cornerRadius, style: .continuous)
                .strokeBorder(SweepTokens.hairline, lineWidth: 1)
        }
        .shadow(
            // Hue-tinted lift, `ModuleIcon`'s treatment at card scale — a touch stronger on the
            // dark ground where a soft glow is doing all the separation work.
            color: (SweepModuleHue.color(forSymbol: symbol) ?? SweepTokens.accent)
                .opacity((hovering ? 0.22 : 0.10) * (colorScheme == .dark ? 1.5 : 1)),
            radius: hovering ? 12 : 6, y: 3
        )
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(SweepMotion.row, value: hovering)
        .onHover { hovering = $0 }
    }
}

// MARK: - Orphan discovery (the "Also found" card's data)

/// Runs the Uninstaller's orphan matcher once per finished scan: installed-app inventory,
/// leftover roots walked with the matcher's own defaults, sizes summed per candidate. Kept
/// deliberately independent of `UninstallModel` — Smart Scan must not force the Uninstaller's
/// whole prefetch machinery (app icons, receipts cache, root index) to spin up just to answer
/// "is there anything orphaned worth pointing at".
@MainActor
@Observable
final class OrphanFindModel {
    struct Finding: Equatable, Sendable {
        let count: Int
        let totalBytes: Int64
        /// Up to three distinct bundle ids, for the card's one-line caption.
        let sampleBundleIDs: [String]
    }

    private(set) var finding: Finding?
    private(set) var isSearching = false
    private var task: Task<Void, Never>?

    func refresh() {
        task?.cancel()
        isSearching = true
        finding = nil
        task = Task {
            let result = await Task.detached(priority: .utility) { () -> Finding in
                let installed = Set(AppInventory.scan().compactMap(\.bundleIdentifier))
                let orphans = LeftoverMatcher.orphanCandidates(installedBundleIDs: installed)
                var bytes: Int64 = 0
                for orphan in orphans {
                    bytes += FileSizeCalculator.allocatedSize(at: orphan.url)
                }
                var seen = Set<String>()
                var sample: [String] = []
                for orphan in orphans where seen.insert(orphan.apparentBundleID).inserted {
                    sample.append(orphan.apparentBundleID)
                    if sample.count == 3 { break }
                }
                return Finding(count: orphans.count, totalBytes: bytes, sampleBundleIDs: sample)
            }.value
            guard !Task.isCancelled else { return }
            finding = result
            isSearching = false
        }
    }
}
