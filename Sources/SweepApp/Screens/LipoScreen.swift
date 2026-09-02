import AppKit
import Observation
import SweepUI
import SwiftUI

// MARK: - Model

enum LipoPhase: Equatable {
    case idle
    case scanning
    case results
}

/// Drives App Lipo (PLAN's queued "Lipo" hub module — strip unused architecture slices, PearCleaner
/// parity). Discovery/measurement (`LipoEngine.scan`) is read-only and runs off-main; the one
/// mutation this screen offers (`LipoThinningService.thin`) is preview-first — `pendingThinTarget`
/// is never set without the confirm dialog immediately backing it, and confirming is the only path
/// that ever calls into the engine's thin action, matching the same preview-first discipline
/// `HomebrewModel` uses for its own mutations.
///
/// Standalone by design (task constraint: this screen must compile and be reachable with no
/// navigation wiring) — it owns its own model rather than being handed one, exactly like
/// `LargeOldFilesScreen` owning `LargeFilesModel` via `@State`.
@MainActor
@Observable
final class LipoModel {
    private(set) var phase: LipoPhase = .idle
    private(set) var rows: [LipoAppRow] = []
    private(set) var intelOnlyCount = 0
    /// Finished thin attempts, by bundle path. A row with an entry here renders its state chip
    /// instead of the Thin button; the underlying `LipoAppRow` is left untouched in `rows` so a
    /// failed attempt can still show its original savings estimate alongside the failure.
    private(set) var outcomesByID: [String: LipoThinOutcome] = [:]
    /// Bundle paths with a thin in flight right now — disables that one row's button without
    /// touching any other row, same one-row-at-a-time-is-fine reasoning `HomebrewModel` applies to
    /// per-package upgrades (each is an independent `lipo`/`codesign` invocation against a
    /// different bundle; there is no shared resource for two to contend on).
    private(set) var thinningIDs: Set<String> = []

    /// Set the instant the user taps Thin; drives the confirm dialog. Never set anywhere else —
    /// there is no code path that reaches `LipoThinningService.thin` without this having been
    /// shown and explicitly confirmed first.
    var pendingThinTarget: LipoAppRow?
    /// Whether the pending target's bundle is one this process cannot write into (root-owned
    /// installer-package apps) — probed at request time so the confirm dialog can say up front
    /// that macOS will ask for an administrator password, instead of the prompt appearing
    /// unannounced.
    private(set) var pendingThinNeedsAdmin = false

    /// Drives the Thin All confirm dialog, same never-set-anywhere-else discipline as
    /// `pendingThinTarget`.
    var thinAllRequested = false
    private(set) var thinAllNeedsAdmin = false

    private var scanTask: Task<Void, Never>?

    /// Sum of every listed row's estimated savings, excluding rows already successfully thinned
    /// (a failed attempt changed nothing on disk, so its savings are still real and still counted).
    var totalReclaimableBytes: Int64 {
        rows.reduce(into: Int64(0)) { total, row in
            if let outcome = outcomesByID[row.id], outcome.succeeded { return }
            total += row.savingsBytes
        }
    }

    var resultsCaption: String {
        let noun = rows.count == 1 ? "universal app" : "universal apps"
        return "\(SweepFormat.count(rows.count)) \(noun) found"
    }

    var intelOnlyFootnote: String? {
        guard intelOnlyCount > 0 else { return nil }
        let noun = intelOnlyCount == 1 ? "app runs" : "apps run"
        return "\(SweepFormat.count(intelOnlyCount)) Intel-only \(noun) under Rosetta \u{2014} nothing to thin; there is no arm64 code to keep."
    }

    func icon(for row: LipoAppRow) -> NSImage {
        NSWorkspace.shared.icon(forFile: row.bundlePath.path)
    }

    /// Live query, deliberately never cached: the same contract `RunningAppChecker.isRunning`
    /// keeps for the Uninstaller, so an app launched after the scan finished still disables its
    /// own row the moment the view re-evaluates, and re-verified again right before the mutation
    /// itself in `confirmPendingThin()`.
    func isRunning(_ row: LipoAppRow) -> Bool {
        let runningPaths = Set(NSWorkspace.shared.runningApplications.compactMap {
            $0.bundleURL?.resolvingSymlinksInPath().path
        })
        return LipoProtection.isRunning(bundlePath: row.bundlePath, runningBundlePaths: runningPaths)
    }

    func isThinning(_ row: LipoAppRow) -> Bool {
        thinningIDs.contains(row.id)
    }

    func outcome(for row: LipoAppRow) -> LipoThinOutcome? {
        outcomesByID[row.id]
    }

