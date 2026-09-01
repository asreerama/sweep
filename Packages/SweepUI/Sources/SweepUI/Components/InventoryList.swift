import SwiftUI

/// The inventory-view template (PLAN §3, design contract): one skeleton, N data sources.
/// Uninstaller, Developer, Homebrew, Startup Items and Orphans all render through this.
///
/// Virtualised with `LazyVStack` + pinned section headers over stable string ids. Rows carry
/// pre-formatted sizes and no per-row formatter, no per-row date math and no per-row closure
/// allocation beyond one `Binding`, which is what keeps a ten-thousand-row tree scrolling at
/// display rate instead of at whatever `ByteCountFormatter` can manage.
public struct InventoryList: View {
    private let groups: [InventoryGroup]
    private let selection: Binding<InventorySelection>?
    @Binding private var collapsed: Set<String>

    public init(
        groups: [InventoryGroup],
        selection: Binding<InventorySelection>? = nil,
        collapsed: Binding<Set<String>>
    ) {
        self.groups = groups
        self.selection = selection
        self._collapsed = collapsed
    }

    public var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        if !collapsed.contains(group.id) {
                            ForEach(group.items) { item in
                                InventoryRow(item: item, selection: binding(for: item), indented: true)
                            }
                            .padding(.bottom, 1)
                        }
                    } header: {
                        header(for: group)
                    }
                }
                Color.clear.frame(height: SweepTokens.s4)
            }
        }
        .scrollContentBackground(.hidden)
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
                get: { !collapsed.contains(group.id) },
                set: { expanded in
                    if expanded { collapsed.remove(group.id) } else { collapsed.insert(group.id) }
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
    @State private var collapsed: Set<String> = []

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
        InventoryList(groups: groups, selection: $selection, collapsed: $collapsed)
            .onAppear { selection = .safeDefaults(in: groups) }
    }
}
