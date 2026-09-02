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
    @State private var pendingForceQuit: MemoryProcessRow?

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
            let sampler = StatsSampler(configuration: .init(interval: .seconds(2), topProcessCount: 12))
            for await value in await sampler.snapshots() {
                snapshot = value
                runningAppsByPID = Self.regularRunningApps()
                iconsByPID = Self.resolveIcons(for: value.topProcesses.map(\.pid), cache: iconsByPID)
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

    private func processesSection(_ snapshot: SystemSnapshot) -> some View {
        let rows = processRows(snapshot)
        return SectionCard {
            VStack(spacing: 0) {
                HStack {
                    Text("Top Processes")
                        .font(SweepFont.sectionTitle)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, SweepTokens.s4)
                .padding(.top, SweepTokens.s4)
                .padding(.bottom, SweepTokens.s2)

                if rows.isEmpty {
                    Text("No process data yet.")
                        .font(SweepFont.caption)
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, SweepTokens.s4)
                        .padding(.bottom, SweepTokens.s4)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                        processRow(row)
                            .padding(.horizontal, SweepTokens.s3 - 2)
                    }
                    .padding(.bottom, SweepTokens.s2)
                }
            }
        }
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
                Button("Quit") { quit(row) }
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

    /// Never called for a pid with no resolved running app: `runningAppsByPID` only ever holds
    /// `.regular`-policy apps, and `row.canQuit` (hence this button's visibility) is derived from
    /// membership in exactly that map.
    private func quit(_ row: MemoryProcessRow) {
        guard let app = runningAppsByPID[row.pid] else { return }
        // `terminate()`'s return value reports whether the request was delivered, not whether
        // the app actually exits — an unresponsive app can still return `true` here. This module
        // treats a `false` return as the (conservative) non-responding signal PLAN asks for; a
        // sturdier detector (e.g. a short timeout before offering force-quit) is future scope.
        if MemoryScreenLogic.afterTerminateAttempt(succeeded: app.terminate()) == .offerForceQuit {
            pendingForceQuit = row
        }
    }

    private func forceQuit(_ row: MemoryProcessRow) {
        runningAppsByPID[row.pid]?.forceTerminate()
    }
}
