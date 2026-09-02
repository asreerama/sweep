import AppKit
import SwiftUI

/// Offscreen screenshot harness for design review.
///
/// PLAN §6: "UI work verified by screenshot, not assertion." This renders the *real* window's
/// content view through the AppKit backing store, so what lands on disk is the shipping layout
/// at the shipping backing scale — no separate preview tree that could drift from it, and no
/// dependency on the screen being awake, unlocked, or attached.
///
/// Inert unless `SWEEP_SNAPSHOTS` names an output directory. It drives the shell through
/// ``AppState``, the same values the sidebar sets, so nothing here reaches into a screen.
///
///   SWEEP_SNAPSHOTS=<dir>            output directory (required; harness is off without it)
///   SWEEP_SNAPSHOT_APPEARANCE=dark   force dark aqua for this run (default: system)
///   SWEEP_SNAPSHOT_SCAN_WAIT=<sec>   how long to hold the scanning frame before capturing
///   SWEEP_SNAPSHOT_EXIT=1            quit once the sequence completes
@MainActor
enum SnapshotHarness {

    static func runIfRequested(state: AppState) async {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["SWEEP_SNAPSHOTS"] else { return }
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

        let scanHold = Double(environment["SWEEP_SNAPSHOT_SCAN_WAIT"] ?? "") ?? 1.0

        await settle(seconds: 1.2)
        guard let window = mainWindow() else {
            FileHandle.standardError.write(Data("snapshot harness: no window\n".utf8))
            return
        }
        window.setContentSize(NSSize(width: 1060, height: 700))
        await settle(seconds: 0.6)

        if environment["SWEEP_SNAPSHOT_DUMP"] == "1", let root = window.contentView {
            dump(root, depth: 0)
        }

        await capture(window, to: output, "\(prefix)-01-smart-scan-idle", state: state)

        if environment["SWEEP_SNAPSHOT_MEMORY_ONLY"] == "1" {
            state.destination = .memory
            await settle(seconds: 5.0)
            if let root = window.contentView { dump(root, depth: 0) }
            await capture(window, to: output, "\(prefix)-06c-memory", state: state)
            if environment["SWEEP_SNAPSHOT_EXIT"] == "1" { await settle(seconds: 0.3); await MainActor.run { NSApp.terminate(nil) } }
            return
        }

        // Same fast-iteration shape as MEMORY_ONLY, for the Maintenance screen.
        if environment["SWEEP_SNAPSHOT_MAINTENANCE_ONLY"] == "1" {
            state.destination = .maintenance
            await settle(seconds: 3.0)
            await capture(window, to: output, "\(prefix)-06d-maintenance", state: state)
            if environment["SWEEP_SNAPSHOT_EXIT"] == "1" { await settle(seconds: 0.3); await MainActor.run { NSApp.terminate(nil) } }
            return
        }

        state.scan.start()
        await settle(seconds: scanHold)
        await capture(window, to: output, "\(prefix)-02-smart-scan-scanning", state: state)

        await waitForResults(state.scan, timeout: 600)
        // Motion continuity evidence (PLAN §5): the model already says `.results`, but
        // `SmartScanScreen` holds the ring in its scanning slot for `SweepMotion
        // .resultsMorphDelay` while it decelerates and closes. A short settle here catches that
        // in-flight frame; the longer settle below waits past it for the fully morphed layout.
        await settle(seconds: 0.35)
        await capture(window, to: output, "\(prefix)-02b-smart-scan-settling-mid-transition", state: state)
        await settle(seconds: 1.4)
        await capture(window, to: output, "\(prefix)-03-smart-scan-results", state: state)

        state.destination = .systemJunk
        await settle(seconds: 0.7)
        await capture(window, to: output, "\(prefix)-04-system-junk", state: state)

        if state.environment.showsStressHarness {
            let before = residentBytes()
            state.destination = .listStress
            await settle(seconds: 2.0)
            await capture(window, to: output, "\(prefix)-05-list-stress", state: state)
            // PLAN §6b evidence: the full window, native titlebar included, at whatever row
            // count `SWEEP_UI_STRESS` requested. Bounded expansion keeps rendered rows (and so
            // scroll-content height) flat regardless of this number — this is the screenshot
            // that shows the titlebar is not corrupted at that row count.
            await captureFullWindowForTitlebarEvidence(
                window, to: output, "\(prefix)-05b-titlebar-evidence-\(state.environment.stressRowCount)rows"
            )
            let after = residentBytes()
            print("stress: \(state.environment.stressRowCount)-row inventory resident \(before / 1_048_576) MB -> \(after / 1_048_576) MB")
            await measureScroll(in: window, rows: state.environment.stressRowCount)

            state.destination = .cleanFlowPreview
            for phase in CleanFlowPreviewPhase.allCases {
                state.cleanFlowPreviewPhase = phase
                await settle(seconds: 0.5)
                await capture(window, to: output, "\(prefix)-05c-clean-flow-\(phase.rawValue)", state: state)
            }
        }

        // Toolbox (PLAN §3): Developer and Homebrew each own their scan/refresh state, not
        // `state.scan`, so — unlike every capture above — nothing here triggers their data load;
        // that happens on `SWEEP_TOOLBOX_AUTOSCAN` (Developer) and on appear (Homebrew, a fast
        // read-mostly listing, see `HomebrewScreen`). The settle windows below are generous
        // enough to catch a real scan/refresh landing when that env var is set for the run.
        // Both real-data loads below can run against the real account (Developer's `userCaches`-
        // rooted rules ignore `SWEEP_HOME` — `SweepPolicy.candidateRootURLs(for: .userCaches, ...)`
        // always asks `FileManager` for the real cachesDirectory regardless of the `home` argument
        // — and Homebrew always talks to the real `brew`), so these settle windows are generous
        // rather than the ~1s the rest of this sequence uses.
        state.destination = .developer
        // Empirically the slowest step in this whole sequence on this machine: the `developer`
        // catalog's `userCaches`/`developerToolCaches`-rooted rules walk this account's real,
        // heavily-used `~/Library/Caches` and `~/Library/Developer/CoreSimulator/Caches` in full
        // (unbounded depth, same as any other rule-catalog scan) — measured over a minute here,
        // well past Smart Scan's own full-catalog walk moments earlier in this same run, most
        // likely because CoreSimulator's cache tree dwarfs a plain app-cache walk file-for-file.
        await settle(seconds: 90.0)
        await capture(window, to: output, "\(prefix)-06-toolbox-developer", state: state)

        state.destination = .homebrew
        await settle(seconds: 20.0)
        await capture(window, to: output, "\(prefix)-06b-toolbox-homebrew", state: state)

        state.destination = .memory
        await settle(seconds: 4.0)
        await capture(window, to: output, "\(prefix)-06c-memory", state: state)

        // Minimum supported window: 900x600. Everything above must still fit here.
        state.destination = .smartScan
        window.setContentSize(NSSize(width: 900, height: 600))
        await settle(seconds: 0.9)
        await capture(window, to: output, "\(prefix)-07-minimum-size-results", state: state)

        state.destination = .systemJunk
        await settle(seconds: 0.6)
        await capture(window, to: output, "\(prefix)-08-minimum-size-junk", state: state)

        print("snapshot harness: wrote \(prefix) set to \(output.path)")
        if environment["SWEEP_SNAPSHOT_EXIT"] == "1" {
            await settle(seconds: 0.3)
            NSApp.terminate(nil)
        }
    }

