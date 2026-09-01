import SwiftUI
import SweepUI

/// Destination that exists in the IA but not yet in code.
///
/// Says which phase it lands in rather than pretending to be under construction: the sidebar is
/// the plan's information architecture, and an entry the user can select should tell them
/// something true when they do.
struct ModulePlaceholderScreen: View {
    let destination: Destination
    let arrival: String

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: destination.title, subtitle: destination.subtitle)
            Divider()
            VStack(spacing: SweepTokens.s3) {
                Image(systemName: destination.symbol)
                    .font(.system(size: 28, weight: .light))
                    .foregroundStyle(.quaternary)
                Text(arrival)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.secondary)
                if destination.tier == .toolbox {
                    Footnote("Toolbox modules never auto-select and never feed Smart Scan.", symbol: "hand.raised")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// Debug harness, reachable only when `SWEEP_UI_STRESS` is set.
///
/// Ten thousand rows through the shipping `InventoryList`, with the same row component, the
/// same pinned headers and the same selection model the real screens use. It exists so the
/// virtualisation claim can be checked by scrolling it rather than asserted in a comment.
struct ListStressScreen: View {
    let rowCount: Int

    @State private var selection = InventorySelection()
    @State private var expansion = InventoryExpansion()
    @State private var query = ""
    @State private var groups: [InventoryGroup] = []

    static func makeGroups(rowCount: Int) -> [InventoryGroup] {
        let sections = max(1, min(10, rowCount / 100))
        let perSection = max(1, rowCount / sections)
        return (0..<sections).map { section in
            InventoryGroup(
                id: "stress-\(section)",
                title: "Synthetic group \(section + 1)",
                symbol: "shippingbox",
                items: (0..<perSection).map { index in
                    let ordinal = section * perSection + index
                    return InventoryItem(
                        id: "stress-\(ordinal)",
                        title: "com.example.package.\(String(format: "%05d", ordinal))",
                        detail: "~/Library/Caches/com.example.package.\(ordinal)/Cache_Data/f_\(String(format: "%06x", ordinal))",
                        symbol: "shippingbox",
                        byteCount: Int64((ordinal + 1) * 104_729),
                        tier: ordinal % 97 == 0 ? .caution : .safe
                    )
                }
            )
        }
    }

    private var visible: [InventoryGroup] {
        InventoryAggregate.filter(groups, query: query)
    }

    /// What's actually on screen right now, summed across every group's bounded page. Printed in
    /// the footnote as the screenshot evidence for PLAN §6b: this number stays flat whether
    /// `rowCount` is 100 or 10,000.
    private var renderedRowCount: Int {
        visible.reduce(0) { $0 + expansion.visibleCount(for: $1) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                title: Destination.listStress.title,
                subtitle: Destination.listStress.subtitle
            ) {
                SweepSearchField(text: $query, prompt: "Filter paths").frame(width: 200)
            }
            Divider()
            InventoryList(groups: visible, selection: $selection, expansion: $expansion)

            VStack(spacing: 0) {
                Divider()
                HStack {
                    Footnote(
                        "\(SweepFormat.count(InventoryAggregate.totalItems(groups))) rows total, "
                            + "\(SweepFormat.count(renderedRowCount)) rendered across \(SweepFormat.count(groups.count)) sections "
                            + "(budget \(InventoryBudget.maxVisibleRows)) — PLAN §6b.",
                        symbol: "speedometer"
                    )
                    Spacer()
                    Text(SweepFormat.bytes(selection.selectedBytes(in: groups)))
                        .font(SweepFont.mono)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, SweepTokens.s5)
                .padding(.vertical, SweepTokens.s3)
            }
            .background(.bar)
        }
        .onAppear {
            guard groups.isEmpty else { return }
            groups = Self.makeGroups(rowCount: rowCount)
            selection = .safeDefaults(in: groups)
            expansion = .initial(for: groups)
        }
    }
}
