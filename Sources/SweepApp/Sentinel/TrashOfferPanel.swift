import AppKit
import SwiftUI

/// The SmartDelete watcher's quiet offer: "Clean up leftovers of <App>?"
///
/// A non-activating panel (`.nonactivatingPanel`) — it never steals focus or key window status
/// from whatever the user was doing when they dragged an app to the Trash. Accepting routes
/// through the same `sweep://open-uninstall-orphan` deep link the Dock/document-open path uses
/// (`AppState.handleOpenURL`), so there is exactly one place in the app that opens the Uninstaller
/// in orphan mode, regardless of which entry point triggered it.
@MainActor
enum TrashOfferPanel {
    private static var current: NSPanel?
    private static var dismissWorkItem: DispatchWorkItem?

    static func show(appName: String, bundleIdentifier: String) {
        current?.close()
        dismissWorkItem?.cancel()

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 108),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hasShadow = true
        panel.backgroundColor = .clear

        let content = TrashOfferContent(
            appName: appName,
            onClean: {
                openUninstaller(bundleIdentifier: bundleIdentifier)
                panel.close()
            },
            onDismiss: { panel.close() }
        )
        let hosting = NSHostingView(rootView: content)
        panel.contentView = hosting
        hosting.frame = NSRect(x: 0, y: 0, width: 320, height: 108)

        if let screenFrame = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screenFrame.maxX - 340, y: screenFrame.minY + 24))
        }

        panel.orderFrontRegardless()
        current = panel

        // An offer nobody acts on should not linger forever.
        let workItem = DispatchWorkItem { panel.close() }
        dismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: workItem)
    }

    /// Round-trips through `NSWorkspace.open(_:)` rather than calling `AppState` directly: this
    /// is the same URL the Dock/document-open route produces, so accepting the offer exercises
    /// the identical deep-link path a future out-of-process Sentinel (or an external `sweep://`
    /// link) would also use.
    private static func openUninstaller(bundleIdentifier: String) {
        var components = URLComponents()
        components.scheme = "sweep"
        components.host = "open-uninstall-orphan"
        components.queryItems = [URLQueryItem(name: "bundleID", value: bundleIdentifier)]
        guard let url = components.url else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct TrashOfferContent: View {
    let appName: String
    let onClean: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "trash.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.orange)
                Text("Clean up leftovers of \(appName)?")
                    .font(.system(size: 12.5, weight: .medium))
                    .lineLimit(2)
                Spacer(minLength: 0)
                Button(action: onDismiss) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            HStack {
                Spacer()
                Button("Not Now", action: onDismiss)
                    .buttonStyle(.plain)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                Button("Clean Up", action: onClean)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(.separator, lineWidth: 0.5)
        }
    }
}
