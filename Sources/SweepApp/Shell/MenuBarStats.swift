import AppKit
import SwiftUI
import SweepSystem
import SweepUI

/// Menubar accessory-mode switch (PLAN §2: "One app process switching activation policy, regular
/// when main window open, accessory otherwise").
///
/// Watches window visibility via `NSApplication`-level notifications rather than a per-window
/// `NSWindowDelegate` — cheaper to install from a SwiftUI view's lifecycle (no window reference to
/// hand a delegate to before the window exists) and it already answers the same question
/// `WindowVisibility` (Shell/WindowVisibility.swift) asks for the pause-when-occluded contract:
/// is any Sweep window actually on screen. A second, independent listener here rather than
/// threading that one through is deliberate — this file owns exactly the accessory-mode switch,
/// nothing about `WindowVisibility`'s animation-pausing contract.
///
/// Also installs itself as `NSApp`'s delegate to answer `applicationShouldTerminateAfterLastWindow
/// Closed` with `false`: without that, AppKit's default is to quit the process once its last
/// window closes, which would make an "accessory mode" for the menubar-only state meaningless —
/// there would be no process left to be an accessory. `SweepApp.swift` installs no delegate of its
/// own (a plain SwiftUI-lifecycle `App`), so it is safe for this to claim the role; if that ever
/// changes, `NSApp.delegate` assignment here would simply be overwritten by whichever runs later
/// and this comment is the flag for whoever notices activation-policy switching silently stopped.
@MainActor
final class MenuBarActivationPolicy: NSObject, NSApplicationDelegate {
    static let shared = MenuBarActivationPolicy()

    private var didStart = false

    private override init() { super.init() }

    /// Idempotent: every call site that might run first (`MenuBarStats.onAppear`, the budget
    /// harness below) calls this unconditionally rather than coordinating who goes first.
    func start() {
        guard !didStart else { return }
        didStart = true

        if NSApp.delegate == nil {
            NSApp.delegate = self
        }

        sync()
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.sync() }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: nil, queue: .main
        ) { [weak self] _ in
            // The closing window is still in `NSApp.windows` at the moment this notification
            // fires; hop one runloop turn so `sync()` sees the post-close window list.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.sync() } }
        }
    }

    nonisolated func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// `.regular` (Dock icon, full app switching) while any titled window is visible; `.accessory`
    /// (menubar-only) the instant none are. Filters to `.titled` windows the same way
    /// `SnapshotHarness.mainWindow()` does: the menu bar extra's own `.window`-style popover is a
    /// borderless panel and must never itself count as "the main window is open."
    private func sync() {
        let anyMainWindowVisible = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) }
        let target: NSApplication.ActivationPolicy = anyMainWindowVisible ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
    }
}

/// Menubar popover: a compact stat stack and one action row (PLAN §5).
///
/// Same rows as before, restyled onto `SweepStatRow`. Motion moment three lives here: the
/// pressure gauge breathes only while pressure is off normal, so a still gauge is itself the
/// signal that nothing is wrong.
struct MenuBarStats: View {
    @State private var snapshot: SystemSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s3) {
            header

            if let snapshot {
                VStack(alignment: .leading, spacing: SweepTokens.s3) {
                    SweepStatRow(
                        symbol: "memorychip",
                        title: "Memory",
                        valueText: memoryText(snapshot),
                        fraction: memoryFraction(snapshot),
                        tint: pressureTint(snapshot.memoryPressure),
                        isBreathing: snapshot.memoryPressure != .normal
                    )
                    SweepStatRow(
                        symbol: "cpu",
                        title: "CPU",
                        valueText: String(format: "%.0f%%", 100 - snapshot.cpu.aggregateIdlePercent),
                        fraction: max(0, min(1, (100 - snapshot.cpu.aggregateIdlePercent) / 100))
                    )
                    if let disk = snapshot.disks.first(where: { $0.isInternal }) ?? snapshot.disks.first {
                        SweepStatRow(
                            symbol: "internaldrive",
                            title: disk.volumeName,
                            valueText: diskText(disk),
                            fraction: diskFraction(disk)
                        )
                    }
                }
            } else {
                HStack(spacing: SweepTokens.s2) {
                    ProgressView().controlSize(.small)
                    Text("Sampling\u{2026}")
                        .font(SweepFont.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(height: 46)
            }

            Divider()

            HStack(spacing: SweepTokens.s2) {
                Button("Open Sweep") {
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: { $0.isVisible })?.makeKeyAndOrderFront(nil)
                }
                .buttonStyle(.sweepQuiet)
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(.sweepQuiet)
                    .keyboardShortcut("q")
            }
        }
        .padding(SweepTokens.s3)
        .frame(width: 268)
        .onAppear { MenuBarActivationPolicy.shared.start() }
        .task {
            let sampler = StatsSampler()
            for await value in await sampler.snapshots() {
                snapshot = value
            }
        }
        .task { await MenuBarBudgetHarness.runIfRequested() }
    }

    private var header: some View {
        HStack(spacing: SweepTokens.s2 - 2) {
            Image(systemName: "wind")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(SweepTokens.accent)
            Text("Sweep")
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            if let snapshot {
                Text(pressureLabel(snapshot.memoryPressure))
                    .font(SweepFont.badge)
                    .tracking(0.5)
                    .foregroundStyle(pressureTint(snapshot.memoryPressure))
            }
        }
    }

    // MARK: - Readouts

    private func memoryText(_ snapshot: SystemSnapshot) -> String {
        let used = snapshot.memory.totalBytes - snapshot.memory.freeBytes
        return "\(memoryFormatted(used)) / \(memoryFormatted(snapshot.memory.totalBytes))"
    }

    private func memoryFraction(_ snapshot: SystemSnapshot) -> Double {
        let total = Double(snapshot.memory.totalBytes)
        guard total > 0 else { return 0 }
        return Double(snapshot.memory.totalBytes - snapshot.memory.freeBytes) / total
    }

    private func diskText(_ disk: DiskStats) -> String {
        let used = disk.totalBytes - disk.availableBytes
        return "\(SweepFormat.bytes(Int64(used))) / \(SweepFormat.bytes(Int64(disk.totalBytes)))"
    }

    private func diskFraction(_ disk: DiskStats) -> Double {
        guard disk.totalBytes > 0 else { return 0 }
        return Double(disk.totalBytes - disk.availableBytes) / Double(disk.totalBytes)
    }

    /// Memory is the one place decimal units would be wrong: RAM is sold and reported in
    /// binary multiples, so this readout keeps `ByteCountFormatter(.memory)`.
    private func memoryFormatted(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private func pressureTint(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: SweepTokens.accent
        case .warning: SweepTokens.tierCaution
        case .critical: SweepTokens.tierExpert
        }
    }

    private func pressureLabel(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: "NORMAL"
        case .warning: "WARNING"
        case .critical: "CRITICAL"
        }
    }
}

