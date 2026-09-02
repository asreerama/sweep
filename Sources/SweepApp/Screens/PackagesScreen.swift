import AppKit
import SweepUI
import SwiftUI

// MARK: - Screen model

/// Screen state for Packages (Toolbox): the `pkgutil --pkgs` id list loaded once at open, with
/// each receipt's metadata/file-list detail fetched lazily — one receipt at a time, only when its
/// row is expanded — and cached for the rest of the session. See `PackageReceipts.swift`'s
/// top-level doc comment for the measured reason this never fans detail requests out concurrently.
@MainActor
@Observable
final class PackagesModel {
    private(set) var vendorGroups: [PackageVendorGroup] = []
    private(set) var appleHiddenCount = 0
    private(set) var hasLoaded = false
    private(set) var isLoading = false

    private(set) var expandedIDs: Set<String> = []
    private(set) var filesFullyShownIDs: Set<String> = []
    private(set) var loadingDetailIDs: Set<String> = []
    private var detailCache: [String: PackageReceiptDetail] = [:]

    func load() async {
        isLoading = true
        let ids = await Task.detached(priority: .utility) {
            PackageIDsLoader.load()
        }.value
        let (kept, appleCount) = ApplePackageFilter.excludingApple(ids)
        vendorGroups = PackageVendorGrouping.buildGroups(from: kept)
        appleHiddenCount = appleCount
        hasLoaded = true
        isLoading = false
    }

    /// Re-runs the id spawn and drops every cached detail — a receipt could have been forgotten,
    /// reinstalled at a new version, or newly recorded since the screen opened, and stale detail
    /// under a since-changed id would be a silent lie rather than an honest re-read.
    func refresh() {
        guard !isLoading else { return }
        detailCache.removeAll()
        expandedIDs.removeAll()
        filesFullyShownIDs.removeAll()
        loadingDetailIDs.removeAll()
        Task { await load() }
    }

    func isExpanded(_ id: String) -> Bool { expandedIDs.contains(id) }
    func isLoadingDetail(_ id: String) -> Bool { loadingDetailIDs.contains(id) }
    func detail(for id: String) -> PackageReceiptDetail? { detailCache[id] }
    func filesFullyShown(_ id: String) -> Bool { filesFullyShownIDs.contains(id) }

    func toggleExpanded(_ id: String) {
        if expandedIDs.contains(id) {
            expandedIDs.remove(id)
        } else {
            expandedIDs.insert(id)
            loadDetailIfNeeded(id)
        }
    }

    func showAllFiles(_ id: String) {
        filesFullyShownIDs.insert(id)
    }

    private func loadDetailIfNeeded(_ id: String) {
        guard detailCache[id] == nil, !loadingDetailIDs.contains(id) else { return }
        loadingDetailIDs.insert(id)
        Task {
            let detail = await Task.detached(priority: .utility) {
                PackageReceiptDetailLoader.load(packageID: id)
            }.value
            detailCache[id] = detail
            loadingDetailIDs.remove(id)
        }
    }
}

// MARK: - Screen

/// Packages (Toolbox, PLAN.md v1.1 backlog item, promoted): a `pkgutil` receipts browser — every
/// installed package receipt, what files it claims, reveal-in-Finder. STRICTLY READ-ONLY this
/// wave: no forget, no uninstall-by-receipt, no file deletion. Those are gated destructive
/// features that ship later, stated plainly in the footnote below.
///
/// Not built on `InventoryList`: that template's rows carry a byte size and a deletion-safety
/// tier, neither of which a read-only receipt has an opinion about (a receipt's own footprint is
/// the files it claims, already double-counted by whatever installed them). `SectionCard` + a
/// plain vendor header + custom disclosure rows is the same honest fit `StartupItemsScreen` and
/// `PluginsScreen` make for their own read-mostly inventories.
struct PackagesScreen: View {
    @State private var model = PackagesModel()
    @State private var query = ""

