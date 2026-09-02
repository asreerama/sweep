import SwiftUI
import SweepUI

struct RootView: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var visibility = WindowVisibility()
    /// Persisted so the chosen density survives relaunch. Collapsed is a 64 pt icon rail, never a
    /// hidden sidebar: navigation stays one click away in both states.
    @AppStorage("sweep.sidebar.collapsed") private var sidebarCollapsed = false

    private static let sidebarWidth: CGFloat = 248
    // 80 pt clears the rail's 56 pt slots with real margin either side (scale v4: the rail is
    // an app launcher, not a cramped icon strip).
    private static let railWidth: CGFloat = 80

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
                isCollapsed: $sidebarCollapsed
            )
            .frame(width: sidebarCollapsed ? Self.railWidth : Self.sidebarWidth)
            .frame(maxHeight: .infinity, alignment: .top)
            // Behind-window sidebar material (user-directed: the solid `sidebarGround` read as
            // flat grey). The material IS the ground — no opaque token color in the stack, or
            // the translucency reads as barely different from the old flat fill; the material
            // supplies its own opaque backing automatically when Reduce Transparency is on.
            // The faint accent wash keeps the pane in the app's indigo family rather than
            // neutral vibrancy grey — and the whole stack stays a plane of the window, not
            // macOS 26's floating glass overlay. The offscreen snapshot harness has no window
            // server behind it, so THERE the material renders flat: judge this surface on a
            // real desktop, not in a capture.
            .background {
                ZStack {
                    SidebarMaterial()
                    SweepTokens.accent.opacity(0.05)
                }
                .ignoresSafeArea()
            }

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
        // Full-bleed under the hidden titlebar: without this, the invisible titlebar's safe-area
        // inset leaves a transparent strip above both panes (the traffic lights would float over
        // bare window background instead of `sidebarGround`). The sidebar's own `topStrip`
        // provides the clearance the safe area used to.
        .ignoresSafeArea(.container, edges: .top)
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: state.destination)
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: sidebarCollapsed)
        // Window title kept for Mission Control / the app switcher; nothing draws it on screen —
        // the window itself is `.hiddenTitleBar` (SweepApp.swift) and the sidebar toggle lives in
        // `SidebarView`'s top strip beside the traffic lights.
        .navigationTitle(state.destination.title)
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

/// The sidebar's behind-window blur. `.sidebar` material, active state following the window —
/// the standard Mac translucency, hosted here because SwiftUI exposes no material that blends
/// behind the window rather than within it. Renders as a flat approximation in the offscreen
/// snapshot harness (no window server behind it there), which is fine: the harness verifies
/// layout, not desktop bleed-through.
private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
