import SwiftUI
import SweepUI
import SweepSystem

@main
struct SweepApp: App {
    var body: some Scene {
        Window("Sweep", id: "main") {
            MainWindowPlaceholder()
        }
        .defaultSize(width: 980, height: 640)

        MenuBarExtra("Sweep", systemImage: "wind") {
            MenuBarStats()
        }
        .menuBarExtraStyle(.window)
    }
}

struct MainWindowPlaceholder: View {
    var body: some View {
        NavigationSplitView {
            List {
                Label("Smart Scan", systemImage: "sparkles")
                Section("Clean") {
                    Label("System Junk", systemImage: "trash")
                    Label("Large & Old Files", systemImage: "doc.zipper")
                }
                Section("Speed") {
                    Label("Memory", systemImage: "memorychip")
                    Label("Maintenance", systemImage: "wrench.and.screwdriver")
                    Label("Startup Items", systemImage: "power")
                }
                Section("Apps") {
                    Label("Uninstaller", systemImage: "xmark.bin")
                }
                Section("Toolbox") {
                    Label("Developer", systemImage: "hammer")
                    Label("Homebrew", systemImage: "mug")
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
        } detail: {
            VStack(spacing: 12) {
                Image(systemName: "wind")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(SweepTokens.accent)
                Text("Sweep")
                    .font(.system(size: 28, weight: .bold, design: .default))
                Text("Scaffold build. Modules land in P2/P3.")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

struct MenuBarStats: View {
    @State private var snapshot: SystemSnapshot?

    var body: some View {
        VStack(alignment: .leading, spacing: SweepTokens.s2) {
            Text("Sweep").font(.headline)
            if let s = snapshot {
                statRow("memorychip", "Memory",
                        used: s.memory.totalBytes - s.memory.freeBytes,
                        total: s.memory.totalBytes,
                        tint: pressureTint(s.memoryPressure))
                statRow("cpu", "CPU", percent: 100 - s.cpu.aggregateIdlePercent)
                if let disk = s.disks.first(where: { $0.isInternal }) ?? s.disks.first {
                    statRow("internaldrive", disk.volumeName,
                            used: disk.totalBytes - disk.availableBytes,
                            total: disk.totalBytes,
                            tint: SweepTokens.accent)
                }
            } else {
                ProgressView().controlSize(.small)
            }
            Divider()
            Button("Quit Sweep") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(SweepTokens.s3)
        .frame(width: 260)
        .task {
            let sampler = StatsSampler()
            for await snap in await sampler.snapshots() {
                snapshot = snap
            }
        }
    }

    private func pressureTint(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: SweepTokens.accent
        case .warning: SweepTokens.tierCaution
        case .critical: SweepTokens.tierExpert
        }
    }

    @ViewBuilder
    private func statRow(_ symbol: String, _ title: String, used: UInt64, total: UInt64, tint: Color) -> some View {
        let fraction = total > 0 ? Double(used) / Double(total) : 0
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(title, systemImage: symbol).font(.caption)
                Spacer()
                Text("\(format(used)) / \(format(total))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: fraction).tint(tint).controlSize(.small)
        }
    }

    @ViewBuilder
    private func statRow(_ symbol: String, _ title: String, percent: Double) -> some View {
        HStack {
            Label(title, systemImage: symbol).font(.caption)
            Spacer()
            Text(String(format: "%.0f%%", percent))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }
}
