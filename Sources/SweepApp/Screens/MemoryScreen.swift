import AppKit
import Darwin
import SweepSystem
import SweepUI
import SwiftUI

// MARK: - Pure logic (unit-testable; see Tests/SweepAppTests/MemoryScreenLogicTests.swift)

/// What happened after a normal `terminate()` call, and what the screen should do next.
///
/// Named separately from a bare `Bool` so the policy this module must follow — PLAN §3: "confirm
/// non-responding apps via forceTerminate, offered only after normal terminate fails" — reads at
/// the call site instead of living implicitly in an `if succeeded {} else {}`.
enum QuitOutcome: Equatable {
    case quit
    case offerForceQuit
}

enum MemoryScreenLogic {

    /// `terminate()`'s return value, translated into the one decision this module ever makes
    /// about a quit attempt: offer `forceTerminate()` only once the polite path has failed.
    /// Never called for `forceTerminate()` itself — that one is fired directly from the
    /// confirmation the caller shows on `.offerForceQuit`.
    static func afterTerminateAttempt(succeeded: Bool) -> QuitOutcome {
        succeeded ? .quit : .offerForceQuit
    }

    /// Kernel pressure level → the tint every semantic-color affordance in this app already uses
    /// for the same three levels.
    static func pressureTint(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: SweepTokens.accent
        case .warning: SweepTokens.tierCaution
        case .critical: SweepTokens.tierExpert
        }
    }

    static func pressureLabel(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: "Normal"
        case .warning: "Warning"
        case .critical: "Critical"
        }
    }

    /// Fraction of `totalBytes` each breakdown bar fills. Each is clamped independently and the
    /// four are not required to sum to 1: `MemoryStats.appMemoryBytes` is itself documented as an
    /// approximation (see `MemoryStats`), so app/wired/compressed/free can overlap or leave a
    /// sliver uncounted at the edges.
    static func breakdown(_ stats: MemoryStats) -> (app: Double, wired: Double, compressed: Double, free: Double) {
        guard stats.totalBytes > 0 else { return (0, 0, 0, 0) }
        let total = Double(stats.totalBytes)
        func fraction(_ value: UInt64) -> Double { min(1, max(0, Double(value) / total)) }
        return (
            fraction(stats.appMemoryBytes),
            fraction(stats.wiredBytes),
            fraction(stats.compressedBytes),
            fraction(stats.freeBytes)
        )
    }

    /// Memory is the one place decimal units would be wrong: RAM is sold and reported in binary
    /// multiples (matches `MenuBarStats.memoryFormatted` in Shell — duplicated here rather than
    /// shared, since this file cannot import from that one; `SweepFormat.bytes` stays reserved
    /// for decimal/disk sizes per its own doc comment).
    static func formatMemory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// Pids eligible for a "Quit" button: present in both the footprint list and the set of pids
    /// this run resolved to a `.regular`-policy `NSRunningApplication`. Kept as a plain `Int32`
    /// intersection, decoupled from `NSRunningApplication` itself, so it is testable without a
    /// live process list — PLAN's "never touch processes without a corresponding running app"
    /// plus "only apps with activationPolicy == .regular get quit buttons" is exactly this one
    /// filter.
    static func quittablePIDs(processFootprints: [Int32], regularAppPIDs: Set<Int32>) -> [Int32] {
        processFootprints.filter { regularAppPIDs.contains($0) }
    }

    /// One app's aggregated memory: every process whose executable lives inside the app's
    /// outermost bundle, summed. This is what a person means by "how much memory is Notion
    /// using" — the Electron/browser helper split (user-reported: a page of anonymous
    /// "Helper (Renderer)" rows where only one row had a Quit button) is process bookkeeping
    /// they never chose and can't act on.
    struct AppMemoryAggregate: Identifiable, Equatable {
        let bundlePath: String
        let totalBytes: UInt64
        let processCount: Int
        var id: String { bundlePath }
    }

    /// Pure fold, injected resolver — unit-testable without Darwin. Processes that resolve to
    /// no app bundle (true daemons) fold into one "system & background" bucket.
    static func aggregateByApp(
        processes: [(pid: Int32, bytes: UInt64)],
        bundlePathForPID: (Int32) -> String?
    ) -> (apps: [AppMemoryAggregate], otherBytes: UInt64, otherCount: Int) {
        var byApp: [String: (bytes: UInt64, count: Int)] = [:]
        var otherBytes: UInt64 = 0
        var otherCount = 0
        for process in processes {
            if let bundle = bundlePathForPID(process.pid) {
                let prior = byApp[bundle] ?? (0, 0)
                byApp[bundle] = (prior.bytes + process.bytes, prior.count + 1)
            } else {
                otherBytes += process.bytes
                otherCount += 1
            }
        }
        let apps = byApp
            .map { AppMemoryAggregate(bundlePath: $0.key, totalBytes: $0.value.bytes, processCount: $0.value.count) }
            .sorted { $0.totalBytes > $1.totalBytes }
        return (apps, otherBytes, otherCount)
    }
}

