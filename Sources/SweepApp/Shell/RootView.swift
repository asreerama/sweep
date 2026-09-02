import SwiftUI
import SweepUI

struct RootView: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var visibility = WindowVisibility()
    /// Persisted so the chosen density survives relaunch. Collapsed is a 64 pt icon rail, never a
    /// hidden sidebar: navigation stays one click away in both states.
    @AppStorage("sweep.sidebar.collapsed") private var sidebarCollapsed = false

    private static let sidebarWidth: CGFloat = 216
    private static let railWidth: CGFloat = 64

    var body: some View {
        // A hand-rolled split, not `NavigationSplitView`: on macOS 26 the system sidebar renders
        // as a floating glass pane over the content (and its only collapse is full-hide), which
        // read as a detached overlay rather than part of the window. Here the sidebar is a plane
        // of the same window — solid `sidebarGround`, hairline edge — and collapsing animates it
        // down to an icon rail instead of removing it.
        HStack(spacing: 0) {
            SidebarView(
                selection: $state.destination,
                showsStressHarness: state.environment.showsStressHarness,
                isCollapsed: sidebarCollapsed
            )
            .frame(width: sidebarCollapsed ? Self.railWidth : Self.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            .background(SweepTokens.sidebarGround)

            Divider()

            // A GeometryReader pins the detail to the pane's size and hands each screen a
            // definite height. Without it, a screen whose content has a large ideal height
            // (Memory's stacked stat cards + process table, ~1175pt) leaks that ideal up through
            // the container — measured on macOS 26 as a 700pt window rendering a 1349pt layout
            // offset to y=-298, shoving the header off the top. Clamping to `proxy.size` forces
            // the screen's own ScrollView to scroll internally instead.
            GeometryReader { proxy in
                // Module navigation (PLAN §5, "Motion continuity"): a crossfade with a slight
                // vertical drift, never a hard swap. `.id` gives each destination's content its
                // own identity so the transition has an insert/remove to animate.
                detail
                    .id(state.destination)
                    .transition(
                        .opacity.combined(with: .offset(y: 6))
                    )
                    .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
                // Palette v2's tinted ground, set explicitly rather than left to the system
                // default: `Color(nsColor: .windowBackgroundColor)` (what an unset background
                // otherwise resolves to) is an `NSColor` bridge, and — like every other `NSColor`
                // bridge tried here — does not reliably re-resolve for a forced dark appearance
                // inside this app's offscreen screenshot harness, even though it works correctly
                // in a normally-composited window. `SweepTokens` colors sidestep that whole
                // class of bridge (see `adaptive`'s doc comment) and are correct in both places.
                    .background(SweepTokens.groundGradient)
            }
        }
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: state.destination)
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: sidebarCollapsed)
        .navigationTitle(state.destination.title)
        .toolbar(removing: .title)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    sidebarCollapsed.toggle()
                } label: {
                    Image(systemName: "sidebar.left")
                }
                .help(sidebarCollapsed ? "Expand the sidebar" : "Collapse the sidebar to icons")
                .keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
        .environment(state.scan)
        .environment(state.homebrew)
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