    /// Idempotent auto-scan entry point: the screen calls this from `.task` on every appearance
    /// (user-directed: no Scan button — discovery is read-only and fast, so it just happens).
    /// Guarded to the idle phase so SwiftUI re-evaluating the view can never restart a scan
    /// that is already running or throw away results mid-look.
    func scanIfNeeded() {
        guard phase == .idle else { return }
        scan()
    }

    func scan() {
        guard scanTask == nil else { return }
        phase = .scanning
        outcomesByID = [:]
        thinningIDs = []
        scanTask = Task {
            let outcome = await Task.detached(priority: .utility) {
                LipoEngine.scan()
            }.value
            guard !Task.isCancelled else { return }
            rows = outcome.rows
            intelOnlyCount = outcome.intelOnlyCount
            phase = .results
            scanTask = nil
        }
    }

    /// Refuses outright for a protected or currently-running app — mirrors the Uninstaller's
    /// `select(_:)`, which never even shows a confirm sheet for a protected app rather than
    /// showing one it would then have to refuse.
    func requestThin(_ row: LipoAppRow) {
        guard !row.isProtected, !isRunning(row) else { return }
        pendingThinNeedsAdmin = {
            guard let executableURL = Bundle(url: row.bundlePath)?.executableURL else { return false }
            return !LipoWriteAccess.canWriteAlongside(executableURL: executableURL)
        }()
        pendingThinTarget = row
    }

    func cancelPendingThin() {
        pendingThinTarget = nil
    }

    func confirmPendingThin() {
        guard let row = pendingThinTarget else { return }
        pendingThinTarget = nil
        // Re-checked at the last possible moment, same reasoning as the guard inside
        // `LipoThinningService.thin` itself re-parsing every file instead of trusting the scan:
        // the confirm dialog could have sat open for a while before this ran.
        guard !row.isProtected, !isRunning(row) else { return }
        thinningIDs.insert(row.id)
        Task {
            let outcome = await LipoThinningService.thin(appAt: row.bundlePath)
            thinningIDs.remove(row.id)
            outcomesByID[row.id] = outcome
        }
    }

    // MARK: Thin All

    /// Every row a Thin All would act on right now: not protected, not running, not already
    /// successfully thinned. Running apps are simply left out — their RUNNING chip already says
    /// why — rather than failing the whole batch over one open app.
    var thinAllEligibleRows: [LipoAppRow] {
        rows.filter { row in
            !row.isProtected && !(outcomesByID[row.id]?.succeeded ?? false) && !isRunning(row)
        }
    }

    var thinAllEligibleSavings: Int64 {
        thinAllEligibleRows.reduce(0) { $0 + $1.savingsBytes }
    }

    var isThinningAny: Bool { !thinningIDs.isEmpty }

    func requestThinAll() {
        let eligible = thinAllEligibleRows
        guard !eligible.isEmpty, !isThinningAny else { return }
        thinAllNeedsAdmin = eligible.contains { row in
            guard let executableURL = Bundle(url: row.bundlePath)?.executableURL else { return false }
            return !LipoWriteAccess.canWriteAlongside(executableURL: executableURL)
        }
        thinAllRequested = true
    }

    func confirmThinAll() {
        thinAllRequested = false
        // Eligibility re-derived at confirm time — an app launched while the dialog sat open
        // drops out here, same last-moment discipline as the single-row path.
        let targets = thinAllEligibleRows
        guard !targets.isEmpty, !isThinningAny else { return }
        for row in targets { thinningIDs.insert(row.id) }
        Task {
            let outcomes = await LipoThinningService.thinAll(appsAt: targets.map(\.bundlePath))
            for (id, outcome) in outcomes { outcomesByID[id] = outcome }
            for row in targets { thinningIDs.remove(row.id) }
        }
    }
}

// MARK: - Screen