    // MARK: - Plumbing

    private static func dump(_ view: NSView, depth: Int) {
        let indent = String(repeating: "  ", count: depth)
        let layerNote = view.layer == nil ? "no-layer" : "layer=\(type(of: view.layer!)) sublayers=\(view.layer?.sublayers?.count ?? 0)"
        FileHandle.standardError.write(Data(
            "\(indent)\(type(of: view)) frame=\(NSStringFromRect(view.frame)) \(layerNote)\n".utf8
        ))
        guard depth < 6 else { return }
        for child in view.subviews { dump(child, depth: depth + 1) }
    }

    private static func mainWindow() -> NSWindow? {
        NSApp.windows
            .filter { $0.contentView != nil && $0.styleMask.contains(.titled) }
            .max { lhs, rhs in
                lhs.frame.width * lhs.frame.height < rhs.frame.width * rhs.frame.height
            }
    }

    private static func waitForResults(_ scan: ScanModel, timeout: Double) async {
        let deadline = Date().addingTimeInterval(timeout)
        while scan.isScanning, Date() < deadline {
            await settle(seconds: 0.25)
        }
    }

    private static func settle(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
        // Let AppKit finish the display pass the state change scheduled, before it is captured.
        await Task.yield()
        try? await Task.sleep(for: .milliseconds(60))
    }

    private static func capture(_ window: NSWindow, to directory: URL, _ name: String, state: AppState) async {
        guard let view = window.contentView else { return }
        // Forced appearance spans the display pass too, not just the render pass below: a
        // dynamic `NSColor` inside a SwiftUI `Color` can resolve as early as `displayIfNeeded()`
        // evaluates view bodies, not only when `CALayer.render(in:)` walks the finished layers.
        withForcedAppearance { view.displayIfNeeded() }
        let url = directory.appending(path: "\(name).png")
        guard let data = render(view, scale: window.backingScaleFactor, state: state) else { return }
        try? data.write(to: url)
        print("snapshot: \(url.lastPathComponent)  resident=\(residentBytes() / 1_048_576) MB")
    }

