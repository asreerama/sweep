import AppKit
import SweepUI
import SweepUninstall
import SwiftUI

/// Uninstaller (module 5, PLAN §3): AppCleaner parity.
///
/// App inventory (icons, sizes, last-used, search + sort) on the left; selecting a row runs
/// `SweepUninstall.LeftoverMatcher` (read-only) and shows the leftover panel on the right, grouped
/// by evidence tier. "Preview Removal" opens a sheet that always ends at the Gate U notice — this
/// wave finds and displays leftovers, it deletes nothing.
struct UninstallerScreen: View {
    @Bindable var model: UninstallModel

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(title: Destination.uninstaller.title, subtitle: Destination.uninstaller.subtitle) {
                header
            }
            Divider()
            HStack(spacing: 0) {
                appList
                    .frame(minWidth: 300, idealWidth: 380, maxWidth: 460)
                Divider()
                // Layout contract: the detail panel owns a real floor. Without one, a narrow
                // window starved it to ~300 pt and every leftover row crushed into vertical
                // letter soup (user-reported); the window's own minWidth covers
                // sidebar + list floor + this floor.
                detailPanel
                    .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .onAppear { model.loadApps() }
        .sheet(isPresented: $model.previewSheetShown) {
            RemovalPreviewSheet(model: model)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: SweepTokens.s2) {
            if !model.apps.isEmpty {
                SweepSearchField(text: $model.searchQuery, prompt: "Search apps").frame(width: 240)
            }
            Picker("Sort", selection: $model.sortField) {
                ForEach(AppSortField.allCases) { field in Text(field.label).tag(field) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 108)
            Button {
                model.sortAscending.toggle()
            } label: {
                Image(systemName: model.sortAscending ? "arrow.up" : "arrow.down")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .buttonStyle(.sweepQuiet)
            .accessibilityLabel(model.sortAscending ? "Ascending" : "Descending")
        }
    }

    // MARK: - App list

    @ViewBuilder
    private var appList: some View {
        if model.isLoadingApps {
            InventoryEmptyState(symbol: "xmark.bin", title: "Reading installed apps\u{2026}")
        } else if model.visibleApps.isEmpty {
            InventoryEmptyState(
                symbol: model.searchQuery.isEmpty ? "xmark.bin" : "magnifyingglass",
                title: model.searchQuery.isEmpty ? "No apps found" : "No matches",
                message: model.searchQuery.isEmpty ? nil : "Nothing matches \u{201C}\(model.searchQuery)\u{201D}."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(model.visibleApps) { app in
                        AppRowView(
                            app: app,
                            icon: model.icon(for: app),
                            sizeBytes: model.sizeByPath[app.id],
                            lastUsed: model.lastUsedByPath[app.id],
                            isProtected: model.isProtected(app),
                            isRunning: model.isRunning(app),
                            isSelected: model.selection == .app(app)
                        ) {
                            model.select(app)
                        }
                    }
                }
                .padding(SweepTokens.s2)
            }
            .scrollContentBackground(.hidden)
            .background(SweepTokens.ground)
        }
    }

    // MARK: - Detail panel

    @ViewBuilder
    private var detailPanel: some View {
        switch model.selection {
        case .none:
            InventoryEmptyState(
                symbol: "xmark.bin",
                title: "Select an app",
                message: "Choose an app on the left to see what it would leave behind."
            )
        case .app(let app):
            appDetail(app)
        case .orphan(let bundleIdentifier):
            orphanDetail(bundleIdentifier)
        }
    }

    private func appDetail(_ app: InstalledApp) -> some View {
        VStack(spacing: 0) {
            AppSummaryCard(
                app: app,
                icon: model.icon(for: app),
                sizeBytes: model.sizeByPath[app.id],
                isRunning: model.isRunning(app),
                onQuit: { model.quit(app) }
            )
            .padding(SweepTokens.s5)

            Divider()
            leftoverBody(emptyMessage: "Nothing under the known leftover locations is attributed to \(app.name).")
            detailFooter
        }
    }

    private func orphanDetail(_ bundleIdentifier: String) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: SweepTokens.s3) {
                Image(systemName: "questionmark.app.fill")
                    .font(.system(size: 34, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tertiary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bundleIdentifier)
                        .font(SweepFont.rowTitleEmphasis)
                        .lineLimit(1)
                    Text("Already moved to Trash \u{2014} matching leftovers only")
                        .font(SweepFont.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(SweepTokens.s5)

            Divider()
            leftoverBody(emptyMessage: "No leftovers for this bundle id were found under the known locations.")
            detailFooter
        }
    }

    @ViewBuilder
    private func leftoverBody(emptyMessage: String) -> some View {
        Group {
            if model.isLoadingLeftovers {
                InventoryEmptyState(symbol: "magnifyingglass", title: "Looking for leftovers\u{2026}")
            } else if model.leftoverGroups.isEmpty {
                InventoryEmptyState(symbol: "checkmark.circle", title: "No leftovers found", message: emptyMessage)
            } else {
                InventoryList(groups: model.leftoverGroups, selection: $model.leftoverSelection, expansion: $model.leftoverExpansion)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detailFooter: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: SweepTokens.s3) {
                Button("Preview Removal") { model.previewSheetShown = true }
                    .buttonStyle(.sweepPrimary(minWidth: 148))
                    .disabled(model.leftoverGroups.isEmpty && model.selectedAppTotalBytes == 0)
                Spacer(minLength: SweepTokens.s3)
                Text(footerSummaryText)
                    .font(SweepFont.mono)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.vertical, SweepTokens.s3)
        }
        .background(.bar)
    }

    private var footerSummaryText: String {
        let total = model.selectedAppTotalBytes + model.selectedLeftoverBytes
        return "\(SweepFormat.count(model.selectedLeftoverCount)) leftovers selected \u{00B7} \(SweepFormat.bytes(total))"
    }
}

// MARK: - App row

/// One app in the master list: real icon (`NSWorkspace.icon(forFile:)`), name, bundle id, size,
/// last-used — not built on `InventoryRow`, which draws SF Symbol glyphs, never an app icon.
private struct AppRowView: View {
    let app: InstalledApp
    let icon: NSImage
    let sizeBytes: Int64?
    let lastUsed: Date?
    let isProtected: Bool
    let isRunning: Bool
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SweepTokens.s3) {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: SweepTokens.s1) {
                        Text(app.name)
                            .font(SweepFont.rowTitleEmphasis)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        if isProtected {
                            Image(systemName: "lock.fill")
                                .font(.system(size: 11.5, weight: .semibold))
                                .foregroundStyle(.tertiary)
                        }
                        if isRunning {
                            RunningChip()
                        }
                    }
                    Text(app.bundleIdentifier ?? app.bundlePath.path)
                        .font(SweepFont.monoSmall)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: SweepTokens.s2)
                VStack(alignment: .trailing, spacing: 1) {
                    if let sizeBytes {
                        Text(SweepFormat.bytes(sizeBytes))
                            .font(SweepFont.mono)
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView().controlSize(.mini)
                    }
                    if let lastUsed {
                        Text(lastUsed.formatted(.relative(presentation: .named)))
                            .font(SweepFont.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, SweepTokens.s3)
            .frame(height: 58)
            .background {
                RoundedRectangle(cornerRadius: SweepTokens.rowRadius, style: .continuous)
                    .fill(isSelected ? AnyShapeStyle(SweepTokens.accent.opacity(0.12)) : AnyShapeStyle(.clear))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isProtected)
        .opacity(isProtected ? 0.55 : 1)
        .help(isProtected ? "Protected \u{2014} Sweep never offers to remove system or Apple-signed apps" : "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name)\(isProtected ? ", protected" : "")\(isRunning ? ", running" : "")")
    }
}

