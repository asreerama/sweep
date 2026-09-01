import AppKit
import SweepSystem
import SwiftUI

/// Screenshot verification harness (PLAN §6: "UI work verified by screenshot, not assertion").
///
/// Renders `MenuPopoverView` offscreen via `ImageRenderer`, the same "drive the real view, capture
/// without a live screen" shape `Sources/SweepApp/Debug/SnapshotHarness.swift` uses for the main
/// app (that one walks the AppKit `CALayer` tree instead, since it needs a whole window with a
/// native sidebar; a single SwiftUI popover has no such requirement, so `ImageRenderer` alone is
/// enough). This is not a "second choice" taken only because a real popover could not be
/// screenshotted this session — this machine's screen was locked when this harness was built (see
/// this file's own verification: a real `screencapture -l<windowNumber>` against the actual
/// `NSPopover` failed with "could not create image from window" while the screen was locked, and
/// `screencapture` unqualified came back a plain lock-screen photo — the exact scenario PLAN §6's
/// "the offscreen harness pattern in Debug/ if easier" fallback exists for) — so this is that
/// fallback, taken for the documented reason.
///
/// Inert unless `SWEEP_MENU_SCREENSHOT` (a directory) is set.
///
///   SWEEP_MENU_SCREENSHOT=<dir>      output directory (required; harness is off without it)
///   SWEEP_MENU_SCREENSHOT_EXIT=1     quit once both PNGs are written
@MainActor
enum MenuScreenshotHarness {
    static func runIfRequested() async {
        guard let directory = ProcessInfo.processInfo.environment["SWEEP_MENU_SCREENSHOT"] else { return }
        let output = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        // A real reading, sampled up front and injected into every capture below via
        // `MenuPopoverView.init(previewSnapshot:)` — see that initializer's own doc comment for
        // why this has to happen before `ImageRenderer` renders, not through the view's own
        // `.task`. One sample serves both appearances: the numbers are the same either way.
        let snapshot = await StatsSampler().sampleOnce()

        capture(snapshot: snapshot, appearance: .aqua, colorScheme: .light, name: "popover-light", to: output)
        capture(snapshot: snapshot, appearance: .darkAqua, colorScheme: .dark, name: "popover-dark", to: output)

        print("SWEEP_MENU_SCREENSHOT: wrote popover-light.png, popover-dark.png to \(output.path)")
        if ProcessInfo.processInfo.environment["SWEEP_MENU_SCREENSHOT_EXIT"] == "1" {
            NSApp.terminate(nil)
        }
    }

    /// Two separate appearance signals, belt-and-suspenders, for the same reason
    /// `SnapshotHarness.withForcedAppearance` sets both `NSApp.appearance` and
    /// `NSAppearance.current`: `SweepTokens.adaptive` (SweepUI) resolves colors by reading
    /// `NSApp?.effectiveAppearance` directly, a different mechanism from SwiftUI's own
    /// `\.colorScheme`-driven `.primary`/`.secondary`/materials — one or the other rendered wrong
    /// in the main app's own offscreen harness until both were forced, so both are forced here too.
    private static func capture(
        snapshot: SystemSnapshot, appearance: NSAppearance.Name, colorScheme: ColorScheme, name: String, to directory: URL
    ) {
        let previousAppAppearance = NSApp.appearance
        NSApp.appearance = NSAppearance(named: appearance)
        let previousCurrent = NSAppearance.current
        NSAppearance.current = NSAppearance(named: appearance)
        defer {
            NSApp.appearance = previousAppAppearance
            NSAppearance.current = previousCurrent
        }

        let renderer = ImageRenderer(content:
            MenuPopoverView(previewSnapshot: snapshot)
                .background(.regularMaterial)
                .environment(\.colorScheme, colorScheme)
        )
        renderer.scale = 2

        guard let nsImage = renderer.nsImage,
              let tiff = nsImage.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:])
        else {
            FileHandle.standardError.write(Data("MenuScreenshotHarness: failed to render \(name)\n".utf8))
            return
        }
        try? data.write(to: directory.appending(path: "\(name).png"))
    }
}