    /// Renders the *whole* window — including the native titlebar strip above `contentView`,
    /// where PLAN §6b's corruption actually shows up — rather than just the content area.
    ///
    /// `window.contentView`'s superview is AppKit's private theme-frame view, which owns the
    /// traffic lights and title text; capturing its layer instead of `contentView`'s is the only
    /// way an offscreen render can show whether the titlebar itself is intact. Skips the sidebar
    /// overlay compositing `capture(_:to:_:state:)` does for the shipping screenshots: this exists
    /// to answer one question — is the titlebar corrupted — not to look production-ready.
    private static func captureFullWindowForTitlebarEvidence(
        _ window: NSWindow, to directory: URL, _ name: String
    ) async {
        guard let content = window.contentView else { return }
        let root = content.superview ?? content
        withForcedAppearance { root.displayIfNeeded() }
        guard let layer = root.layer else { return }
        let scale = window.backingScaleFactor
        let size = root.bounds.size
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return }
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return }
        // `contentView` (used by `render(_:scale:state:)` above) is flipped, so that function's
        // fixed flip transform is correct there. AppKit's private theme-frame view — `root` here
        // — is not, and applying the same transform to a non-flipped layer draws it upside down
        // (traffic lights at the bottom). `CALayer.render(in:)` takes the CTM as given and does
        // not correct for this itself, so the two cases need their own transforms.
        if root.isFlipped {
            context.translateBy(x: 0, y: CGFloat(pixelHeight))
            context.scaleBy(x: scale, y: -scale)
        } else {
            context.scaleBy(x: scale, y: scale)
        }
        // See the matching comment in `render(_:scale:state:)`.
        withForcedAppearance {
            currentAppearance.performAsCurrentDrawingAppearance {
                layer.render(in: context)
            }
        }
        guard let image = context.makeImage() else { return }
        let representation = NSBitmapImageRep(cgImage: image)
        guard let data = representation.representation(using: .png, properties: [:]) else { return }
        let url = directory.appending(path: "\(name).png")
        try? data.write(to: url)
        print("snapshot: \(url.lastPathComponent) (full window, titlebar evidence)")
    }

    /// Renders the window's layer tree.
    ///
    /// `cacheDisplay(in:to:)` walks the AppKit draw path and comes back with the split view's
    /// sidebar blank, because that column is a layer-hosted `NSVisualEffectView` that never
    /// draws through `drawRect`. Rendering the root `CALayer` instead picks up every sublayer
    /// the window server would composite.
    private static func render(_ view: NSView, scale: CGFloat, state: AppState) -> Data? {
        guard let layer = view.layer else { return nil }
        let size = view.bounds.size
        let pixelWidth = Int(size.width * scale)
        let pixelHeight = Int(size.height * scale)
        guard pixelWidth > 0, pixelHeight > 0 else { return nil }

        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }

        // CoreGraphics is origin-bottom-left, the layer tree is origin-top-left.
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: scale, y: -scale)
        // `CALayer.render(in:)` draws outside AppKit's normal display cycle, which is what
        // usually brackets a draw with an active `NSAppearance` — every custom dynamic `NSColor`
        // (the whole Palette v2 token set) resolved to its light variant under a forced dark run
        // without this, even though `NSApp.appearance` was set correctly and system materials
        // (`.bar`, `NSVisualEffectView`) rendered dark regardless, because those bake in their
        // appearance during the `displayIfNeeded()` call above instead.
        withForcedAppearance {
            currentAppearance.performAsCurrentDrawingAppearance {
                layer.render(in: context)
            }
        }

        // The sidebar column will not read back offscreen on macOS 26: the split view hosts it
        // inside an `NSContainerConcentricGlassEffectView` whose backdrop and mask layers only
        // exist while the window server is compositing, and both the layer walk and the AppKit
        // cache path return an empty column. Re-render the same `SidebarView`, with the same
        // selection, through `ImageRenderer` and draw it into the column's real frame.
        if let column = sidebarFrame(in: view) {
            // The live column extends under the unified titlebar and SwiftUI insets its content
            // by the titlebar safe area; `ImageRenderer` has no safe area, so apply the same
            // inset by hand or the top row lands under the traffic lights in the capture.
            let titlebarInset = max(0, titlebarHeight(of: view) - column.minY)
            let renderer = ImageRenderer(
                content: SidebarView(
                    selection: .constant(state.destination),
                    showsStressHarness: state.environment.showsStressHarness,
                    isCollapsed: .constant(false)
                )
                .padding(.top, titlebarInset)
                .frame(width: column.width, height: column.height)
                // The live column's ground is a window-server backdrop that is not there
                // offscreen; paint the appearance's window background so the composite reads
                // the way the running app does.
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.colorScheme, isDarkAppearance ? .dark : .light)
            )
            renderer.scale = scale
            if let image = renderer.cgImage {
                let topLeftY = view.isFlipped ? column.minY : view.bounds.height - column.maxY
                context.saveGState()
                context.translateBy(x: column.minX, y: topLeftY + column.height)
                context.scaleBy(x: 1, y: -1)
                context.draw(image, in: CGRect(x: 0, y: 0, width: column.width, height: column.height))
                context.restoreGState()
            }
        }

        guard let image = context.makeImage() else { return nil }
        let representation = NSBitmapImageRep(cgImage: image)
        return representation.representation(using: .png, properties: [:])
    }

    /// Jumps the inventory scroll view to a series of offsets and times the synchronous layout
    /// and display each jump forces.
    ///
    /// This is the cost that would show up as a dropped frame: every jump lands on rows that
    /// have never been built, so SwiftUI has to evaluate their bodies before it can draw. A
    /// 120 Hz frame is 8.3 ms; anything comfortably under that scrolls clean.
    private static func measureScroll(in window: NSWindow, rows: Int) async {
        guard let root = window.contentView, let scrollView = firstScrollView(in: root) else {
            print("stress: no scroll view found")
            return
        }
        let document = scrollView.documentView?.frame.height ?? 0
        let visible = scrollView.contentView.bounds.height
        let travel = max(0, document - visible)
        guard travel > 0 else {
            print("stress: content fits, nothing to scroll")
            return
        }

        func sweep(_ label: String, offsets: [CGFloat]) async {
            var worst: Double = 0
            var total: Double = 0
            for offset in offsets {
                let start = ContinuousClock.now
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                root.layoutSubtreeIfNeeded()
                root.displayIfNeeded()
                let elapsed = Double((ContinuousClock.now - start).components.attoseconds) / 1e15
                worst = max(worst, elapsed)
                total += elapsed
                await Task.yield()
            }
            print(String(
                format: "stress: %d rows, %@ — mean %.2f ms, worst %.2f ms (120 Hz budget 8.33 ms)",
                rows, label, total / Double(offsets.count), worst
            ))
        }

        // Teleports: every jump lands on rows that have never been built. Worst case.
        let stops = 24
        await sweep(
            "\(stops) cold jumps over \(Int(travel)) pt",
            offsets: (1...stops).map { travel * CGFloat($0) / CGFloat(stops) }
        )

        // Continuous scrolling: what a trackpad actually does, reusing most visible rows.
        scrollView.contentView.scroll(to: .zero)
        await sweep(
            "160 continuous 40 pt steps",
            offsets: (1...160).map { min(travel, CGFloat($0) * 40) }
        )
    }

    private static func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView, scrollView.documentView != nil { return scrollView }
        for child in view.subviews {
            if let found = firstScrollView(in: child) { return found }
        }
        return nil
    }

    /// Resident footprint, so the virtualisation claim is a measurement rather than an
    /// assertion: a `LazyVStack` that quietly materialised all ten thousand rows would show up
    /// here as tens of megabytes.
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }

    private static func titlebarHeight(of view: NSView) -> CGFloat {
        guard let window = view.window else { return 52 }
        return max(0, window.frame.height - window.contentLayoutRect.height)
    }

    private static var isDarkAppearance: Bool {
        NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    private static var currentAppearance: NSAppearance {
        NSApp.effectiveAppearance
    }

    /// Forces `NSAppearance.current` for the duration of `body` — belt-and-suspenders alongside
    /// `performAsCurrentDrawingAppearance` at each `layer.render(in:)` call. A dynamic `NSColor`
    /// resolves its `dynamicProvider` against whichever of these actually reflects the forced
    /// appearance at that exact call site; setting both, rather than picking one, is cheaper than
    /// re-diagnosing which one a given macOS version honors for a `CALayer` walk outside the
    /// normal AppKit display cycle.
    private static func withForcedAppearance<T>(_ body: () -> T) -> T {
        let previous = NSAppearance.current
        NSAppearance.current = currentAppearance
        defer { NSAppearance.current = previous }
        return body()
    }

    /// The split view's sidebar column, in the content view's coordinates.
    private static func sidebarFrame(in view: NSView) -> CGRect? {
        var found: CGRect?
        func walk(_ current: NSView) {
            let name = String(describing: type(of: current))
            if name.contains("ConcentricGlassEffectView"), current.bounds.width < view.bounds.width / 2 {
                found = current.convert(current.bounds, to: view)
                return
            }
            for child in current.subviews where found == nil { walk(child) }
        }
        walk(view)
        return found
    }
}
