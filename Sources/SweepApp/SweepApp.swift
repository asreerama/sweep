import AppKit
import OSLog
import SwiftUI
import SweepUI

private let dockDropLog = Logger(subsystem: "com.aditya.sweep", category: "uninstall")

@main
struct SweepApp: App {
    /// Catalog location and scan home are resolved once, here, and injected. Nothing below
    /// this line knows a filesystem path.
    @State private var state = AppState(environment: .resolve())
    /// Dock-drop plumbing, route 2 of 2 (PLAN §3 module 5, AppCleaner parity): a `.app` dropped
    /// on the Dock icon while Sweep is closed launches the process and macOS calls
    /// `application(_:open:)` once the delegate exists — see `SweepAppDelegate` below. Route 1 is
    /// `RootView`'s `.dropDestination(for: URL.self)`, for a `.app` dropped on the window itself.
    @NSApplicationDelegateAdaptor(SweepAppDelegate.self) private var appDelegate

    /// First-run onboarding (PLAN §4/§5): one `UserDefaults`-backed flag, presented as a sheet
    /// over the main window rather than a window of its own — "never blocks the main window." A
    /// plain `@State` (not `@Bindable`) is enough here: nothing below reads `$onboarding` itself,
    /// only `onboarding.isPresented` through the hand-built `Binding` at the `.sheet` call site,
    /// the same shape `SmartScanScreen` already uses for its own sheet (`cleanFlow`).
    @State private var onboarding = OnboardingLaunchState.shared

    /// In-app-menubar hand-off (PLAN §3 module 7, the P4-B split): `MenuBarHandoff` (Shell/
    /// MenuBarStats.swift) tracks whether the standalone `SweepMenu` process is running, and this
    /// scene's own `MenuBarExtra` below binds its `isInserted` to it — exactly one of the two ever
    /// draws a Sweep status item.
    @State private var menuBarHandoff = MenuBarHandoff.shared

    var body: some Scene {
        Window("Sweep", id: "main") {
            RootView(state: state)
                .frame(minWidth: 900, minHeight: 600)
                .task { await SnapshotHarness.runIfRequested(state: state) }
                .task { await UninstallerSnapshotHarness.runIfRequested(state: state) }
                .task { await OnboardingSnapshotHarness.runIfRequested() }
                .task { _ = QuarantineWatch.checkAtStartup() }
                .task { SentinelSettings.shared.apply() }
                // FDA capability model (PLAN §4): starts the probe-and-recheck lifecycle once,
                // at launch, independent of whether onboarding ever gets a chance to read it —
                // a later Settings-triggered re-run should never show a stale first reading.
                .task { CapabilityStore.shared.start() }
                .sheet(isPresented: Binding(
                    get: { onboarding.isPresented }, set: { onboarding.setPresented($0) }
                )) {
                    OnboardingFlow { _ in onboarding.markSeen() }
                }
                // Menubar accessory-mode switch (PLAN §2), started here rather than only from
                // `MenuBarStats`'s own `.onAppear`: `MenuBarExtra`'s `.window`-style content
                // closure is evaluated lazily — confirmed empirically, not just by inspection —
                // the popover body never runs until the user opens it at least once, so a launch
                // that closes the main window without ever clicking the status item would
                // otherwise never engage `MenuBarActivationPolicy` at all. `start()` is idempotent
                // (Shell/MenuBarStats.swift), so this and `MenuBarStats.onAppear` racing to be
                // first is harmless either way.
                .task { MenuBarActivationPolicy.shared.start() }
                // Same reachability reason as immediately above: this is a no-op unless
                // `SWEEP_MENUBAR_BUDGET` is set, but it has to be reachable without a popover
                // open to measure the exact "main window closed, menubar only" state at all.
                .task { await MenuBarBudgetHarness.runIfRequested() }
                // Same reachability reason again, and load-bearing this time rather than just a
                // measurement hook: `MenuBarExtra`'s content closure (and so `MenuBarStats.onAppear`)
                // never runs while `isInserted` is false, which is exactly the state that must
                // still watch for `SweepMenu` quitting so the in-app item can hand back.
                .task { MenuBarHandoff.shared.start() }
                .onAppear { appDelegate.attach(state) }
                // `sweep://open-uninstall-orphan?bundleID=...` — the SmartDelete watcher's own
                // offer accept action (`TrashOfferPanel`), and the one other place a `sweep://`
                // deep link could arrive from. File-based document opens (the Dock-drop route)
                // go through `SweepAppDelegate.application(_:open:)` instead, never this.
                .onOpenURL { url in state.handleOpenURL(url) }
        }
        .defaultSize(width: 1060, height: 700)

        // `isInserted` is the hand-off switch (PLAN §3 module 7): unchecked the instant `SweepMenu`
        // is detected running, so there is never more than one Sweep status item on screen.
        MenuBarExtra("Sweep", systemImage: "wind", isInserted: $menuBarHandoff.showsInAppMenuBar) {
            MenuBarStats()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
        }
    }
}

/// Fallback for the Dock-drop route: `CFBundleDocumentTypes` (added to the Info.plist template in
/// `scripts/build-app.sh`) registers Sweep with Launch Services as able to open
/// `com.apple.application-bundle` documents, which is what makes a `.app` dropped on Sweep's
/// closed Dock icon launch the process at all. Once launched, AppKit hands the dropped URLs to
/// this delegate method — never `.onOpenURL`, which is SwiftUI's route for custom URL schemes
/// (`sweep://...`), not Finder/Dock document-open events.
///
/// `AppState` is created by the `App` struct's own `@State`, which is not guaranteed to exist
/// yet the instant AppKit finishes launching and could deliver an open-file event; URLs that
/// arrive before `attach(_:)` runs are queued and flushed the moment it does.
@MainActor
final class SweepAppDelegate: NSObject, NSApplicationDelegate {
    private weak var appState: AppState?
    private var pendingURLs: [URL] = []

    func attach(_ state: AppState) {
        appState = state
        let queued = pendingURLs
        pendingURLs = []
        for url in queued { route(url) }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        dockDropLog.notice("application(_:open:) received \(urls.count) URL(s): \(urls.map(\.path).joined(separator: ", "), privacy: .public)")
        for url in urls { route(url) }
    }

    /// Legacy fallback. Empirically (this build, this macOS version): a cold launch via
    /// `open -a Sweep SomeApp.app` — an application bundle as the "document" — calls the modern
    /// `application(_:open:)` above exactly once with an EMPTY array (apparently just the launch
    /// bookkeeping call every cold launch gets) and instead delivers the real path through this
    /// older, plural, `[String]`-based selector. Implementing both costs nothing — AppKit only
    /// ever invokes whichever one the actual Apple Event maps to — and `NSApplication.reply
    /// (toOpenOrPrint:)` is required here so LaunchServices does not treat the request as having
    /// silently failed.
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        dockDropLog.notice("application(_:openFiles:) received \(filenames.count) path(s): \(filenames.joined(separator: ", "), privacy: .public)")
        for path in filenames { route(URL(fileURLWithPath: path)) }
        sender.reply(toOpenOrPrint: filenames.isEmpty ? .failure : .success)
    }

    private func route(_ url: URL) {
        guard let appState else {
            pendingURLs.append(url)
            return
        }
        appState.openUninstaller(forDroppedAppAt: url)
    }
}
