import SwiftUI

/// The sidebar's two tiers, expressed as one enum so the difference is a data choice rather
/// than duplicated view code.
///
/// Scale v4 (user-directed: "they are the main features of the app"): primary rows are 15 pt
/// medium on a 44 pt row with a 32 pt module chip — the modules read as the app's marquee
/// destinations, not an Xcode inspector's filter list. Toolbox rows sit one visible step down
/// (14 pt regular, 38 pt row, 26 pt chip): advanced tools, quieter, out of the way, exactly
/// the contract in PLAN §3 — Toolbox modules never auto-select and never feed Smart Scan, and
/// the sidebar should say so before the user clicks anything.
public enum SidebarTier: Sendable {
    case primary
    case toolbox

    var font: Font { self == .primary ? SweepFont.sidebarPrimary : SweepFont.sidebarToolbox }
    var rowHeight: CGFloat { self == .primary ? 44 : 38 }
    var glyphSize: CGFloat { self == .primary ? 15 : 13.5 }
    var glyphWidth: CGFloat { self == .primary ? 32 : 26 }
    var indent: CGFloat { self == .primary ? SweepTokens.s2 : SweepTokens.s2 }
}

/// Press feedback for the sidebar's module rows in both layouts (full-width and icon rail):
/// a quick settle-down on press, released on the same spring. The punch that makes a row feel
/// like a button rather than a list line.
public struct SidebarPressStyle: ButtonStyle {
    public init() {}

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.965 : 1)
            .animation(.spring(response: 0.22, dampingFraction: 0.75), value: configuration.isPressed)
    }
}

/// Uppercase group label. `CLEAN`, `SPEED`, `APPS`, `TOOLBOX`.
public struct SidebarSectionHeader: View {
    private let title: String
    private let tier: SidebarTier

    public init(_ title: String, tier: SidebarTier = .primary) {
        self.title = title
        self.tier = tier
    }

    public var body: some View {
        Text(title.uppercased())
            .font(SweepFont.sidebarSection)
            .tracking(0.7)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, SweepTokens.s3)
            .padding(.top, tier == .primary ? SweepTokens.s4 : SweepTokens.s3)
            .padding(.bottom, SweepTokens.s1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A selectable sidebar row.
///
/// Selection is drawn rather than delegated to `List`, because the Toolbox block is pinned to
/// the bottom of the sidebar outside the scrolling list and the two halves have to highlight
/// identically. The selected fill is `SweepTokens.accent` — the app's indigo, one palette
/// everywhere — not the system accent.
public struct SidebarRow: View {
    private let title: String
    private let symbol: String
    private let tier: SidebarTier
    private let isSelected: Bool
    private let badge: String?
    private let action: () -> Void

    @State private var isHovering = false

    public init(
        title: String,
        symbol: String,
        tier: SidebarTier = .primary,
        isSelected: Bool,
        badge: String? = nil,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.symbol = symbol
        self.tier = tier
        self.isSelected = isSelected
        self.badge = badge
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            HStack(spacing: SweepTokens.s3) {
                icon
                Text(title)
                    .font(tier.font)
                    .foregroundStyle(titleStyle)
                    .lineLimit(1)
                Spacer(minLength: SweepTokens.s1)
                if let badge {
                    Text(badge)
                        .font(SweepFont.badge)
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? AnyShapeStyle(.white.opacity(0.85)) : AnyShapeStyle(.tertiary))
                }
            }
            .padding(.horizontal, SweepTokens.s2)
            .frame(height: tier.rowHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: SweepTokens.rowRadius, style: .continuous)
                    .fill(background)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(SidebarPressStyle())
        .padding(.horizontal, tier.indent)
        .onHover { isHovering = $0 }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// Every row gets the colored "System Settings" chip (scale v3 — the whole sidebar carries
    /// the module-hue identity now, Toolbox included). The tier contract survives in metrics,
    /// not icon treatment: Toolbox chips are 6 pt smaller on a shorter row in a lighter face.
    /// `ModuleIcon` itself falls back to a plain hierarchical glyph for symbols with no assigned
    /// hue, so an unrecognized row degrades to exactly the old look. Hover pops the chip a step
    /// forward — the "this is clickable" cue, on the icon rather than the whole row.
    private var icon: some View {
        ModuleIcon(symbol: symbol, diameter: tier.glyphWidth)
            .scaleEffect(isHovering && !isSelected ? 1.07 : 1)
            .animation(SweepMotion.row, value: isHovering)
    }

    private var background: AnyShapeStyle {
        // The app's own indigo, not `Color.accentColor`: system blue was the one surface still
        // speaking AppKit in a palette that says indigo everywhere else (Scale v3 SaaS pass).
        if isSelected { return AnyShapeStyle(SweepTokens.accent) }
        if isHovering { return AnyShapeStyle(.fill.quaternary) }
        return AnyShapeStyle(.clear)
    }

    private var titleStyle: AnyShapeStyle {
        if isSelected { return AnyShapeStyle(.white) }
        return AnyShapeStyle(tier == .primary ? HierarchicalShapeStyle.primary : HierarchicalShapeStyle.secondary)
    }

}

#Preview("Sidebar") {
    SidebarPreview()
        .frame(width: 216, height: 420)
}

private struct SidebarPreview: View {
    @State private var selected = "smart"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarRow(title: "Smart Scan", symbol: "sparkles", isSelected: selected == "smart") { selected = "smart" }
                .padding(.top, SweepTokens.s2)
            SidebarSectionHeader("Clean")
            SidebarRow(title: "System Junk", symbol: "trash", isSelected: selected == "junk") { selected = "junk" }
            SidebarRow(title: "Large & Old Files", symbol: "doc.zipper", isSelected: selected == "large") { selected = "large" }
            Spacer()
            Divider().padding(.horizontal, SweepTokens.s3)
            SidebarSectionHeader("Toolbox", tier: .toolbox)
            SidebarRow(title: "Developer", symbol: "hammer", tier: .toolbox, isSelected: selected == "dev") { selected = "dev" }
            SidebarRow(title: "Homebrew", symbol: "mug", tier: .toolbox, isSelected: selected == "brew") { selected = "brew" }
                .padding(.bottom, SweepTokens.s2)
        }
    }
}
