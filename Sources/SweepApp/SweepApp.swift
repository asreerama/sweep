import SwiftUI
import SweepUI

@main
struct SweepApp: App {
    /// Catalog location and scan home are resolved once, here, and injected. Nothing below
    /// this line knows a filesystem path.
    @State private var state = AppState(environment: .resolve())

    var body: some Scene {
        Window("Sweep", id: "main") {
            RootView(state: state)
                .frame(minWidth: 900, minHeight: 600)
                .task { await SnapshotHarness.runIfRequested(state: state) }
                .task { _ = QuarantineWatch.checkAtStartup() }
        }
        .defaultSize(width: 1060, height: 700)

        MenuBarExtra("Sweep", systemImage: "wind") {
            MenuBarStats()
        }
        .menuBarExtraStyle(.window)
    }
}
