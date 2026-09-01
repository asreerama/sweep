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

        state.scan.start()
        await settle(seconds: scanHold)
        await capture(window, to: output, "\(prefix)-02-smart-scan-scanning", state: state)

        await waitForResults(state.scan, timeout: 600)
        await settle(seconds: 1.0)
        await capture(window, to: output, "\(prefix)-03-smart-scan-results", state: state)

        state.destination = .systemJunk
        await settle(seconds: 0.7)
        await capture(window, to: output, "\(prefix)-04-system-junk", state: state)

        if state.environment.showsStressHarness {
            let before = residentBytes()
            state.destination = .listStress
            await settle(seconds: 2.0)
            await capture(window, to: output, "\(prefix)-05-list-stress", state: state)
            let after = residentBytes()
            print("stress: \(state.environment.stressRowCount)-row inventory resident \(before / 1_048_576) MB -> \(after / 1_048_576) MB")
            await measureScroll(in: window, rows: state.environment.stressRowCount)
        }

        state.destination = .developer
        await settle(seconds: 0.5)
        await capture(window, to: output, "\(prefix)-06-toolbox-placeholder", state: state)

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
        view.displayIfNeeded()
        let url = directory.appending(path: "\(name).png")
        guard let data = render(view, scale: window.backingScaleFactor, state: state) else { return }
        try? data.write(to: url)
        print("snapshot: \(url.lastPathComponent)  resident=\(residentBytes() / 1_048_576) MB")
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
        layer.render(in: context)

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
                    showsStressHarness: state.environment.showsStressHarness
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
