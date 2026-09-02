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
    let isCollapsed: Bool

    var body: some View {
        // No `ScrollView`: at the 600 pt minimum window height the whole IA fits with room to
        // spare, and a `Spacer` is what actually pins Toolbox to the bottom. If the Toolbox
        // grows past the fold (Packages, Plugins, Lipo, File Search are queued for v1.1) the
        // primary block gets a scroll view and Toolbox stays a bottom inset.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SidebarGroup.primary) { group in
                if isCollapsed {
                    // Section headers carry no information an icon rail can use; a small gap
                    // keeps the grouping legible without labels.
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

            Spacer(minLength: SweepTokens.s5)

            toolbox
        }
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
                .frame(width: 40, height: tier == .primary ? 32 : 28)
                .background {
                    RoundedRectangle(cornerRadius: SweepTokens.rowRadius, style: .continuous)
                        .fill(background)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 1)
        .onHover { isHovering = $0 }
        .help(title)
        .accessibilityLabel(title)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var glyph: some View {
        if tier == .primary {
            ModuleIcon(symbol: symbol, diameter: 22)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isSelected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
        }
    }

    private var background: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(Color.accentColor.opacity(0.20)) }
        if isHovering { return AnyShapeStyle(.fill.quaternary) }
        return AnyShapeStyle(.clear)
    }
}
