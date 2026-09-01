import AppKit
import Observation

/// Tracks whether any Sweep window is actually on screen.
///
/// The efficiency contract says animations pause when the window is occluded. A `repeatForever`
/// rotation is cheap, but "cheap" times "forever behind another window" is still a background
/// app spending the user's battery on a picture nobody can see.
@MainActor
@Observable
final class WindowVisibility {
    private(set) var isVisible = true

    init() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeOcclusionStateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.isVisible = NSApp.occlusionState.contains(.visible)
            }
        }
    }
}
