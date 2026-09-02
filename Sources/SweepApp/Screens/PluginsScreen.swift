import AppKit
import SweepUI
import SwiftUI

// MARK: - Screen model

/// Screen state for Plugins (Toolbox): read-mostly inventory across every plug-in surface macOS
/// exposes, with Reveal everywhere and Move-to-Trash for the five filesystem categories. App
/// extensions (category 6, `pluginkit`) are read-only end to end — see `PluginItem.isRemovable`.
@MainActor
@Observable
final class PluginsModel {
    private(set) var groups: [PluginCategoryGroup] = []
    private(set) var hasLoaded = false
    private(set) var isLoading = false

    /// The item a "Remove" tap is waiting on confirmation for. Non-nil is exactly what drives the
    /// confirmation dialog's `isPresented` binding.
    private(set) var pendingRemoval: PluginItem?
    /// Per-row, sticky failure text ("macOS refused: …") — the row stays in the list (nothing
    /// actually moved), so the honest explanation stays with it until the next refresh rather
    /// than fading like a success toast would.
    private(set) var rowNotice: [String: String] = [:]
    /// A brief, screen-level confirmation for a successful trash — the row itself is already
    /// gone by the time this shows, so it has nowhere else to live.
    private(set) var transientMessage: String?
    private var transientTask: Task<Void, Never>?

    func load() async {
        isLoading = true
        let home = ScanEnvironment.resolve().home
        let result = await Task.detached(priority: .utility) {
            PluginInventoryEngine.scan(home: home)
        }.value
        groups = result
        hasLoaded = true
        isLoading = false
    }

    func refresh() {
        guard !isLoading else { return }
        Task { await load() }
    }

    func requestRemoval(_ item: PluginItem) {
        guard item.isRemovable else { return }
        pendingRemoval = item
    }

    func cancelRemoval() {
        pendingRemoval = nil
    }

    /// Runs the trash off the main actor, then either drops the row (success) or leaves it in
    /// place with an honest inline reason (failure) — the ACTIONS contract for a refused
    /// `/Library` removal.
    func confirmRemoval() {
        guard let item = pendingRemoval else { return }
        pendingRemoval = nil
        rowNotice[item.id] = nil
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                PluginRemovalService.trash(item)
            }.value
            switch outcome {
            case .succeeded:
                removeItem(item)
                showTransient("Moved \u{201C}\(item.name)\u{201D} to the Trash.")
            case .failed(let reason):
                rowNotice[item.id] = "macOS refused: \(reason). Remove it from the owning app instead."
            }
        }
    }

    private func removeItem(_ item: PluginItem) {
        groups = groups.compactMap { group in
            guard group.category == item.category else { return group }
            let remaining = group.items.filter { $0.id != item.id }
            return remaining.isEmpty ? nil : PluginCategoryGroup(category: group.category, items: remaining)
        }
        rowNotice[item.id] = nil
    }

    private func showTransient(_ message: String) {
        transientMessage = message
        transientTask?.cancel()
        transientTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.transientMessage = nil
        }
    }
}

// MARK: - Screen