/// One row of the top-processes table. `runningApp` is looked up once per snapshot tick and
/// dropped as soon as the pid stops being a `.regular`-policy running app — the moment that
/// happens, `canQuit` goes false and the row simply loses its button rather than holding a stale
/// handle.
private struct MemoryProcessRow: Identifiable {
    let pid: Int32
    var id: Int32 { pid }
    let name: String
    let footprintText: String
    let canQuit: Bool
}

// MARK: - Screen

/// Memory (module 3, PLAN §3): honest RAM. Live pressure, a real breakdown, real quit buttons —
/// no purge action, because there is no real "free memory" button on Apple Silicon to offer.
struct MemoryScreen: View {
    @State private var snapshot: SystemSnapshot?
    @State private var runningAppsByPID: [Int32: NSRunningApplication] = [:]
    /// App icon per process pid, so each row shows what launched it instead of leaving the user to
    /// decode a bare process name. Resolved from the process's own bundle; a bundleless system
    /// process resolves to `nil` and the row falls back to a tasteful Apple mark.
    @State private var iconsByPID: [Int32: NSImage] = [:]
    /// Outermost app bundle per pid (`.some(nil)` = resolved as a non-app daemon), cached across
    /// ticks the same way `iconsByPID` is — `proc_pidpath` per pid per tick would be waste.
    @State private var bundlePathByPID: [Int32: String?] = [:]
    @State private var appIconsByPath: [String: NSImage] = [:]
    @State private var appAggregates: [MemoryScreenLogic.AppMemoryAggregate] = []
    @State private var otherProcessesBytes: UInt64 = 0
    @State private var showAllProcesses = false
    @State private var pendingForceQuit: QuitTarget?