/// App Lipo: finds universal (fat) app binaries, shows how much disk their non-native slice
/// wastes, and thins them to arm64 on demand (PearCleaner "app slimming" parity).
///
/// Read-only discovery, one preview-first mutation. Irreversible once confirmed — there is no
/// Trash copy of a removed Intel slice — which is why the confirm dialog states that plainly
/// before the first thin, per the task spec, rather than relying on a "destructive button color"
/// alone to carry that weight.
struct LipoScreen: View {
    @State private var model = LipoModel()

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                title: "App Lipo",
                subtitle: "Trim Intel-only code from universal apps. Apple-signed apps are never touched."
            ) {
                // No Scan button (user-directed): discovery is read-only header parsing, fast
                // enough to just run on every visit — the spinner is the only scan UI there is.
                if model.phase == .scanning {
                    ProgressView().controlSize(.small)
                } else if model.phase == .results, !model.thinAllEligibleRows.isEmpty {
                    Button("Thin All") { model.requestThinAll() }
                        .buttonStyle(.sweepDestructive(minWidth: 84))
                        .disabled(model.isThinningAny)
                        .fixedSize()
                        .confirmationDialog(
                            thinAllTitle,
                            isPresented: Binding(
                                get: { model.thinAllRequested },
                                set: { if !$0 { model.thinAllRequested = false } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button("Thin All", role: .destructive) { model.confirmThinAll() }
                            Button("Cancel", role: .cancel) { model.thinAllRequested = false }
                        } message: {
                            Text(thinAllMessage)
                        }
                }
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .animation(SweepMotion.layout, value: model.phase)
        .task { model.scanIfNeeded() }
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(
                get: { model.pendingThinTarget != nil },
                set: { if !$0 { model.cancelPendingThin() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Thin", role: .destructive) { model.confirmPendingThin() }
            Button("Cancel", role: .cancel) { model.cancelPendingThin() }
        } message: {
            Text(confirmMessage)
        }
    }

    private var confirmTitle: String {
        "Thin \u{201C}\(model.pendingThinTarget?.name ?? "this app")\u{201D}?"
    }

    private var thinAllTitle: String {
        let count = model.thinAllEligibleRows.count
        return "Thin \(count == 1 ? "1 app" : "\(count) apps")?"
    }

    private var thinAllMessage: String {
        var message = "Removes the Intel portion from every listed app that isn\u{2019}t running. "
            + "Frees ~\(SweepFormat.bytes(model.thinAllEligibleSavings)). "
            + "Cannot be undone; each app is re-signed locally afterward."
        if model.thinAllNeedsAdmin {
            message += " One administrator password approves all system-installed apps together."
        }
        return message
    }

    private var confirmMessage: String {
        let savings = SweepFormat.bytes(model.pendingThinTarget?.savingsBytes ?? 0)
        var message = "Removes the Intel portion of its code. Frees ~\(savings). "
            + "Cannot be undone; the app is re-signed locally afterward."
        if model.pendingThinNeedsAdmin {
            message += " This app is installed by the system, so macOS will ask for an administrator password."
        }
        return message
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle, .scanning:
            // `.idle` lasts only until the `.task` below fires, so both phases read as the scan
            // already being underway — there is no "No scan yet" state a user can reach.
            InventoryEmptyState(symbol: "square.stack.3d.up", title: "Scanning installed apps\u{2026}")
        case .results:
            if model.rows.isEmpty {
                InventoryEmptyState(
                    symbol: "checkmark.circle",
                    title: "No universal apps found",
                    message: model.intelOnlyFootnote ?? "Every app on this Mac is already arm64-only."
                )
            } else {
                ScrollView {
                    VStack(spacing: SweepTokens.s5) {
                        heroLine
                        resultsCard
                    }
                    .padding(SweepTokens.s5)
                }
            }
        }
    }

    private var heroLine: some View {
        HeroByteCounter(byteCount: model.totalReclaimableBytes, size: 44, label: "Reclaimable")
    }

    private var resultsCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SweepTokens.s2) {
                    Text("Universal Apps")
                        .font(SweepFont.sectionTitle)
                        .foregroundStyle(.secondary)
                    Text(SweepFormat.itemCount(model.rows.count))
                        .font(SweepFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                    Spacer()
                }
                .padding(.horizontal, SweepTokens.s4)
                .padding(.top, SweepTokens.s4)
                .padding(.bottom, SweepTokens.s2)

                ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                    LipoAppRowView(
                        row: row,
                        icon: model.icon(for: row),
                        isRunning: model.isRunning(row),
                        isThinning: model.isThinning(row),
                        outcome: model.outcome(for: row),
                        onThin: { model.requestThin(row) }
                    )
                    .padding(.horizontal, SweepTokens.s3 - 2)
                }
            }
            .padding(.bottom, SweepTokens.s2)
        }
    }

    private var footer: some View {
        Group {
            if model.phase == .results, !model.rows.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    VStack(alignment: .leading, spacing: SweepTokens.s1) {
                        Footnote(
                            "Thinning removes code for CPUs this Mac doesn\u{2019}t have. Apps update themselves "
                                + "back to universal when their developer ships an update.",
                            symbol: "info.circle"
                        )
                        if let intelOnlyFootnote = model.intelOnlyFootnote {
                            Footnote(intelOnlyFootnote, symbol: "cpu")
                        }
                    }
                    .padding(.horizontal, SweepTokens.s5)
                    .padding(.vertical, SweepTokens.s3)
                }
                .background(.bar)
            }
        }
    }
}

