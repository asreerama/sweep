import AppKit
import Darwin

// Unbuffered stdout: `MenuBudgetHarness`/`MenuScreenshotHarness` print single diagnostic lines
// from a process that (unlike a normal CLI tool) never exits on its own to flush a full stdio
// buffer for them — without this, redirecting stdout to a file (`open --stdout`, `> log.txt &`)
// shows nothing until the process is eventually killed.
setbuf(stdout, nil)

// SweepMenu entry point (PLAN §3 module 7, the P4-B decision-gate split). A bare AppKit accessory
// app — no SwiftUI `App`/`Scene` anywhere in this target, on purpose.
//
// Measured side-by-side while building this target (idle RSS, `ps -o rss=`, 60 s after launch,
// three throwaway probes signed and launched the same way real bundles are):
//   - SwiftUI `App` with only a `MenuBarExtra` scene:                        ~72.0 MB
//   - Plain AppKit `NSStatusItem`, no SwiftUI linked at all:                 ~43.4 MB
//   - AppKit `NSStatusItem` + `NSPopover` hosting a real SwiftUI view
//     (`NSHostingController`, same shape this target ships):                ~45.3 MB
// The Scene/App machinery itself — not "SwiftUI" in general — is the ~27 MB difference; hosting
// SwiftUI content inside a plain `NSPopover` costs almost nothing extra over pure AppKit. That is
// the whole reason `MenuBarController` below builds the status item and popover by hand instead
// of declaring a `MenuBarExtra` scene, and why `MenuPopoverView`'s SwiftUI body is reached only
// through `NSHostingController`, never through an `App`.
let delegate = MenuBarController()
let app = NSApplication.shared
app.delegate = delegate
app.run()
