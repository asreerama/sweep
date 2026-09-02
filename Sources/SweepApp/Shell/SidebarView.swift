import SwiftUI
import SweepUI

/// Two-tier sidebar (PLAN §3), with a compressed icon-rail mode.
///
/// The primary groups scroll; the Toolbox block is pinned to the bottom in a bottom safe-area
/// inset, separated by a rule, drawn a size down and a shade back. The split is structural, not
/// cosmetic: primary modules may auto-select safe items and feed Smart Scan, Toolbox modules
/// never do, and the sidebar is where the user first learns that.
///
/// `isCollapsed` renders the same IA as a 64 pt icon rail instead of hiding the sidebar outright:
/// navigation stays one click away in both states, and the pane is part of the window's own split
/// (see `RootView`), never the macOS 26 floating-glass overlay.
struct SidebarView: View {
    @Binding var selection: Destination
    let showsStressHarness: Bool
    @Binding var isCollapsed: Bool

    var body: some View {
        // The contingency this file always planned for arrived: with Lipo, Plugins and
        // Packages the Toolbox outgrew the 600 pt minimum window, so the primary block scrolls
        // and Toolbox stays a pinned bottom inset. At normal window heights nothing actually
        // scrolls — the ScrollView is taller than its content and the layout reads identically.
        VStack(alignment: .leading, spacing: 0) {
            topStrip

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SidebarGroup.primary) { group in
                        if isCollapsed {
                            // Section headers carry no information an icon rail can use; a
                            // small gap keeps the grouping legible without labels.
                            Color.clear.frame(height: SweepTokens.s2)
                        } else if let title = group.title {
                            SidebarSectionHeader(title)
                        } else {
                            Color.clear.frame(height: SweepTokens.s2)
                        }
                        ForEach(group.destinations) { destination in
                            row(destination)
                        }
                    }
                }
            }

            Spacer(minLength: SweepTokens.s3)

            toolbox
        }
    }

    /// The window has no titlebar (`.hiddenTitleBar`, user-directed): the traffic lights float
    /// over this strip's left edge, and the sidebar toggle takes the trailing slot — or, in the
    /// 72 pt rail, drops below the lights where there is no room beside them. The strip's height
    /// clears the lights so the first row never collides with them.
    @ViewBuilder
    private var topStrip: some View {
        if isCollapsed {
            VStack(spacing: 0) {
                Color.clear.frame(height: 34)
                toggleButton.frame(maxWidth: .infinity)
            }
            .padding(.bottom, SweepTokens.s1)
        } else {
            HStack {
                Spacer()
                toggleButton
            }
            .padding(.horizontal, SweepTokens.s3)
            .frame(height: 44, alignment: .bottom)
        }
    }

    /// The "panel" glyph every modern SaaS sidebar uses, not AppKit's `sidebar.left`.
    private var toggleButton: some View {
        SidebarToggleButton(isCollapsed: $isCollapsed)
    }

    private var toolbox: some View {
        let group = SidebarGroup.toolbox(includingStressHarness: showsStressHarness)
        return VStack(alignment: .leading, spacing: 0) {
            Divider().padding(.horizontal, SweepTokens.s3)
            if isCollapsed {
                Color.clear.frame(height: SweepTokens.s2)
            } else {
                SidebarSectionHeader(group.title ?? "Toolbox", tier: .toolbox)
            }
            ForEach(group.destinations) { destination in
                row(destination)
            }
            Color.clear.frame(height: SweepTokens.s2)
        }
    }

    @ViewBuilder
    private func row(_ destination: Destination) -> some View {
        if isCollapsed {
            SidebarRailRow(
                title: destination.title,
                symbol: destination.symbol,
                tier: destination.tier,
                isSelected: selection == destination
            ) {
                selection = destination
            }
        } else {
            SidebarRow(
                title: destination.title,
                symbol: destination.symbol,
                tier: destination.tier,
                isSelected: selection == destination
            ) {
                selection = destination
            }
        }
    }
}

/// The sidebar collapse control: the filled-left-panel glyph (the Linear/Arc-register "panel"
/// icon, user-directed — not AppKit's `sidebar.left`), quiet until hovered, keeping the ⌘⌃S
/// shortcut the old toolbar button carried.
private struct SidebarToggleButton: View {
    @Binding var isCollapsed: Bool
    @State private var isHovering = false

    var body: some View {
        Button {
            isCollapsed.toggle()
        } label: {
            Image(systemName: "rectangle.leftthird.inset.filled")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(isHovering ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .frame(width: 28, height: 28)
                .background {
                    RoundedRectangle(cornerRadius: SweepTokens.rowRadius - 2, style: .continuous)
                        .fill(isHovering ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear))
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(isCollapsed ? "Expand the sidebar" : "Collapse the sidebar to icons")
        .keyboardShortcut("s", modifiers: [.command, .control])
        .accessibilityLabel(isCollapsed ? "Expand the sidebar" : "Collapse the sidebar")
    }
}

/// One icon-rail entry: the module icon centered in a fixed slot, selection as an accent-tinted
/// pill behind it, the row title surviving as a tooltip and the accessibility label. Toolbox rows
/// keep their quieter plain-glyph treatment, same contract as the full-width rows.
private struct SidebarRailRow: View {
    let title: String
    let symbol: String
    let tier: SidebarTier
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            glyph
                .frame(width: 56, height: tier == .primary ? 52 : 44)
                .background {
                    RoundedRectangle(cornerRadius: SweepTokens.rowRadius, style: .continuous)
                        .fill(background)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(SidebarPressStyle())
        .frame(maxWidth: .infinity)
        .padding(.vertical, 3)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The rail carries the whole module identity in the chip alone, so it runs a size UP from
    /// the full-width rows (36 pt vs 32) with real air between slots — the accessible
    /// "app launcher" read, not a cramped icon strip (user-directed).
    private var glyph: some View {
        ModuleIcon(symbol: symbol, diameter: tier == .primary ? 36 : 30)
            .scaleEffect(isHovering && !isSelected ? 1.07 : 1)
            .animation(SweepMotion.row, value: isHovering)
    }

    private var background: AnyShapeStyle {
        // Same indigo family as the full-width rows' selection — never the system accent.
        if isSelected { return AnyShapeStyle(SweepTokens.accent.opacity(0.20)) }
        if isHovering { return AnyShapeStyle(.fill.quaternary) }
        return AnyShapeStyle(.clear)
    }
}