/// Menubar idle-memory budget harness (PLAN §5 budget: "menubar idle < 50 MB RSS"; task item 3:
/// "measure: with main window closed + menubar only, RSS after 60 s idle").
///
/// Inert unless `SWEEP_MENUBAR_BUDGET` is set — never engaged by a normal launch. Closes every
/// titled window itself rather than relying on external UI automation: driving a real window
/// close from outside the process (AppleScript/System Events, a synthetic Cmd-W) needs
/// Accessibility permission granted through a TCC prompt this harness has no way to click through
/// non-interactively, the same class of problem `SnapshotHarness`'s offscreen-rendering approach
/// exists to sidestep for screenshots. Prints one greppable line and, optionally, exits — the
/// same shape as `SnapshotHarness`'s `SWEEP_SNAPSHOT_EXIT`.
///
///   SWEEP_MENUBAR_BUDGET=1        close all windows, wait 60 s, print one RSS measurement
///   SWEEP_MENUBAR_BUDGET_EXIT=1   quit once that line has printed
@MainActor
enum MenuBarBudgetHarness {
    /// Reachable from two call sites (`SweepApp.swift`'s `Window` content, and `MenuBarStats`'s
    /// own `.task` below — see the comment on the former for why both exist) — guarded so
    /// whichever gets there first is the one and only run, the same idempotency shape
    /// `MenuBarActivationPolicy.start()` uses for its own dual call sites.
    private static var hasRun = false

    static func runIfRequested() async {
        guard ProcessInfo.processInfo.environment["SWEEP_MENUBAR_BUDGET"] != nil else { return }
        guard !hasRun else { return }
        hasRun = true

        // Make sure the accessory-mode switch is actually wired before measuring it.
        MenuBarActivationPolicy.shared.start()

        for window in NSApp.windows where window.styleMask.contains(.titled) {
            window.close()
        }
        // `willCloseNotification`'s own handler hops one runloop turn before re-syncing the
        // activation policy; give it a moment to land before the 60 s idle window starts.
        try? await Task.sleep(for: .milliseconds(300))

        try? await Task.sleep(for: .seconds(60))

        // One pass at manual memory pressure relief (PLAN §5 teardown lever, applied from within
        // this file's own ownership): asks the allocator to return free pages to the OS before
        // the measurement below, in case 60 s of idle heap fragmentation is inflating RSS beyond
        // what is actually live. Harmless to call whether or not it moves the number.
        malloc_zone_pressure_relief(nil, 0)

        let rssBytes = residentBytes()
        let policyIsAccessory = NSApp.activationPolicy() == .accessory
        let openWindows = NSApp.windows.filter { $0.isVisible && $0.styleMask.contains(.titled) }.count
        print(String(
            format: "SWEEP_MENUBAR_BUDGET rss_mb=%.1f activation_policy=%@ titled_windows_open=%d",
            Double(rssBytes) / 1_048_576,
            policyIsAccessory ? "accessory" : "regular",
            openWindows
        ))

        if ProcessInfo.processInfo.environment["SWEEP_MENUBAR_BUDGET_EXIT"] == "1" {
            NSApp.terminate(nil)
        }
    }

    /// Same `mach_task_basic_info` read `SnapshotHarness.residentBytes()` uses — duplicated
    /// rather than shared, since that one is `private` to a different file's `enum`.
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
