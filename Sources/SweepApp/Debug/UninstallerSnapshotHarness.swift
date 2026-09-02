import AppKit
import SwiftUI

/// Standalone offscreen screenshot harness for the Uninstaller screen (PLAN §3 module 5
/// verification).
///
/// Deliberately its own file rather than a case added to `SnapshotHarness`'s sequence: that
/// sequence now runs Smart Scan through Developer/Homebrew end to end (several minutes on this
/// machine — see its own comments on the Developer step's real-cache walk), and verifying one
/// new screen should not require paying that whole cost, or editing the one file every other
/// module's screenshot evidence already depends on. Same rendering technique — `CALayer
/// .render(in:)` over the real window's backing store, forced appearance for both the display
/// pass and the render pass (see `SnapshotHarness`'s own doc comment for why both are needed) —
/// duplicated in miniature here rather than shared, since the original's helpers are `private`.
///
///   SWEEP_UNINSTALLER_SNAPSHOTS=<dir>   output directory (required; harness is off without it)
///   SWEEP_SNAPSHOT_APPEARANCE=dark      force dark aqua for this run (default: light)
///
/// One process run captures one appearance, same contract as `SnapshotHarness` and for the same
/// reason: `SweepTokens.adaptive` (SweepUI, `Tokens.swift`) is documented as "not independently
/// live-reactive" — it polls `NSApp.effectiveAppearance` eagerly at body-evaluation time rather
/// than through a SwiftUI-tracked environment key, so a view whose body SwiftUI has no other
/// reason to re-run will not pick up a *later* appearance flip. Setting the appearance once,
/// before the very first frame of this run ever draws, is what the rest of the app already relies
/// on — flipping it mid-run (tried during development of this file) left already-materialized
/// subtrees showing stale colors for tokens that were not otherwise forced to re-evaluate.
@MainActor
enum UninstallerSnapshotHarness {
    static func runIfRequested(state: AppState) async {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["SWEEP_UNINSTALLER_SNAPSHOTS"] else { return }
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

        await settle(1.0)
        guard let window = mainWindow() else {
            FileHandle.standardError.write(Data("uninstaller snapshot harness: no window\n".utf8))
            return
        }
        // SWEEP_SNAPSHOT_WIDTH lets a run capture at the window's minimum (the layout-contract
        // crush case) instead of the comfortable default.
        let width = Double(environment["SWEEP_SNAPSHOT_WIDTH"] ?? "") ?? 1060
        window.setContentSize(NSSize(width: width, height: 700))
        state.destination = .uninstaller
        state.uninstall.loadApps()
        await waitFor(timeout: 30) { !state.uninstall.isLoadingApps }
        await settle(0.6)

        await capture(window, to: output, "\(prefix)-01-uninstaller-list")

        if let target = state.uninstall.apps.first(where: { !state.uninstall.isProtected($0) }) {
            state.uninstall.select(target)
            await waitFor(timeout: 30) { !state.uninstall.isLoadingLeftovers }
            await settle(0.6)
            await capture(window, to: output, "\(prefix)-02-uninstaller-leftovers")

            state.uninstall.previewSheetShown = true
            // Generous on purpose: the sheet's spring-in presentation plus its own
            // `.fixedSize(horizontal: false, vertical: true)` layout pass need to fully settle
            // before `capture` reads `window.contentView.bounds` — caught this cropping the sheet
            // mid-animation at 0.5s during this harness's own development.
            await settle(1.2)
            if let sheet = window.attachedSheet {
                await capture(sheet, to: output, "\(prefix)-03-uninstaller-preview-sheet")
            } else {
                FileHandle.standardError.write(Data("uninstaller snapshot harness: no sheet attached\n".utf8))
            }
            state.uninstall.previewSheetShown = false
        } else {
            FileHandle.standardError.write(Data("uninstaller snapshot harness: no selectable app on this machine\n".utf8))
        }

        print("uninstaller snapshot harness: wrote \(prefix) captures to \(output.path)")
        if environment["SWEEP_SNAPSHOT_EXIT"] == "1" {
            await settle(0.3)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Plumbing

    private static func mainWindow() -> NSWindow? {
        NSApp.windows
            .filter { $0.contentView != nil && $0.styleMask.contains(.titled) }
            .max { lhs, rhs in lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height }
    }

    private static func waitFor(timeout: Double, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { await settle(0.2) }
    }

    private static func settle(_ seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(60))
    }

    private static func capture(_ window: NSWindow, to directory: URL, _ name: String) async {
        guard let view = window.contentView else { return }
        // A sheet's own `.fixedSize` layout pass can still be catching up to its final height at
        // this point (seen empirically: dark-appearance captures of the removal-preview sheet
        // came back cropped to its scroll content alone, missing the title and footer, at a byte
        // size stable across repeated runs — a settled-but-wrong layout, not a race). Forcing one
        // more layout pass before measuring is what actually fixes it, on top of the `settle`
        // delay the caller already waits before getting here.
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
        print("uninstaller snapshot: \(name).png")
    }

    private static var currentAppearance: NSAppearance { NSApp.effectiveAppearance }

    private static func withForcedAppearance<T>(_ body: () -> T) -> T {
        let previous = NSAppearance.current
        NSAppearance.current = currentAppearance
        defer { NSAppearance.current = previous }
        return body()
    }
}
