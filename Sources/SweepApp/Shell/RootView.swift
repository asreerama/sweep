import SwiftUI
import SweepUI

struct RootView: View {
    @Bindable var state: AppState

    @State private var visibility = WindowVisibility()

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $state.destination,
                showsStressHarness: state.environment.showsStressHarness
            )
            .navigationSplitViewColumnWidth(min: 196, ideal: 216, max: 260)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(state.destination.title)
        .environment(state.scan)
        .environment(\.sweepAnimationsEnabled, visibility.isVisible)
    }

    @ViewBuilder
    private var detail: some View {
        switch state.destination {
        case .smartScan:
            SmartScanScreen { state.destination = .systemJunk }
        case .systemJunk:
            SystemJunkScreen()
        case .listStress:
            ListStressScreen(rowCount: state.environment.stressRowCount)
        case .largeFiles:
            ModulePlaceholderScreen(destination: .largeFiles, arrival: "Arrives with the P3 module wave.")
        case .memory:
            ModulePlaceholderScreen(destination: .memory, arrival: "Arrives at M4, on the honest-metrics design in PLAN §3.")
        case .maintenance:
            ModulePlaceholderScreen(destination: .maintenance, arrival: "Arrives at M4, behind typed command adapters.")
        case .startupItems:
            ModulePlaceholderScreen(destination: .startupItems, arrival: "Arrives once the public-API boundary is prototyped.")
        case .uninstaller:
            ModulePlaceholderScreen(destination: .uninstaller, arrival: "Matching engine is built; the preview screen arrives with the P3 module wave.")
        case .developer:
            ModulePlaceholderScreen(destination: .developer, arrival: "Arrives with the P3 module wave, over the same rules engine as System Junk.")
        case .homebrew:
            ModulePlaceholderScreen(destination: .homebrew, arrival: "Arrives at M4, preview-first over typed brew adapters.")
        }
    }
}