    private var filteredGroups: [PackageVendorGroup] {
        let folded = SearchFold.fold(query.trimmingCharacters(in: .whitespaces))
        guard !folded.isEmpty else { return model.vendorGroups }
        return model.vendorGroups.compactMap { $0.filtered(byFoldedQuery: folded) }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                title: "Packages",
                subtitle: "Installer receipts recorded by macOS \u{2014} what got installed, when, and where."
            ) {
                HStack(spacing: SweepTokens.s2) {
                    if !model.vendorGroups.isEmpty {
                        SweepSearchField(text: $query, prompt: "Search package ID")
                            .frame(width: 240)
                    }
                    Button("Refresh") { model.refresh() }
                        .buttonStyle(.sweepQuiet)
                        .disabled(model.isLoading)
                }
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.hasLoaded {
                footer
            }
        }
        .task { await model.load() }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            InventoryEmptyState(symbol: "shippingbox", title: "Reading installer receipts\u{2026}")
        } else if model.vendorGroups.isEmpty {
            InventoryEmptyState(symbol: "checkmark.circle", title: "No third-party installer receipts found.")
        } else if filteredGroups.isEmpty {
            InventoryEmptyState(symbol: "magnifyingglass", title: "No receipts match \u{201C}\(query)\u{201D}.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: SweepTokens.s5) {
                    ForEach(filteredGroups) { group in
                        section(for: group)
                    }
                }
                .padding(SweepTokens.s5)
            }
        }
    }

    @ViewBuilder
    private func section(for group: PackageVendorGroup) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                header(for: group)
                ForEach(Array(group.receipts.enumerated()), id: \.element.id) { index, receipt in
                    if index > 0 { Divider().padding(.horizontal, SweepTokens.s3) }
                    PackageReceiptRow(
                        packageID: receipt.id,
                        isExpanded: model.isExpanded(receipt.id),
                        detail: model.detail(for: receipt.id),
                        isLoadingDetail: model.isLoadingDetail(receipt.id),
                        filesFullyShown: model.filesFullyShown(receipt.id),
                        onToggleExpanded: {
                            withAnimation(SweepMotion.row) { model.toggleExpanded(receipt.id) }
                        },
                        onReveal: reveal,
                        onShowAllFiles: { model.showAllFiles(receipt.id) }
                    )
                    .padding(.horizontal, SweepTokens.s3 - 2)
                }
            }
            .padding(.bottom, SweepTokens.s2)
        }
    }

    private func header(for group: PackageVendorGroup) -> some View {
        HStack(spacing: SweepTokens.s2) {
            Image(systemName: "shippingbox")
                .font(.system(size: 13, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 17)
            Text(group.vendorName)
                .font(SweepFont.sectionTitle)
                .foregroundStyle(.primary)
                .lineLimit(1)
            Text(SweepFormat.itemCount(group.receipts.count))
                .font(SweepFont.caption)
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: SweepTokens.s3)
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
                    "Read-only. Forgetting or uninstalling by receipt is destructive and arrives behind its own gate.",
                    symbol: "lock"
                )
                Spacer(minLength: SweepTokens.s3)
                if model.appleHiddenCount > 0 {
                    Text("\(SweepFormat.count(model.appleHiddenCount)) Apple receipts hidden")
                        .font(SweepFont.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.vertical, SweepTokens.s3)
        }
        .background(.bar)
    }

    // MARK: Actions

    /// Read-only, matching every other reveal action in this app: hands the item off to Finder
    /// rather than touching it directly.
    private func reveal(_ absolutePath: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: absolutePath)])
    }
}

// MARK: - Row

/// Shared across every row so `RelativeDateTimeFormatter`'s (non-trivial) construction happens
/// once, not once per row per render. `@MainActor`-isolated (never `Sendable`): every reader is a
/// row's `body`, which already runs on the main actor.
@MainActor
private let packageInstallDateFormatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter
}()

