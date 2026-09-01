import AppKit
import SwiftUI
import SweepSystem
import SweepUI

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