// MARK: - Row

/// One universal app: real app icon, name, architecture summary, right-aligned mono savings
/// column, and a destructive Thin action — or, once thinned, a state chip in its place.
private struct LipoAppRowView: View {
    let row: LipoAppRow
    let icon: NSImage
    let isRunning: Bool
    let isThinning: Bool
    let outcome: LipoThinOutcome?
    let onThin: () -> Void

    var body: some View {
        HStack(spacing: SweepTokens.s3) {
            Image(nsImage: icon)
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: SweepTokens.s1) {
                    Text(row.name)
                        .font(SweepFont.rowTitleEmphasis)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if row.isProtected {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.tertiary)
                    }
                    if isRunning {
                        LipoRunningChip()
                    }
                }
                Text(architectureSummary)
                    .font(SweepFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                // A failure's reason lives in the row itself, not only behind the chip's hover
                // tooltip — "Thin failed" alone is exactly the opaque dead-end the first
                // real-world run of this screen produced.
                if let outcome, !outcome.succeeded {
                    Text(outcome.message)
                        .font(SweepFont.caption)
                        .foregroundStyle(SweepTokens.tierExpert)
                        .lineLimit(2)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: SweepTokens.s3)

            trailing
        }
        .padding(.horizontal, SweepTokens.s3 - 2)
        .frame(minHeight: SweepTokens.inventoryRowHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(row.name)\(row.isProtected ? ", protected" : "")\(isRunning ? ", running" : "")")
    }

    private var architectureSummary: String {
        "Universal \u{2014} " + row.architectures.joined(separator: " + ")
    }

    @ViewBuilder
    private var trailing: some View {
        if let outcome, outcome.succeeded {
            LipoOutcomeChip(outcome: outcome)
        } else {
            // A failed attempt keeps its Thin button: the failure is stated in the row's own
            // caption, and most failures (a canceled password prompt, an app quit since) are
            // exactly the kind a second attempt resolves.
            HStack(spacing: SweepTokens.s3) {
                if let outcome {
                    LipoOutcomeChip(outcome: outcome)
                } else {
                    Text(SweepFormat.bytes(row.savingsBytes))
                        .font(SweepFont.monoEmphasis)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize()
                        .frame(width: SweepTokens.sizeColumnWidth, alignment: .trailing)
                }

                if isThinning {
                    ProgressView()
                        .controlSize(.small)
                        .frame(width: 70)
                } else {
                    Button("Thin", action: onThin)
                        .buttonStyle(.sweepDestructive(minWidth: 70))
                        .disabled(row.isProtected || isRunning)
                        .help(disabledHint)
                        .accessibilityHint(disabledHint)
                }
            }
        }
    }

    private var disabledHint: String {
        if row.isProtected { return "Protected \u{2014} Sweep never touches Apple-signed or system apps." }
        if isRunning { return "Quit \(row.name) first." }
        return ""
    }
}

/// Layout contract: badges/chips are atoms — `.lineLimit(1).fixedSize()`, never wrapped — and the
/// name beside them truncates instead (same rule `RunningChip`/`BrokenBadge` follow elsewhere).
private struct LipoRunningChip: View {
    var body: some View {
        Text("RUNNING")
            .font(SweepFont.badge)
            .tracking(0.5)
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(SweepTokens.tierCaution)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(SweepTokens.tierCaution.opacity(0.12)))
    }
}

/// The row's post-action state: a freed-bytes chip on success, a plain failure flag on error —
/// full detail lives in `.help`, not crammed into the chip text itself.
private struct LipoOutcomeChip: View {
    let outcome: LipoThinOutcome

    var body: some View {
        HStack(spacing: SweepTokens.s1) {
            Image(systemName: outcome.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 11, weight: .semibold))
            Text(outcome.succeeded ? "Thinned \u{2014} freed \(SweepFormat.bytes(outcome.freedBytes))" : "Thin failed")
        }
        .font(SweepFont.badge)
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(outcome.succeeded ? SweepTokens.tierSafe : SweepTokens.tierExpert)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Capsule().fill((outcome.succeeded ? SweepTokens.tierSafe : SweepTokens.tierExpert).opacity(0.12))
        )
        .help(outcome.message)
        .accessibilityLabel(outcome.succeeded ? "Thinned, freed \(SweepFormat.bytes(outcome.freedBytes))" : "Thin failed: \(outcome.message)")
    }
}