private struct RunningChip: View {
    var body: some View {
        Text("RUNNING")
            .font(SweepFont.badge)
            .tracking(0.5)
            .foregroundStyle(SweepTokens.tierCaution)
            .lineLimit(1)
            // Layout contract: chips are atoms — never wrap ("RUNNIN / G", user-reported); the
            // app name beside it truncates instead.
            .fixedSize()
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(SweepTokens.tierCaution.opacity(0.12)))
    }
}

// MARK: - App summary card

private struct AppSummaryCard: View {
    let app: InstalledApp
    let icon: NSImage
    let sizeBytes: Int64?
    let isRunning: Bool
    let onQuit: () -> Void

    var body: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SweepTokens.s4) {
                    Image(nsImage: icon).resizable().frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 2) {
                        // Layout contract: one line each, truncated — never the char-per-line
                        // vertical wrap a starved column produces (user-reported "Go og le").
                        Text(app.name)
                            .font(SweepFont.sectionTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Text(subtitle)
                            .font(SweepFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(app.bundlePath.path)
                            .font(SweepFont.monoSmall)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: SweepTokens.s3)
                    VStack(alignment: .trailing, spacing: SweepTokens.s2) {
                        if let sizeBytes {
                            SizeColumn(byteCount: sizeBytes, font: SweepFont.monoEmphasis, emphasized: true)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        if isRunning {
                            Button("Quit App", action: onQuit).buttonStyle(.sweepQuiet)
                        }
                    }
                }
                .padding(SweepTokens.s4)

                if isRunning {
                    Divider()
                    Footnote("Quit \(app.name) before removing it.", symbol: "exclamationmark.triangle")
                        .padding(.horizontal, SweepTokens.s4)
                        .padding(.vertical, SweepTokens.s3)
                }
            }
        }
    }

    private var subtitle: String {
        [app.bundleIdentifier, app.shortVersion].compactMap { $0 }.joined(separator: " \u{00B7} ")
    }
}

