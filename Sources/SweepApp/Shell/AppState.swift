import Foundation
import Observation

/// Navigation state plus the one scan every screen reads.
///
/// Lifted out of `RootView` so the selected destination is a real value someone else can set —
/// Smart Scan's "Review items" hands off through it, and the snapshot harness drives the whole
/// shell through it without any screen growing a debug hook of its own.
@MainActor
@Observable
final class AppState {
    var destination: Destination = .smartScan
    let scan: ScanModel
    let environment: ScanEnvironment
    /// Uninstaller (module 5): one model shared by the screen, the drop targets and the
    /// SmartDelete watcher's deep link, so all three land on the exact same selection state.
    let uninstall = UninstallModel()

    /// Which state `CleanFlowPreviewScreen` (Toolbox debug harness) shows. Lifted out to
    /// `AppState`, same reasoning as `destination`: the snapshot harness drives it externally
    /// without the screen growing a debug hook of its own.
    var cleanFlowPreviewPhase: CleanFlowPreviewPhase = .confirm

    init(environment: ScanEnvironment) {
        self.environment = environment
        self.scan = ScanModel(environment: environment)
        // Debug: launch straight into a destination for live screenshot/repro (never set in normal use).
        if let raw = ProcessInfo.processInfo.environment["SWEEP_START_DESTINATION"],
           let dest = Destination(rawValue: raw) {
            self.destination = dest
        }
    }

    // MARK: - Uninstaller deep links (PLAN §3 module 5, AppCleaner parity)

    /// Both drop routes — the window's `dropDestination` and the Dock/`application(_:open:)`
    /// fallback (`SweepAppDelegate`, see `SweepApp.swift`) — call this directly with the dropped
    /// `.app`'s URL.
    func openUninstaller(forDroppedAppAt url: URL) {
        destination = .uninstaller
        uninstall.selectDroppedApp(at: url)
    }

    /// `.onOpenURL`'s handler. Currently just the SmartDelete watcher's own
    /// `sweep://open-uninstall-orphan?bundleID=...` offer accept action (`TrashOfferPanel`), kept
    /// as a real URL scheme rather than a direct model call so a future out-of-process Sentinel —
    /// or any other `sweep://` deep link — has exactly one place to route through.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "sweep" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "open-uninstall":
            guard let path = items.first(where: { $0.name == "path" })?.value else { return }
            openUninstaller(forDroppedAppAt: URL(fileURLWithPath: path))
        case "open-uninstall-orphan":
            guard let bundleID = items.first(where: { $0.name == "bundleID" })?.value else { return }
            destination = .uninstaller
            uninstall.selectOrphan(bundleIdentifier: bundleID)
        default:
            break
        }
    }
}
