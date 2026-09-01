import SwiftUI
import SweepUI

/// Two-tier sidebar (PLAN §3).
///
/// The primary groups scroll; the Toolbox block is pinned to the bottom in a bottom safe-area
/// inset, separated by a rule, drawn a size down and a shade back. The split is structural, not
/// cosmetic: primary modules may auto-select safe items and feed Smart Scan, Toolbox modules
/// never do, and the sidebar is where the user first learns that.
struct SidebarView: View {
    @Binding var selection: Destination
    let showsStressHarness: Bool

    var body: some View {
        // No `ScrollView`: at the 600 pt minimum window height the whole IA fits with room to
        // spare, and a `Spacer` is what actually pins Toolbox to the bottom. If the Toolbox
        // grows past the fold (Packages, Plugins, Lipo, File Search are queued for v1.1) the
        // primary block gets a scroll view and Toolbox stays a bottom inset.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(SidebarGroup.primary) { group in
                if let title = group.title {
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
            SidebarSectionHeader(group.title ?? "Toolbox", tier: .toolbox)
            ForEach(group.destinations) { destination in
                row(destination)
            }
            Color.clear.frame(height: SweepTokens.s2)
        }
    }

    private func row(_ destination: Destination) -> some View {
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