/// Plugins (Toolbox): inventory of Spotlight importers, Quick Look generators, preference panes,
/// audio plug-ins, legacy Internet plug-ins and `pluginkit` app extensions — what is installed,
/// who owns it, Reveal everywhere and Trash where that is actually this app's call to offer.
///
/// Not built on `InventoryList`/`GroupHeader`: those assume a selection/checkbox model (bulk
/// select-all, a Clean-flow total) this screen never has — every row here acts alone, some rows
/// have no action beyond Reveal, and the read-only app-extension category has no size or tier at
/// all. `SectionCard` + a plain header + custom rows is the honest fit, the same call
/// `StartupItemsScreen` makes for its own read-mostly rows.
struct PluginsScreen: View {
    @State private var model = PluginsModel()

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                title: "Plugins",
                subtitle: "Spotlight importers, Quick Look, audio units and app extensions \u{2014} and what installed them."
            ) {
                Button("Refresh") { model.refresh() }
                    .buttonStyle(.sweepQuiet)
                    .disabled(model.isLoading)
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .task { await model.load() }
        .confirmationDialog(
            confirmTitle,
            isPresented: Binding(
                get: { model.pendingRemoval != nil },
                set: { shown in if !shown { model.cancelRemoval() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { model.confirmRemoval() }
            Button("Cancel", role: .cancel) { model.cancelRemoval() }
        } message: {
            Text(confirmMessage)
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            InventoryEmptyState(symbol: "puzzlepiece.extension", title: "Reading plug-in folders\u{2026}")
        } else if model.groups.isEmpty {
            InventoryEmptyState(symbol: "checkmark.circle", title: "No third-party plug-ins found.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: SweepTokens.s5) {
                    ForEach(model.groups) { group in
                        section(for: group)
                    }
                }
                .padding(SweepTokens.s5)
            }
        }
    }

    @ViewBuilder
    private func section(for group: PluginCategoryGroup) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                header(for: group)
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                    PluginItemRow(
                        item: item,
                        notice: model.rowNotice[item.id],
                        onReveal: { reveal(item) },
                        onRemove: { model.requestRemoval(item) }
                    )
                    .padding(.horizontal, SweepTokens.s3 - 2)
                }
            }
            .padding(.bottom, SweepTokens.s2)
        }
    }

    /// Filesystem categories show the same title/count/tier/total furniture `GroupHeader` would;
    /// the app-extension category — no size, no deletion-safety tier to show — gets the plainer
    /// version, matching `StartupItemsScreen`'s own "This App (SMAppService)" section.
    @ViewBuilder
    private func header(for group: PluginCategoryGroup) -> some View {
        HStack(spacing: SweepTokens.s2) {
            Image(systemName: group.category.symbol)
                .font(.system(size: 13, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 17)
            Text(group.category.title)
                .font(SweepFont.sectionTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(SweepFormat.itemCount(group.items.count))
                .font(SweepFont.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: SweepTokens.s3)
            if group.category != .appExtension {
                TierBadge(group.tier, showsSafe: true)
                SizeColumn(byteCount: group.byteCount, font: SweepFont.monoEmphasis, emphasized: true)
            }
        }
        .padding(.horizontal, SweepTokens.s4)
        .padding(.top, SweepTokens.s4)
        .padding(.bottom, SweepTokens.s2)
    }

    // MARK: Footer

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: SweepTokens.s3) {
                Footnote(
                    "App extensions live inside their apps \u{2014} remove the app to remove them. Sweep never touches /System.",
                    symbol: "puzzlepiece.extension"
                )
                Spacer(minLength: SweepTokens.s3)
                if let message = model.transientMessage {
                    Text(message)
                        .font(SweepFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.vertical, SweepTokens.s3)
        }
        .background(.bar)
        .animation(SweepMotion.crossfade, value: model.transientMessage)
    }

    // MARK: Confirmation copy

    private var confirmTitle: String {
        guard let item = model.pendingRemoval else { return "Move to the Trash?" }
        return "Move \u{201C}\(item.name)\u{201D} to the Trash?"
    }

    private var confirmMessage: String {
        guard let item = model.pendingRemoval else { return "" }
        return "\(item.path) moves to the Trash. "
            + "Restore it by dragging it back from the Trash \u{2014} the app that installed it "
            + "may put it back if you reinstall, repair, or update that app."
    }

    // MARK: Actions

    /// Read-only, sandboxed-safe: hands the item off to Finder rather than touching it directly.
    private func reveal(_ item: PluginItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }
}

// MARK: - Row

/// One plug-in row: icon, name, detail line, owner, size/tier for removable rows, and a
/// hover-revealed action slot (Reveal always, Remove only when `item.isRemovable`) — the same
/// fixed-slot hover-fade `InventoryRow`'s own reveal button uses, so nothing shifts as the pointer
/// moves on and off a row.
private struct PluginItemRow: View {
    let item: PluginItem
    let notice: String?
    let onReveal: () -> Void
    let onRemove: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SweepTokens.s3 - 2) {
                Image(systemName: item.category.symbol)
                    .font(.system(size: 13.5, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 19, alignment: .center)

                VStack(alignment: .leading, spacing: 0) {
                    Text(item.name)
                        .font(SweepFont.rowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(item.detail)
                        .font(SweepFont.monoSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer(minLength: SweepTokens.s3)

                if let owner = item.owner {
                    Text(owner)
                        .font(SweepFont.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: 150, alignment: .trailing)
                }

                if item.isRemovable {
                    SizeColumn(byteCount: item.byteCount, font: SweepFont.mono, emphasized: false)
                    if let tier = item.tier {
                        TierBadge(tier)
                    }
                }

                actionSlot
            }
            .padding(.horizontal, SweepTokens.s3 - 2)
            .frame(height: SweepTokens.inventoryRowHeight)

            if let notice {
                Text(notice)
                    .font(SweepFont.caption)
                    .foregroundStyle(SweepTokens.tierCaution)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SweepTokens.s3 - 2)
                    .padding(.bottom, SweepTokens.s2)
            }
        }
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var actionSlot: some View {
        HStack(spacing: SweepTokens.s2) {
            Button(action: onReveal) {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(item.name) in Finder")

            if item.isRemovable {
                Button("Remove", action: onRemove)
                    .buttonStyle(.sweepQuiet)
                    .controlSize(.small)
                    .accessibilityHint("Moves \(item.name) to the Trash after you confirm.")
            }
        }
        .opacity(isHovering ? 1 : 0)
        .allowsHitTesting(isHovering)
    }

    private var accessibilityLabel: String {
        var parts = [item.name, item.detail]
        if let tier = item.tier { parts.append("\(tier.label) tier") }
        if let notice { parts.append(notice) }
        return parts.joined(separator: ", ")
    }
}
