import SwiftUI

/// Section header for an inventory list: disclosure, select-all, title, count, tier, total.
///
/// Sits on `.bar` material so it stays legible when pinned above scrolling rows. The total on
/// the right lands in the same fixed column as every row's size, so the group total reads as
/// the sum of the column underneath it rather than as a separate piece of furniture.
public struct GroupHeader: View {
    private let title: String
    private let itemCount: Int
    private let sizeValue: String
    private let sizeUnit: String
    private let tier: SweepTier
    private let symbol: String?
    private let selection: SelectionState?
    private let onToggleSelection: (() -> Void)?
    private let isExpanded: Binding<Bool>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(
        title: String,
        itemCount: Int,
        sizeValue: String,
        sizeUnit: String,
        tier: SweepTier,
        symbol: String? = nil,
        selection: SelectionState? = nil,
        onToggleSelection: (() -> Void)? = nil,
        isExpanded: Binding<Bool>? = nil
    ) {
        self.title = title
        self.itemCount = itemCount
        self.sizeValue = sizeValue
        self.sizeUnit = sizeUnit
        self.tier = tier
        self.symbol = symbol
        self.selection = selection
        self.onToggleSelection = onToggleSelection
        self.isExpanded = isExpanded
    }

    public init(
        group: InventoryGroup,
        selection: SelectionState? = nil,
        onToggleSelection: (() -> Void)? = nil,
        isExpanded: Binding<Bool>? = nil
    ) {
        self.init(
            title: group.title,
            itemCount: group.itemCount,
            sizeValue: group.sizeValue,
            sizeUnit: group.sizeUnit,
            tier: group.tier,
            symbol: group.symbol,
            selection: selection,
            onToggleSelection: onToggleSelection,
            isExpanded: isExpanded
        )
    }

    public var body: some View {
        HStack(spacing: SweepTokens.s2) {
            if let isExpanded {
                Button {
                    withAnimation(reduceMotion ? SweepMotion.crossfade : SweepMotion.row) {
                        isExpanded.wrappedValue.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded.wrappedValue ? 90 : 0))
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded.wrappedValue ? "Collapse \(title)" : "Expand \(title)")
            }

            if let selection, let onToggleSelection {
                SweepCheckbox(state: selection, label: "Select all in \(title)", action: onToggleSelection)
                    .padding(.trailing, 1)
            }

            if let symbol {
                // Module-hue tint (PLAN §5 volume-raise), not the full sidebar badge: a header
                // row is compact and already carries a chevron, checkbox, badge and size — a
                // tinted glyph reads as "this module's color" without adding another shape.
                Image(systemName: symbol)
                    .font(.system(size: 13, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(SweepModuleHue.color(forSymbol: symbol) ?? .secondary)
                    .frame(width: 17)
            }

            Text(title)
                .font(SweepFont.sectionTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)

            Text(SweepFormat.itemCount(itemCount))
                .font(SweepFont.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                // Layout contract: the count is an atom; the title truncates, the count never.
                .fixedSize()

            Spacer(minLength: SweepTokens.s3)

            TierBadge(tier, showsSafe: true)

            SizeColumn(value: sizeValue, unit: sizeUnit, font: SweepFont.monoEmphasis, emphasized: true)
        }
        .padding(.horizontal, SweepTokens.s4)
        .frame(height: 38)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityElement(children: .contain)
    }
}

#Preview("Group headers") {
    VStack(spacing: 0) {
        StatefulPreview(true) { expanded in
            GroupHeader(
                title: "User Application Caches",
                itemCount: 18204,
                sizeValue: "9.81", sizeUnit: "GB",
                tier: .safe,
                symbol: "shippingbox",
                selection: .all,
                onToggleSelection: {},
                isExpanded: expanded
            )
        }
        StatefulPreview(false) { expanded in
            GroupHeader(
                title: "Xcode Device Support",
                itemCount: 41,
                sizeValue: "24.6", sizeUnit: "GB",
                tier: .caution,
                symbol: "hammer",
                selection: .partial,
                onToggleSelection: {},
                isExpanded: expanded
            )
        }
        GroupHeader(
            title: "Crash Reports", itemCount: 1,
            sizeValue: "812", sizeUnit: "B",
            tier: .safe, symbol: "exclamationmark.triangle"
        )
    }
    .frame(width: 620)
}
