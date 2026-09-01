import AppKit
import Foundation

/// "Open Sweep" (PLAN §3 module 7's quick action). Launches the main app through its own
/// `sweep://` URL scheme (`CFBundleURLTypes`, registered by `scripts/build-app.sh`) rather than
/// resolving and opening `Sweep.app` by path: `NSWorkspace.open(_:)` on a registered custom scheme
/// launches the app if it isn't running and activates it if it already is, in one call — both
/// "launch the main app" and "deep link" in a single action, matching the AppCleaner-parity
/// `sweep://` front door `AppState.handleOpenURL` (`Sources/SweepApp/Shell/AppState.swift`)
/// already owns. No query string today (nothing past the root to deep-link to from the menu bar
/// popover yet); a menu-bar-specific destination is a query item away whenever one is needed,
/// through the exact same URL.
enum MenuQuickActions {
    static let openSweepURL = URL(string: "sweep://")!

    static func openSweep(workspace: NSWorkspace = .shared) {
        workspace.open(openSweepURL)
    }
}
