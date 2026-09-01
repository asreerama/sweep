import AppKit
import SwiftUI

/// Standalone offscreen screenshot harness for `OnboardingFlow` (PLAN §6: "UI work verified by
/// screenshot, not assertion"), same shape as `UninstallerSnapshotHarness`: its own file rather
/// than a case added to `SnapshotHarness`'s already-long sequence, since verifying three new
/// onboarding steps has nothing to do with that one's Smart Scan → Toolbox walk.
///
/// Hosts `OnboardingFlow` in its own `NSWindow` — not the production `.sheet` trigger
/// (`SweepApp.swift`) — specifically so every step can be captured independently via
/// `OnboardingFlow`'s `initialStep` seam, rather than needing to drive three real button clicks
/// (Continue/Continue/Start Smart Scan) through the FDA step's live capability probing along the
/// way. What lands on disk is still the shipping view's real body, rendered through the same
/// `CALayer.render(in:)` backing-store technique both other harnesses use — only *how the window
/// hosting it gets created* differs, not what gets drawn inside it.
///
///   SWEEP_ONBOARDING_SNAPSHOTS=<dir>   output directory (required; harness is off without it)
///   SWEEP_SNAPSHOT_APPEARANCE=dark     force dark aqua for this run (default: light)
///
/// One process run captures one appearance — see `SnapshotHarness`'s own doc comment for why
/// (`SweepTokens.adaptive` is not independently live-reactive; the appearance must be set before
/// the first frame of the run ever draws).
@MainActor
enum OnboardingSnapshotHarness {
    static func runIfRequested() async {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["SWEEP_ONBOARDING_SNAPSHOTS"] else { return }
        let output = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        let prefix: String
        if environment["SWEEP_SNAPSHOT_APPEARANCE"] == "dark" {
            NSApp.appearance = NSAppearance(named: .darkAqua)
            prefix = "dark"
        } else {
            NSApp.appearance = NSAppearance(named: .aqua)
            prefix = "light"
        }

        for step in OnboardingFlow.Step.allCases {
            let window = makeWindow(for: step)
            window.makeKeyAndOrderFront(nil)
            await settle(1.0)
            await capture(window, to: output, "\(prefix)-onboarding-\(step.rawValue + 1)-\(name(for: step))")
            window.close()
        }

        print("onboarding snapshot harness: wrote \(prefix) captures to \(output.path)")
        if environment["SWEEP_SNAPSHOT_EXIT"] == "1" {
            await settle(0.3)
            // `exit(0)` rather than `NSApp.terminate(nil)`: this harness's windows are plain
            // `NSWindow`s created and closed by hand (`makeWindow(for:)`), never routed through
            // the app's own `Window` scene the way `SnapshotHarness`/`UninstallerSnapshotHarness`
            // are — empirically, `terminate(nil)` after that path left the process parked in the
            // run loop instead of quitting. Every file this harness writes is already flushed
            // synchronously (`Data.write(to:)` in `capture(_:to:_:)`) by the time this line runs,
            // so a hard exit here drops nothing.
            exit(0)
        }
    }

    // MARK: - Plumbing

    private static func name(for step: OnboardingFlow.Step) -> String {
        switch step {
        case .welcome: "welcome"
        case .fullDiskAccess: "full-disk-access"
        case .finish: "finish"
        }
    }

    /// `OnboardingFlow`'s own body fixes its frame at 580x640 (see `Screens/OnboardingFlow.swift`)
    /// — the same size the production `.sheet` presents at — so the window is created at exactly
    /// that content size rather than left to `NSHostingController`'s intrinsic-size guess, which
    /// only settles after a layout pass this harness would otherwise have to wait an extra beat
    /// to be sure of.
    private static func makeWindow(for step: OnboardingFlow.Step) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 640),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(
            rootView: OnboardingFlow(initialStep: step, onComplete: { _ in })
        )
        return window
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(60))
    }

    private static func capture(_ window: NSWindow, to directory: URL, _ name: String) async {
        guard let view = window.contentView else { return }
        view.layoutSubtreeIfNeeded()
        withForcedAppearance { view.displayIfNeeded() }

        guard let layer = view.layer else { return }
        let scale = window.backingScaleFactor
        let size = view.bounds.size
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0, let context = CGContext(
            data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }

        if view.isFlipped {
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: scale, y: -scale)
        } else {
            context.scaleBy(x: scale, y: scale)
        }
        withForcedAppearance {
            currentAppearance.performAsCurrentDrawingAppearance {
                layer.render(in: context)
            }
        }

        guard let image = context.makeImage() else { return }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: directory.appending(path: "\(name).png"))
        print("onboarding snapshot: \(name).png")
    }

    private static var currentAppearance: NSAppearance { NSApp.effectiveAppearance }

    private static func withForcedAppearance<T>(_ body: () -> T) -> T {
        let previous = NSAppearance.current
        NSAppearance.current = currentAppearance
        defer { NSAppearance.current = previous }
        return body()
    }
}