/// One receipt row: id, a disclosure chevron, and — once expanded — its lazily-loaded detail
/// (install location, version, claimed files with reveal-in-Finder and a bounded "Show all").
/// Mirrors `StartupItemsScreen`/`PluginsScreen`'s custom-row convention rather than `InventoryRow`,
/// which has no slot for an inline expanding detail section.
private struct PackageReceiptRow: View {
    let packageID: String
    let isExpanded: Bool
    let detail: PackageReceiptDetail?
    let isLoadingDetail: Bool
    let filesFullyShown: Bool
    let onToggleExpanded: () -> Void
    let onReveal: (String) -> Void
    let onShowAllFiles: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            disclosureRow
            if isExpanded {
                detailSection
            }
        }
    }

    private var disclosureRow: some View {
        Button(action: onToggleExpanded) {
            HStack(spacing: SweepTokens.s3 - 2) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 14, height: 14)
                VStack(alignment: .leading, spacing: 0) {
                    Text(packageID)
                        .font(SweepFont.rowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(captionText)
                        .font(SweepFont.caption)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: SweepTokens.s3)
                if isLoadingDetail {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, SweepTokens.s3 - 2)
            .frame(height: SweepTokens.inventoryRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(packageID), \(captionText)")
        .accessibilityHint(isExpanded ? "Collapses receipt detail" : "Expands receipt detail")
    }

    private var captionText: String {
        guard let info = detail?.info else {
            return isLoadingDetail ? "Loading\u{2026}" : "Tap to load details"
        }
        var parts: [String] = []
        if let version = info.version { parts.append("v\(version)") }
        if let installDate = info.installDate {
            parts.append(packageInstallDateFormatter.localizedString(for: installDate, relativeTo: Date()))
        }
        return parts.isEmpty ? "No version or install date recorded" : parts.joined(separator: " \u{00B7} ")
    }

    @ViewBuilder
    private var detailSection: some View {
        if let detail {
            VStack(alignment: .leading, spacing: SweepTokens.s2) {
                if let info = detail.info {
                    Text(PackageFilePathJoiner.absolutePath(volume: info.volume, installLocation: info.installLocation, relativePath: ""))
                        .font(SweepFont.monoSmall)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(fileCountLine)
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)

                ForEach(visibleFiles) { file in
                    fileRow(file)
                }

                if remainderCount > 0 {
                    Text("and \(SweepFormat.count(remainderCount)) more")
                        .font(SweepFont.caption)
                        .foregroundStyle(.tertiary)
                }

                if !filesFullyShown, detail.files.count > PackageFileListDisplay.previewCount {
                    Button("Show all") { onShowAllFiles() }
                        .buttonStyle(.sweepQuiet)
                        .controlSize(.small)
                }
            }
            .padding(.leading, SweepTokens.rowDisclosureIndent)
            .padding(.trailing, SweepTokens.s3 - 2)
            .padding(.bottom, SweepTokens.s3)
        } else if isLoadingDetail {
            HStack {
                ProgressView().controlSize(.small)
                Text("Loading receipt detail\u{2026}")
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(.leading, SweepTokens.rowDisclosureIndent)
            .padding(.bottom, SweepTokens.s3)
        }
    }

    private var fileCountLine: String {
        detail.map { "\(SweepFormat.itemCount($0.files.count)) claimed" } ?? "0 items claimed"
    }

    private var visibleFiles: [PackageFileEntry] {
        PackageFileListDisplay.visibleFiles(detail?.files ?? [], expanded: filesFullyShown)
    }

    private var remainderCount: Int {
        PackageFileListDisplay.remainderCount(detail?.files ?? [], expanded: filesFullyShown)
    }

    private func fileRow(_ file: PackageFileEntry) -> some View {
        HStack(spacing: SweepTokens.s2) {
            Text(file.relativePath)
                .font(SweepFont.monoSmall)
                .foregroundStyle(file.exists ? .secondary : .tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !file.exists {
                Text("no longer on disk")
                    .font(SweepFont.caption)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .fixedSize()
            }
            Spacer(minLength: SweepTokens.s2)
            Button {
                onReveal(file.absolutePath)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .disabled(!file.exists)
            .help(file.exists ? "Reveal in Finder" : "No longer on disk")
            .accessibilityLabel(file.exists ? "Reveal \(file.relativePath) in Finder" : "\(file.relativePath), no longer on disk")
        }
        .frame(minHeight: 20)
    }
}