    /// One quit request, whichever row shape asked for it — an aggregated app row or a raw
    /// process row from the disclosure list.
    private struct QuitTarget: Identifiable {
        let name: String
        let app: NSRunningApplication
        var id: Int32 { app.processIdentifier }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: Destination.memory.title, subtitle: Destination.memory.subtitle)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        // Pin the whole screen to the detail column and top-align it (mirrors SystemJunkScreen).
        // Without this the VStack sizes to its full content height; under RootView's `.id()`
        // rebuild + layout spring on navigation, an unpinned oversized VStack shoves the header
        // off the top and content bleeds over the titlebar/sidebar (user-reported).
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .task {
            // Own sampler instance: this screen is not the menubar, and `StatsSampler` is cheap
            // and stateless between callers (see its own doc comment). Cancelled automatically
            // when the view goes away, same as `MenuBarStats`'s identical `.task`.
            // 200, not a screenful: the sampler reads every process each tick anyway (the limit
            // is a post-sort truncation), and the per-APP totals below are only honest if the
            // window catches an app's long tail of small helpers, not just its top few.
            let sampler = StatsSampler(configuration: .init(interval: .seconds(2), topProcessCount: 200))
            for await value in await sampler.snapshots() {
                snapshot = value
                runningAppsByPID = Self.regularRunningApps()
                let pids = value.topProcesses.map(\.pid)
                iconsByPID = Self.resolveIcons(for: Array(pids.prefix(Self.allProcessesRowCap)), cache: iconsByPID)
                var pathCache = bundlePathByPID
                for pid in pids where pathCache[pid] == nil {
                    pathCache[pid] = .some(Self.outermostAppBundlePath(forPID: pid))
                }
                bundlePathByPID = pathCache.filter { pids.contains($0.key) }
                let aggregated = MemoryScreenLogic.aggregateByApp(
                    processes: value.topProcesses.map { ($0.pid, $0.physicalFootprintBytes) },
                    bundlePathForPID: { pathCache[$0] ?? nil }
                )
                appAggregates = aggregated.apps
                otherProcessesBytes = aggregated.otherBytes
                var icons = appIconsByPath
                for app in aggregated.apps where icons[app.bundlePath] == nil {
                    icons[app.bundlePath] = NSWorkspace.shared.icon(forFile: app.bundlePath)
                }
                appIconsByPath = icons.filter { path, _ in aggregated.apps.contains { $0.bundlePath == path } }
            }
        }
        .confirmationDialog(
            forceQuitTitle,
            isPresented: Binding(
                get: { pendingForceQuit != nil },
                set: { if !$0 { pendingForceQuit = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Force Quit", role: .destructive) {
                if let row = pendingForceQuit { forceQuit(row) }
                pendingForceQuit = nil
            }
            Button("Cancel", role: .cancel) { pendingForceQuit = nil }
        } message: {
            Text("It did not quit when asked normally. Force quitting can lose unsaved work in it.")
        }
    }

    private var forceQuitTitle: String {
        "\u{201C}\(pendingForceQuit?.name ?? "This app")\u{201D} isn\u{2019}t responding."
    }

    @ViewBuilder
    private var content: some View {
        ZStack {
            if let snapshot {
                ScrollView {
                    VStack(alignment: .leading, spacing: SweepTokens.s5) {
                        pressureSection(snapshot)
                        breakdownSection(snapshot)
                        swapSection(snapshot)
                        processesSection(snapshot)
                    }
                    .padding(SweepTokens.s5)
                }
            } else {
                InventoryEmptyState(symbol: "memorychip", title: "Reading memory stats\u{2026}")
            }
        }
        // The first snapshot lands ~2s after this screen appears, swapping the empty state for a
        // much taller ScrollView. Without this, that swap inherits RootView's navigation layout
        // spring (`.animation(SweepMotion.layout, value: destination)`) and animates a large
        // height change, leaving the ScrollView scrolled off its top under NavigationSplitView on
        // macOS 26 (user-reported "clicking Memory screws up the UI"). A fixed ZStack container
        // plus a no-op transaction on the swap keeps the frame stable.
        .transaction { $0.animation = nil }
    }

    // MARK: - Sections

    private func pressureSection(_ snapshot: SystemSnapshot) -> some View {
        SectionCard {
            SweepStatRow(
                symbol: "gauge.with.dots.needle.67percent",
                title: "Memory Pressure",
                valueText: MemoryScreenLogic.pressureLabel(snapshot.memoryPressure),
                fraction: usedFraction(snapshot),
                tint: MemoryScreenLogic.pressureTint(snapshot.memoryPressure),
                isBreathing: snapshot.memoryPressure != .normal
            )
            .padding(SweepTokens.s4)
        }
    }

    private func breakdownSection(_ snapshot: SystemSnapshot) -> some View {
        let fractions = MemoryScreenLogic.breakdown(snapshot.memory)
        return SectionCard {
            VStack(alignment: .leading, spacing: SweepTokens.s3) {
                Text("Breakdown")
                    .font(SweepFont.sectionTitle)
                    .foregroundStyle(.secondary)
                SweepStatRow(
                    symbol: "app.badge",
                    title: "App Memory",
                    valueText: MemoryScreenLogic.formatMemory(snapshot.memory.appMemoryBytes),
                    fraction: fractions.app
                )
                SweepStatRow(
                    symbol: "lock.fill",
                    title: "Wired",
                    valueText: MemoryScreenLogic.formatMemory(snapshot.memory.wiredBytes),
                    fraction: fractions.wired
                )
                SweepStatRow(
                    symbol: "arrow.down.right.and.arrow.up.left",
                    title: "Compressed",
                    valueText: MemoryScreenLogic.formatMemory(snapshot.memory.compressedBytes),
                    fraction: fractions.compressed
                )
                SweepStatRow(
                    symbol: "circle.dashed",
                    title: "Free",
                    valueText: MemoryScreenLogic.formatMemory(snapshot.memory.freeBytes),
                    fraction: fractions.free
                )
            }
            .padding(SweepTokens.s4)
        }
    }

    private func swapSection(_ snapshot: SystemSnapshot) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: SweepTokens.s3) {
                Text("Swap (lifetime)")
                    .font(SweepFont.sectionTitle)
                    .foregroundStyle(.secondary)
                SweepStatRow(
                    symbol: "arrow.down.doc",
                    title: "Swapped In",
                    valueText: MemoryScreenLogic.formatMemory(snapshot.memory.swapInsBytes)
                )
                SweepStatRow(
                    symbol: "arrow.up.doc",
                    title: "Swapped Out",
                    valueText: MemoryScreenLogic.formatMemory(snapshot.memory.swapOutsBytes)
                )
            }
            .padding(SweepTokens.s4)
        }
    }

    /// How many raw process rows the "All processes" disclosure shows — the old Top Processes
    /// list, demoted to an advanced view (user-directed: apps with quit buttons are the point,
    /// per-process bookkeeping is not).
    private static let allProcessesRowCap = 12
    /// How many aggregated app rows show before the list stops earning its scroll.
    private static let appRowCap = 10

    private func processesSection(_ snapshot: SystemSnapshot) -> some View {
        SectionCard {
            VStack(spacing: 0) {
                HStack {
                    Text("Apps Using Memory")
                        .font(SweepFont.sectionTitle)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, SweepTokens.s4)
                .padding(.top, SweepTokens.s4)
                .padding(.bottom, SweepTokens.s2)

                if appAggregates.isEmpty {
                    Text("No process data yet.")
                        .font(SweepFont.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, SweepTokens.s4)
                        .padding(.bottom, SweepTokens.s4)
                } else {
                    ForEach(Array(appAggregates.prefix(Self.appRowCap).enumerated()), id: \.element.id) { index, app in
                        if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                        appMemoryRow(app)
                            .padding(.horizontal, SweepTokens.s3 - 2)
                    }
                    Divider().padding(.horizontal, SweepTokens.s3)
                    otherProcessesRow
                        .padding(.horizontal, SweepTokens.s3 - 2)
                    Divider().padding(.horizontal, SweepTokens.s3)
                    allProcessesDisclosure(snapshot)
                        .padding(.horizontal, SweepTokens.s4)
                        .padding(.vertical, SweepTokens.s2)
                }
            }
        }
    }

    /// One app, one number, one Quit — the row the user asked for. Quitting the app takes its
    /// whole helper tree with it, which is exactly why the aggregate is the actionable unit.
    private func appMemoryRow(_ app: MemoryScreenLogic.AppMemoryAggregate) -> some View {
        let running = runningRegularApp(forBundlePath: app.bundlePath)
        let name = Self.displayName(forBundlePath: app.bundlePath)
        return HStack(spacing: SweepTokens.s3 - 2) {
            Group {
                if let icon = appIconsByPath[app.bundlePath] {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").foregroundStyle(.secondary)
                }
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(SweepFont.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(app.processCount == 1 ? "1 process" : "\(app.processCount) processes")
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: SweepTokens.s3)
            Text(MemoryScreenLogic.formatMemory(app.totalBytes))
                .font(SweepFont.mono)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
            if let running {
                Button("Quit") { quit(QuitTarget(name: name, app: running)) }
                    .buttonStyle(.sweepQuiet)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(height: SweepTokens.inventoryRowHeight + 4)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(MemoryScreenLogic.formatMemory(app.totalBytes))\(running != nil ? ", can quit" : "")")
    }

    private var otherProcessesRow: some View {
        HStack(spacing: SweepTokens.s3 - 2) {
            Image(systemName: "apple.logo")
                .font(.system(size: 14.5, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 26)
            Text("macOS system & background processes")
                .font(SweepFont.rowTitle)
                .foregroundStyle(.secondary)
            Spacer(minLength: SweepTokens.s3)
            Text(MemoryScreenLogic.formatMemory(otherProcessesBytes))
                .font(SweepFont.mono)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
            Color.clear.frame(width: 1, height: 1)
        }
        .frame(height: SweepTokens.inventoryRowHeight)
    }

    /// The old per-process table, kept for the advanced look under a quiet disclosure.
    private func allProcessesDisclosure(_ snapshot: SystemSnapshot) -> some View {
        DisclosureGroup(isExpanded: $showAllProcesses) {
            let rows = Array(processRows(snapshot).prefix(Self.allProcessesRowCap))
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                    processRow(row)
                }
            }
            .padding(.top, SweepTokens.s1)
        } label: {
            Text("All processes")
                .font(SweepFont.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func quitTarget(for row: MemoryProcessRow) -> QuitTarget? {
        guard let app = runningAppsByPID[row.pid] else { return nil }
        return QuitTarget(name: row.name, app: app)
    }

    private func processRow(_ row: MemoryProcessRow) -> some View {
        HStack(spacing: SweepTokens.s3 - 2) {
            processIcon(for: row)
                .frame(width: 20, height: 20, alignment: .center)
            VStack(alignment: .leading, spacing: 0) {
                Text(row.name)
                    .font(SweepFont.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("PID \(row.pid)")
                    .font(SweepFont.monoSmall)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: SweepTokens.s3)
            Text(row.footprintText)
                .font(SweepFont.mono)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 104, alignment: .trailing)
            if row.canQuit {
                Button("Quit") { if let target = quitTarget(for: row) { quit(target) } }
                    .buttonStyle(.sweepQuiet)
            } else {
                Color.clear.frame(width: 1, height: 1)
            }
        }
        .frame(height: SweepTokens.inventoryRowHeight)
    }

    /// The launching app's real icon, or the Apple mark for a bundleless system process.
    @ViewBuilder
    private func processIcon(for row: MemoryProcessRow) -> some View {
        if let icon = iconsByPID[row.pid] {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: 18, height: 18)
        } else {
            Image(systemName: "apple.logo")
                .font(.system(size: 14.5, weight: .regular))
                .foregroundStyle(.secondary)
                .help("System process")
        }
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            Footnote(
                "Quitting apps is the only real memory relief. There is no purge on Apple Silicon "
                    + "— Sweep will not fake one.",
                symbol: "info.circle"
            )
            .padding(.horizontal, SweepTokens.s5)
            .padding(.vertical, SweepTokens.s3)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.bar)
    }

    // MARK: - Derived data

    private func usedFraction(_ snapshot: SystemSnapshot) -> Double {
        guard snapshot.memory.totalBytes > 0 else { return 0 }
        return 1 - Double(snapshot.memory.freeBytes) / Double(snapshot.memory.totalBytes)
    }

    private func processRows(_ snapshot: SystemSnapshot) -> [MemoryProcessRow] {
        let quittable = Set(MemoryScreenLogic.quittablePIDs(
            processFootprints: snapshot.topProcesses.map(\.pid),
            regularAppPIDs: Set(runningAppsByPID.keys)
        ))
        return snapshot.topProcesses.map { info in
            MemoryProcessRow(
                pid: info.pid,
                name: info.name,
                footprintText: MemoryScreenLogic.formatMemory(info.physicalFootprintBytes),
                canQuit: quittable.contains(info.pid)
            )
        }
    }

    /// Every currently running `.regular`-policy app, keyed by pid — the only processes this
    /// screen is ever allowed to touch (PLAN §3: "skip system processes: only apps with
    /// `NSRunningApplication.activationPolicy == .regular` get quit buttons").
    private static func regularRunningApps() -> [Int32: NSRunningApplication] {
        var map: [Int32: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            map[app.processIdentifier] = app
        }
        return map
    }

    /// App icon per pid for the current top processes. A `.regular` app resolves through
    /// `NSRunningApplication`; a helper process (`Notion Helper (Renderer)`, `Code Helper
    /// (Plugin)`, every Electron/browser child — user-reported showing the Apple mark) is NOT
    /// registered with LaunchServices, so it resolves through its executable path instead: the
    /// OUTERMOST `.app` bundle on that path is the app the user recognizes
    /// (`/Applications/Notion.app/Contents/Frameworks/Notion Helper (Renderer).app/...` →
    /// Notion's icon). Only a genuinely bundleless process (a pure system daemon) falls through
    /// to the Apple mark. Reuses `cache` so an unchanged pid isn't re-resolved, and prunes to
    /// the current pids so the map can't grow without bound as processes come and go.
    private static func resolveIcons(for pids: [Int32], cache: [Int32: NSImage]) -> [Int32: NSImage] {
        var result = cache
        for pid in pids where result[pid] == nil {
            if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil, let icon = app.icon {
                result[pid] = icon
            } else if let bundlePath = outermostAppBundlePath(forPID: pid) {
                result[pid] = NSWorkspace.shared.icon(forFile: bundlePath)
            }
        }
        return result.filter { pids.contains($0.key) }
    }

    /// `/Applications/Notion.app/Contents/Frameworks/Notion Helper (Renderer).app/Contents/MacOS/…`
    /// → `/Applications/Notion.app`. The LEFTMOST `.app` component wins on purpose: nested helper
    /// bundles carry no icon of their own, and the outermost bundle is the identity the user
    /// actually recognizes. Returns nil for any process not living inside an app bundle.
    private static func outermostAppBundlePath(forPID pid: Int32) -> String? {
        // `PROC_PIDPATHINFO_MAXSIZE` is a C macro (4 × MAXPATHLEN) the Swift importer can't see.
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        let path = String(cString: buffer)
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let appIndex = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[0...appIndex].joined(separator: "/")
    }

    // MARK: - Actions

    /// One quit path for both row shapes. `terminate()`'s return value reports whether the
    /// request was delivered, not whether the app actually exits — an unresponsive app can still
    /// return `true` here. This module treats a `false` return as the (conservative)
    /// non-responding signal PLAN asks for; a sturdier detector (e.g. a short timeout before
    /// offering force-quit) is future scope.
    private func quit(_ target: QuitTarget) {
        if MemoryScreenLogic.afterTerminateAttempt(succeeded: target.app.terminate()) == .offerForceQuit {
            pendingForceQuit = target
        }
    }

    private func forceQuit(_ target: QuitTarget) {
        target.app.forceTerminate()
    }

    /// The registered `.regular` running app whose bundle is exactly `bundlePath` — the handle
    /// an aggregated app row quits through. Helpers exit with their parent, which is the whole
    /// point of quitting at the app level.
    private func runningRegularApp(forBundlePath bundlePath: String) -> NSRunningApplication? {
        runningAppsByPID.values.first { $0.bundleURL?.standardizedFileURL.path == bundlePath }
    }

    private static func displayName(forBundlePath bundlePath: String) -> String {
        let name = FileManager.default.displayName(atPath: bundlePath)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }
}
