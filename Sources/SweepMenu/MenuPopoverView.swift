import AppKit
import SweepSystem
import SweepUI
import SwiftUI

/// The popover's content: a compact stat stack and one action row (PLAN §5, §3 module 7) — the
/// same shape as the in-app `MenuBarExtra`'s `MenuBarStats` (`Sources/SweepApp/Shell/
/// MenuBarStats.swift`), rebuilt here from the same two packages (`SweepSystem.StatsSampler`,
/// `SweepUI`'s tokens and `SweepStatRow`) rather than shared, since this executable target must
/// not depend on `SweepApp`. Motion moment three lives here exactly as it does there: the memory
/// row's bar breathes only while pressure is off normal (`SweepStatRow`'s own `isBreathing`,
/// `SweepMotion.breathe`, reduce-motion-respecting) — a still gauge means nothing is wrong.
struct MenuPopoverView: View {
    @State private var snapshot: SystemSnapshot?

    /// `previewSnapshot` lets `MenuScreenshotHarness` seed a real, already-sampled reading before
    /// an offscreen `ImageRenderer` pass: `ImageRenderer` renders synchronously against whatever
    /// state the view already holds, so this view's own `.task` below (which starts a fresh async
    /// `StatsSampler` loop) would not have produced a result yet at render time. The live popover
    /// never passes this — `MenuBarController` always constructs a plain `MenuPopoverView()`.
    init(previewSnapshot: SystemSnapshot? = nil) {
        _snapshot = State(initialValue: previewSnapshot)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s3) {
            header

            if let snapshot {
                VStack(alignment: .leading, spacing: SweepTokens.s3) {
                    SweepStatRow(
                        symbol: "memorychip",
                        title: "Memory",
                        valueText: MenuDisplayLogic.memoryText(memory: snapshot.memory),
                        fraction: MenuDisplayLogic.memoryFraction(memory: snapshot.memory),
                        tint: MenuDisplayLogic.pressureTint(snapshot.memoryPressure),
                        isBreathing: snapshot.memoryPressure != .normal
                    )
                    SweepStatRow(
                        symbol: "cpu",
                        title: "CPU",
                        valueText: String(format: "%.0f%%", 100 - snapshot.cpu.aggregateIdlePercent),
                        fraction: max(0, min(1, (100 - snapshot.cpu.aggregateIdlePercent) / 100))
                    )
                    if let disk = snapshot.disks.first(where: \.isInternal) ?? snapshot.disks.first {
                        SweepStatRow(
                            symbol: "internaldrive",
                            title: disk.volumeName,
                            valueText: MenuDisplayLogic.diskText(disk: disk),
                            fraction: MenuDisplayLogic.diskFraction(disk: disk)
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
                Button("Open Sweep") { MenuQuickActions.openSweep() }
                    .buttonStyle(.sweepQuiet)
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.sweepQuiet)
                    .keyboardShortcut("q")
            }
        }
        .padding(SweepTokens.s3)
        .frame(width: 268)
        .task {
            let sampler = StatsSampler()
            for await value in await sampler.snapshots() {
                snapshot = value
            }
        }
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
                Text(MenuDisplayLogic.pressureLabel(snapshot.memoryPressure))
                    .font(SweepFont.badge)
                    .tracking(0.5)
                    .foregroundStyle(MenuDisplayLogic.pressureTint(snapshot.memoryPressure))
            }
        }
    }
}
