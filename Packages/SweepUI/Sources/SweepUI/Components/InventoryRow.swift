import SwiftUI

/// One row of an inventory: icon, title, optional path, size, tier, optional checkbox.
///
/// Two densities. `.standard` is the 34 pt list row that appears ten thousand times;
/// `.summary` is the taller row Smart Scan uses for its per-group totals. Both put the size in
/// the same fixed-width `SizeColumn`, so numbers line up down the page and across groups
/// without a `Table`, and both indent past the group header's disclosure chevron so a row's
/// checkbox sits directly under the header's.
public struct InventoryRow: View {

    public enum Emphasis: Sendable {
        case standard
        case summary
    }

    private let symbol: String
    private let title: String
    private let detail: String?
    private let detailIsPath: Bool
    private let sizeValue: String
    private let sizeUnit: String
    private let tier: SweepTier
    private let emphasis: Emphasis
    private let selection: Binding<Bool>?
    private let indented: Bool

    @State private var isHovering = false

    public init(
        symbol: String,
        title: String,
        detail: String? = nil,
        detailIsPath: Bool = true,
        sizeValue: String,
        sizeUnit: String,
        tier: SweepTier,
        emphasis: Emphasis = .standard,
        selection: Binding<Bool>? = nil,
        indented: Bool = false
    ) {
        self.symbol = symbol
        self.title = title
        self.detail = detail
        self.detailIsPath = detailIsPath
        self.sizeValue = sizeValue
        self.sizeUnit = sizeUnit
        self.tier = tier
        self.emphasis = emphasis
        self.selection = selection
        self.indented = indented
    }

    public init(
        item: InventoryItem,
        emphasis: Emphasis = .standard,
        selection: Binding<Bool>? = nil,
        indented: Bool = false
    ) {
        self.init(
            symbol: item.symbol,
            title: item.title,
            detail: item.detail,
            sizeValue: item.sizeValue,
            sizeUnit: item.sizeUnit,
            tier: item.tier,
            emphasis: emphasis,
            selection: selection,
            indented: indented
        )
    }

    public var body: some View {
        HStack(spacing: SweepTokens.s3 - 2) {
            if indented {
                Color.clear.frame(width: SweepTokens.rowDisclosureIndent - SweepTokens.s3 + 2, height: 1)
            }

            if let selection {
                SweepCheckbox(isOn: selection.wrappedValue, label: "Select \(title)") {
                    selection.wrappedValue.toggle()
                }
            }

            Image(systemName: symbol)
                .font(.system(size: emphasis == .summary ? 14 : 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 17, alignment: .center)

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(emphasis == .summary ? SweepFont.rowTitleEmphasis : SweepFont.rowTitle)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let detail {
                    Text(detail)
                        .font(detailIsPath ? SweepFont.monoSmall : SweepFont.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(detailIsPath ? .middle : .tail)
                }
            }

            Spacer(minLength: SweepTokens.s3)

            TierBadge(tier, showsSafe: emphasis == .summary)

            SizeColumn(
                value: sizeValue,
                unit: sizeUnit,
                font: emphasis == .summary ? SweepFont.monoEmphasis : SweepFont.mono,
                emphasized: emphasis == .summary
            )
        }
        // 10 inside the hover pill + 6 outside = the 16 pt gutter GroupHeader uses, so the
        // size column lines up with the group total above it.
        .padding(.horizontal, SweepTokens.s3 - 2)
        .frame(height: emphasis == .summary ? SweepTokens.summaryRowHeight : SweepTokens.inventoryRowHeight)
        .background {
            RoundedRectangle(cornerRadius: SweepTokens.rowRadius, style: .continuous)
                .fill(isHovering ? AnyShapeStyle(.fill.quaternary) : AnyShapeStyle(.clear))
        }
        .padding(.horizontal, SweepTokens.s1 + 2)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(title), \(sizeValue) \(sizeUnit), \(tier.label) tier")
    }
}

#Preview("Inventory rows") {
    VStack(spacing: 0) {
        InventoryRow(
            symbol: "trash",
            title: "System Junk",
            detail: "18,204 items",
            detailIsPath: false,
            sizeValue: "9.81", sizeUnit: "GB",
            tier: .safe,
            emphasis: .summary
        )
        Divider()
        InventoryRow(
            symbol: "hammer",
            title: "Developer",
            detail: "2,133 items",
            detailIsPath: false,
            sizeValue: "194", sizeUnit: "MB",
            tier: .caution,
            emphasis: .summary
        )
        Divider().padding(.vertical, SweepTokens.s3)
        StatefulPreview(true) { on in
            InventoryRow(
                symbol: "shippingbox",
                title: "com.google.Chrome",
                detail: "~/Library/Caches/Google/Chrome/Default/Cache/Cache_Data",
                sizeValue: "482", sizeUnit: "MB",
                tier: .safe,
                selection: on,
                indented: true
            )
        }
        StatefulPreview(false) { on in
            InventoryRow(
                symbol: "iphone",
                title: "iOS DeviceSupport",
                detail: "~/Library/Developer/Xcode/iOS DeviceSupport/18.4 (22E240)",
                sizeValue: "6.12", sizeUnit: "GB",
                tier: .caution,
                selection: on,
                indented: true
            )
        }
    }
    .frame(width: 620)
    .padding(.vertical, SweepTokens.s4)
}

/// Preview-only holder so a `Binding` can be demonstrated without a host view.
struct StatefulPreview<Content: View>: View {
    @State private var value: Bool
    private let content: (Binding<Bool>) -> Content

    init(_ initial: Bool, @ViewBuilder content: @escaping (Binding<Bool>) -> Content) {
        self._value = State(initialValue: initial)
        self.content = content
    }

    var body: some View { content($value) }
}
