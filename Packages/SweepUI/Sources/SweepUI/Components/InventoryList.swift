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
                                InventoryRow(
                                    item: item,
                                    selection: binding(for: item),
                                    indented: true,
                                    // Item ids are absolute paths for every scan/inventory source;
                                    // anything else (a synthetic id) simply gets no reveal button.
                                    revealURL: item.id.hasPrefix("/") ? URL(fileURLWithPath: item.id) : nil
                                )
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
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 19, alignment: .center)
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

/// Shown in place of the list when a scan found nothing, a filter matched nothing, or work is
/// still running. Pass `isBusy: true` for the last case: a title ending in an ellipsis with no
/// moving affordance under it is indistinguishable from a wedged screen.
public struct InventoryEmptyState: View {
    private let symbol: String
    private let title: String
    private let message: String?
    private let isBusy: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(symbol: String, title: String, message: String? = nil, isBusy: Bool = false) {
        self.symbol = symbol
        self.title = title
        self.message = message
        self.isBusy = isBusy
    }

    public var body: some View {
        VStack(spacing: SweepTokens.s3) {
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(isBusy ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.quaternary))
                .symbolEffect(.pulse, options: .repeating, isActive: isBusy && !reduceMotion)
            Text(title)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            if isBusy {
                IndeterminateSweepBar()
                    .padding(.top, 2)
            }
            if let message {
                Text(message)
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isBusy ? .updatesFrequently : [])
    }
}

/// The "still working" affordance under a busy empty state: a highlight travelling the width of a
/// hairline track. Deliberately indeterminate — the scans behind these states have no countable
/// total, and a determinate bar filling toward an invented 100% would be a lie.
private struct IndeterminateSweepBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var advanced = false

    private let trackWidth: CGFloat = 128
    private let thickness: CGFloat = 3
    private var highlightWidth: CGFloat { reduceMotion ? trackWidth : trackWidth * 0.36 }

    var body: some View {
        Capsule()
            .fill(.quaternary)
            .frame(width: trackWidth, height: thickness)
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(.tertiary)
                    // Reduce Motion keeps the signal but drops the travel: the full-width bar
                    // breathes in place instead of sliding.
                    .frame(width: highlightWidth, height: thickness)
                    .offset(x: reduceMotion ? 0 : (advanced ? trackWidth - highlightWidth : 0))
                    .opacity(reduceMotion ? (advanced ? 0.85 : 0.2) : 1)
            }
            .clipShape(Capsule())
            .animation(cycle, value: advanced)
            .onAppear { advanced = true }
            .onDisappear { advanced = false }
            .accessibilityHidden(true)
    }

    private var cycle: Animation {
        let base: Animation = reduceMotion
            ? .easeInOut(duration: 1.1)
            : .easeInOut(duration: SweepMotion.sweepPeriod * 0.75)
        return base.repeatForever(autoreverses: true)
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