// MARK: - Removal preview sheet

/// The removal preview: bundle + every selected leftover, total size — and a "Remove" button that
/// is always disabled. App removal arrives at Gate U (a dedicated execution path with its own
/// review, next wave); this sheet is read-only end to end.
private struct RemovalPreviewSheet: View {
    @Bindable var model: UninstallModel

    var body: some View {
        if let report = model.removalReport {
            // The finished removal, in the same report vocabulary as every other clean.
            CleanReportState(report: report, onDone: { model.finishRemoval() })
                .frame(width: 500)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            previewBody
        }
    }

    private var previewBody: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: SweepTokens.s2) {
                Text(sheetTitle)
                    .font(SweepFont.sectionTitle)
                    .foregroundStyle(.primary)
                let summary = model.previewSummary()
                HStack(spacing: SweepTokens.s2 - 2) {
                    Text(SweepFormat.bytes(summary.totalBytes))
                        .font(SweepFont.monoEmphasis)
                        .foregroundStyle(.primary)
                    Text("across \(SweepFormat.itemCount(summary.itemCount)).")
                        .font(SweepFont.screenSubtitle)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.top, SweepTokens.s5)
            .padding(.bottom, SweepTokens.s4)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: SweepTokens.s3) {
                    if case .app(let app) = model.selection {
                        let parts = SweepFormat.split(model.selectedAppTotalBytes)
                        SectionCard {
                            InventoryRow(
                                symbol: "app.badge", title: app.name, detail: app.bundlePath.path,
                                sizeValue: parts.value, sizeUnit: parts.unit, tier: .safe, emphasis: .summary
                            )
                        }
                    }
                    // Every selected path, individually, no cap (Codex Gate-U re-review
                    // finding #4): what the user confirms here is exactly, itemized, what the
                    // request will carry — never a count standing in for a list.
                    ForEach(selectedGroupSummaries) { row in
                        SectionCard {
                            InventoryRow(
                                symbol: row.symbol, title: row.title, detail: SweepFormat.itemCount(row.count),
                                detailIsPath: false, sizeValue: row.sizeValue, sizeUnit: row.sizeUnit,
                                tier: row.tier, emphasis: .summary
                            )
                            ForEach(row.items) { item in
                                Divider().padding(.horizontal, SweepTokens.s3)
                                InventoryRow(
                                    symbol: item.symbol, title: item.title, detail: item.detail,
                                    sizeValue: item.sizeValue, sizeUnit: item.sizeUnit,
                                    tier: item.tier, emphasis: .standard
                                )
                            }
                        }
                    }
                    if selectedGroupSummaries.isEmpty, case .app = model.selection {
                        Footnote("No leftovers selected \u{2014} only the app itself will move to Trash.", symbol: "info.circle")
                    }
                    Footnote(
                        "Everything above goes to the Trash \u{2014} nothing is deleted outright. Restore from the Trash to undo.",
                        symbol: "arrow.uturn.backward"
                    )
                }
                .padding(SweepTokens.s5)
            }

            Divider()
            HStack(spacing: SweepTokens.s3) {
                if model.isRemoving {
                    ProgressView().controlSize(.small)
                    Text(model.removalProgressCaption ?? "Removing\u{2026}")
                        .font(SweepFont.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if !model.canExecuteRemoval {
                    GateNotice("App removal is disabled in this build")
                }
                Spacer(minLength: SweepTokens.s3)
                Button("Cancel") { model.previewSheetShown = false }
                    .buttonStyle(.sweepQuiet)
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isRemoving)
                Button("Remove") { model.executeRemoval() }
                    .buttonStyle(.sweepDestructive())
                    .disabled(!model.canExecuteRemoval || model.isRemoving)
                    .accessibilityHint("Moves the app and every item listed above to the Trash.")
            }
            .padding(SweepTokens.s5)
        }
        .frame(width: 500)
        .fixedSize(horizontal: false, vertical: true)
        // Consent binds to what THIS sheet displays: identities snapshot on appear, die on
        // disappear (Codex Gate-U re-review #1/#4 — never captured at click time).
        .onAppear { model.prepareRemovalReview() }
        .onDisappear {
            // Unconditional (Codex Gate-U adjudication): the snapshot is copied into the
            // request at the Remove click itself, so a departed sheet can never authorize
            // anything — no dismissal route may leave it alive.
            model.discardRemovalReview()
            // A standing report dismissed by any route (not just its Done button) still
            // finalizes: the disk already changed, so the inventory reload must happen and
            // the stale report must never greet the next review.
            if model.removalReport != nil, !model.isRemoving { model.finishRemoval() }
        }
    }

    private var sheetTitle: String {
        switch model.selection {
        case .app(let app): "Remove \(app.name)?"
        case .orphan(let bundleIdentifier): "Remove leftovers of \(bundleIdentifier)?"
        case .none: "Remove?"
        }
    }

    private struct GroupSummaryRow: Identifiable {
        let id: String
        let title: String
        let symbol: String
        let count: Int
        let sizeValue: String
        let sizeUnit: String
        let tier: SweepTier
        /// Every selected item in the group — the itemized list the sheet renders in full.
        let items: [InventoryItem]
    }

    private var selectedGroupSummaries: [GroupSummaryRow] {
        model.leftoverGroups.compactMap { group in
            let selectedItems = group.items.filter { model.leftoverSelection.contains($0.id) }
            guard !selectedItems.isEmpty else { return nil }
            let bytes = selectedItems.reduce(Int64(0)) { $0 + $1.byteCount }
            let parts = SweepFormat.split(bytes)
            return GroupSummaryRow(
                id: group.id, title: group.title, symbol: group.symbol, count: selectedItems.count,
                sizeValue: parts.value, sizeUnit: parts.unit, tier: group.tier, items: selectedItems
            )
        }
    }
}
