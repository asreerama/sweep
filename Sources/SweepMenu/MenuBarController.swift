import AppKit
import SwiftUI

/// Owns the one `NSStatusItem` this process exists for, and the popover it shows/hides. No
/// window of any kind — see `main.swift` for why this is plain AppKit rather than a SwiftUI
/// `MenuBarExtra` scene.
@MainActor
final class MenuBarController: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `LSUIElement` in `scripts/build-menu.sh`'s Info.plist already keeps this off the Dock;
        // setting the activation policy here too means the same binary launched without that key
        // (a debug run via `swift run`, say) still behaves like the shipped accessory app.
        NSApp.setActivationPolicy(.accessory)

        // macos-native-tool skill, Recipe 5: an accessory app with no visible window is a
        // candidate for automatic/sudden termination the moment nothing is on screen — which for
        // this process is always true between popover appearances. It must keep running as a
        // background status item regardless.
        ProcessInfo.processInfo.disableAutomaticTermination("menu bar status item")
        ProcessInfo.processInfo.disableSuddenTermination()

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "wind", accessibilityDescription: "Sweep")
        item.button?.target = self
        item.button?.action = #selector(toggle)
        statusItem = item

        let pop = NSPopover()
        pop.behavior = .transient
        pop.contentViewController = NSHostingController(rootView: MenuPopoverView())
        popover = pop

        MenuBudgetHarness.runIfRequested()
        Task { await MenuScreenshotHarness.runIfRequested() }
    }

    @objc private func toggle() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }
}
