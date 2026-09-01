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
            MenuBarPlaceholder()
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

struct MenuBarPlaceholder: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sweep").font(.headline)
            Text("Live stats land at M1 (SweepSystem).")
                .font(.caption)
                .foregroundStyle(.secondary)
            Divider()
            Button("Quit Sweep") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(12)
        .frame(width: 260)
    }
}
