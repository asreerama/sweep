import SwiftUI

/// The inventory-view template (PLAN §3, design contract): one skeleton, N data sources.
/// Uninstaller, Developer, Homebrew, Startup Items and Orphans all render through this.
///
/// Virtualised with `LazyVStack` + pinned section headers over stable string ids. Rows carry
/// pre-formatted sizes and no per-row formatter, no per-row date math and no per-row closure
/// allocation beyond one `Binding`, which is what keeps a ten-thousand-row tree scrolling at
/// display rate instead of at whatever `ByteCountFormatter` can manage.
///
/// Rows within a group are bounded by ``InventoryExpansion`` (PLAN §6b): a group renders at most
/// `InventoryBudget.initialRowsPerGroup` rows until "Show all" pages in more, and the total across
/// every expanded group is capped well under the point count that corrupts a macOS 26 titlebar.
/// A scan producing 10,000 rows and a scan producing 10 render the same handful of DOM nodes at
/// rest — the bound is structural, not a courtesy the caller has to remember.
public struct InventoryList: View {
    private let groups: [InventoryGroup]
    private let selection: Binding<InventorySelection>?
    @Binding private var expansion: InventoryExpansion

    public init(
        groups: [InventoryGroup],
        selection: Binding<InventorySelection>? = nil,
        expansion: Binding<InventoryExpansion>
    ) {
        self.groups = groups
        self.selection = selection
        self._expansion = expansion
    }

    public var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        if !expansion.isCollapsed(group) {
                            ForEach(group.items.prefix(expansion.visibleCount(for: group))) { item in
                                InventoryRow(item: item, selection: binding(for: item), indented: true)
                            }
                            .padding(.bottom, 1)
                            if expansion.hasMore(group) {
                                InventoryShowMoreRow(
                                    shown: expansion.visibleCount(for: group),
                                    total: group.itemCount
                                ) {
                                    withAnimation(SweepMotion.row) {
                                        expansion.showMore(group, in: groups)
                                    }
                                }
                            }
                        }
                    } header: {
                        header(for: group)
                    }
                }
                Color.clear.frame(height: SweepTokens.s4)
            }
        }
        .scrollContentBackground(.hidden)
        .background(SweepTokens.ground)
    }

    private func header(for group: InventoryGroup) -> some View {
        GroupHeader(
            group: group,
            selection: selection.map { $0.wrappedValue.state(of: group) },
            onToggleSelection: selection.map { binding in
                {
                    let selectAll = binding.wrappedValue.state(of: group) != .all
                    binding.wrappedValue.setAll(group, selected: selectAll)
                }
            },
            isExpanded: Binding(
                get: { !expansion.isCollapsed(group) },
                set: { shouldExpand in
                    guard shouldExpand != !expansion.isCollapsed(group) else { return }
                    expansion.toggleCollapsed(group, in: groups)
                }
            )
        )
    }

    private func binding(for item: InventoryItem) -> Binding<Bool>? {
        guard let selection else { return nil }
        return Binding(
            get: { selection.wrappedValue.contains(item.id) },
            set: { selection.wrappedValue.set(item.id, selected: $0) }
        )
    }
}

/// The bounded-group paging control: "Show all N", `InventoryBudget.pageSize` rows at a time.
///
/// Never jumps straight to the full count — a tap always requests one more page, so a group of
/// 50,000 rows takes 250 taps to fully page in rather than one tap that reintroduces the
/// unbounded-height bug it exists to prevent.
struct InventoryShowMoreRow: View {
    let shown: Int
    let total: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SweepTokens.s2) {
                Color.clear.frame(width: SweepTokens.rowDisclosureIndent, height: 1)
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, alignment: .center)
                Text("Show all \(SweepFormat.count(total))")
                    .font(SweepFont.rowTitle)
                    .foregroundStyle(Color.accentColor)
                Text("\(SweepFormat.count(shown)) of \(SweepFormat.count(total)) shown")
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, SweepTokens.s3 - 2)
            .frame(height: SweepTokens.inventoryRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, SweepTokens.s1 + 2)
        .accessibilityLabel("Show all \(total) items, \(shown) currently shown")
    }
}

/// Shown in place of the list when a scan found nothing, or a filter matched nothing.
public struct InventoryEmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String?

    public init(symbol: String, title: String, message: String? = nil) {
        self.symbol = symbol
        self.title = title
        self.message = message
    }

    public var body: some View {
        VStack(spacing: SweepTokens.s3) {
            Image(systemName: symbol)
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.quaternary)
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            if let message {
                Text(message)
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview("Inventory list") {
    InventoryListPreview()
        .frame(width: 700, height: 480)
}

private struct InventoryListPreview: View {
    @State private var selection = InventorySelection()
    @State private var expansion = InventoryExpansion()

    private let groups: [InventoryGroup] = [
        InventoryGroup(id: "caches", title: "User Application Caches", symbol: "internaldrive", items: (0..<40).map {
            InventoryItem(
                id: "c\($0)",
                title: "com.example.app\($0)",
                detail: "~/Library/Caches/com.example.app\($0)/Cache_Data",
                symbol: "shippingbox",
                byteCount: Int64(($0 + 1) * 7_310_912),
                tier: .safe
            )
        }),
        InventoryGroup(id: "xcode", title: "Xcode Device Support", symbol: "hammer", items: (0..<6).map {
            InventoryItem(
                id: "x\($0)",
                title: "18.\($0) (22E24\($0))",
                detail: "~/Library/Developer/Xcode/iOS DeviceSupport/18.\($0)",
                symbol: "iphone",
                byteCount: Int64(($0 + 1) * 3_120_000_000),
                tier: .caution
            )
        }),
    ]

    var body: some View {
        InventoryList(groups: groups, selection: $selection, expansion: $expansion)
            .onAppear {
                selection = .safeDefaults(in: groups)
                expansion = .initial(for: groups)
            }
    }
}
