import SwiftUI
import SweepUI

struct RootView: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var visibility = WindowVisibility()

    var body: some View {
        NavigationSplitView {
            SidebarView(
                selection: $state.destination,
                showsStressHarness: state.environment.showsStressHarness
            )
            .navigationSplitViewColumnWidth(min: 196, ideal: 216, max: 260)
        } detail: {
            // Module navigation (PLAN §5, "Motion continuity"): a crossfade with a slight
            // vertical drift, never a hard swap. `.id` gives each destination's content its own
            // identity so the transition actually has an insert/remove to animate, rather than
            // SwiftUI diffing two same-shaped views in place.
            detail
                .id(state.destination)
                .transition(
                    .opacity.combined(with: .offset(y: 6))
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // Palette v2's tinted ground, set explicitly rather than left to the system
                // default: `Color(nsColor: .windowBackgroundColor)` (what an unset background
                // otherwise resolves to) is an `NSColor` bridge, and — like every other `NSColor`
                // bridge tried here — does not reliably re-resolve for a forced dark appearance
                // inside this app's offscreen screenshot harness, even though it works correctly
                // in a normally-composited window. `SweepTokens.ground` sidesteps that whole
                // class of bridge (see its doc comment) and is correct in both places.
                .background(SweepTokens.ground)
        }
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: state.destination)
        .navigationTitle(state.destination.title)
        .toolbar(removing: .title)
        .environment(state.scan)
        .environment(\.sweepAnimationsEnabled, visibility.isVisible)
        // Drop target 1 of 2 (PLAN §3 module 5, AppCleaner parity): drag a `.app` anywhere onto
        // the window. Drop target 2 (the Dock icon with Sweep closed) is
        // `SweepAppDelegate.application(_:open:)` in `SweepApp.swift` — both land on
        // `AppState.openUninstaller(forDroppedAppAt:)`.
        .dropDestination(for: URL.self) { urls, _ in
            guard let appURL = urls.first(where: { $0.pathExtension == "app" }) else { return false }
            state.openUninstaller(forDroppedAppAt: appURL)
            return true
        }
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
        case .cleanFlowPreview:
            CleanFlowPreviewScreen(phase: $state.cleanFlowPreviewPhase)
        case .largeFiles:
            LargeOldFilesScreen()
        case .memory:
            MemoryScreen()
        case .maintenance:
            MaintenanceScreen()
        case .startupItems:
            StartupItemsScreen()
        case .uninstaller:
            UninstallerScreen(model: state.uninstall)
        case .developer:
            DeveloperScreen()
        case .homebrew:
            HomebrewScreen()
        }
    }
}
