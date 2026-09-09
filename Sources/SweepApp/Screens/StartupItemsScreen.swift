import AppKit
import SweepUI
import SwiftUI

// MARK: - Model

/// Screen-owned state for Startup Items (module 6, PLAN §3). Screen-owned rather than on
/// `AppState` on purpose: every value here is a live reading of the machine — which jobs launchd
/// currently has running, which ones failed last time — and a cached copy that survives navigation
/// would be a stale copy. Re-reading on every visit is the correct behaviour, and it costs one
/// directory listing plus one `launchctl list`.
@MainActor
@Observable
final class StartupItemsModel {
    /// The five questions worth asking of this list. Each is a real segmentation of the same rows,
    /// not a saved search — the counts live beside the chips so the answer is visible before the
    /// filter is even applied.
    enum Filter: String, CaseIterable, Identifiable {
        case all
        case startsItself
        case running
        case thirdParty
        case attention

        var id: String { rawValue }

        /// Deliberately terse. Five chips plus a search field have to survive the narrowest
        /// window the shell allows, and a chip is an atom that never truncates — the long form
        /// lives in the tooltip instead.
        var title: String {
            switch self {
            case .all: "All"
            case .startsItself: "Auto-start"
            case .running: "Running"
            case .thirdParty: "From apps"
            case .attention: "Issues"
            }
        }

        var detail: String {
            switch self {
            case .all: "Every background item Sweep could read."
            case .startsItself: "Starts without anyone asking \u{2014} at login, on a timer, or kept alive continuously."
            case .running: "Has a live process right now."
            case .thirdParty: "Installed by an app or a vendor, not by macOS."
            case .attention: "Points at a missing program, or failed the last time it ran."
            }
        }

        var symbol: String {
            switch self {
            case .all: "square.grid.2x2"
            case .startsItself: "bolt"
            case .running: "play.circle"
            case .thirdParty: "app.badge"
            case .attention: "exclamationmark.triangle"
            }
        }
    }

    /// Everything one background pass produces, in one `Sendable` box so the hop back to the main
    /// actor is a single assignment rather than five.
    private struct Reading: Sendable {
        let rows: [StartupItemRow]
        let statuses: [String: LaunchdStatus]
        let owners: [String: StartupOwner]
    }

    private(set) var rows: [StartupItemRow] = []
    private(set) var serviceRows: [SMAppServiceRow] = []
    private(set) var statuses: [String: LaunchdStatus] = [:]
    private(set) var ownersByRowID: [String: StartupOwner] = [:]
    private(set) var iconsByOwnerID: [String: NSImage] = [:]
    private(set) var hasLoaded = false
    private(set) var isRefreshing = false

    var filter: Filter = .all
    var search: String = ""

    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        await load()
    }

    func load() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let home = ScanEnvironment.resolve().home
        let reading = await Task.detached(priority: .utility) { () -> Reading in
            let rows = StartupItemsScanner.scanAll(home: home)
            let index = InstalledAppIndex.build()
            let statuses = LaunchdStatusService.snapshot()
            var owners: [String: StartupOwner] = [:]
            for row in rows { owners[row.id] = StartupOwnerResolver.owner(for: row, index: index) }
            return Reading(rows: rows, statuses: statuses, owners: owners)
        }.value

        rows = reading.rows
        statuses = reading.statuses
        ownersByRowID = reading.owners
        // `NSImage` is not `Sendable`, so icons are fetched here rather than inside the detached
        // task. One lookup per *owner*, not per row — a vendor with six agents costs one icon.
        var icons: [String: NSImage] = [:]
        for owner in reading.owners.values where icons[owner.id] == nil {
            if let path = owner.appPath { icons[owner.id] = NSWorkspace.shared.icon(forFile: path) }
        }
        iconsByOwnerID = icons
        serviceRows = SMAppServiceInventory.allRows()
        hasLoaded = true
    }

    // MARK: - Derived state

    func runState(for row: StartupItemRow) -> StartupItemRunState {
        StartupItemRunState.resolve(row: row, status: statuses[row.label])
    }

    func owner(for row: StartupItemRow) -> StartupOwner {
        ownersByRowID[row.id] ?? StartupOwner(
            id: "other", name: "Unattributed", kind: .other,
            appPath: nil, symbol: "questionmark.app.dashed", subtitle: nil
        )
    }

    func icon(for owner: StartupOwner) -> NSImage? { iconsByOwnerID[owner.id] }

    /// Broken program, or a job whose last run exited non-zero. The one count on the screen that
    /// is a call to action rather than a description.
    func needsAttention(_ row: StartupItemRow) -> Bool {
        row.isBroken || runState(for: row).isAttention
    }

    private var searchedRows: [StartupItemRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return rows }
        return rows.filter { row in
            row.label.lowercased().contains(query)
                || row.displayName.lowercased().contains(query)
                || (row.executablePath ?? "").lowercased().contains(query)
                || owner(for: row).name.lowercased().contains(query)
                || row.category.label.lowercased().contains(query)
        }
    }

    func matches(_ row: StartupItemRow, _ filter: Filter) -> Bool {
        switch filter {
        case .all: true
        case .startsItself: row.startsByItself
        case .running: runState(for: row).isRunning
        case .thirdParty: owner(for: row).kind == .app || owner(for: row).kind == .vendor
        case .attention: needsAttention(row)
        }
    }

    /// Chip counts are computed against the *searched* set, so a chip never promises rows the
    /// current search has already excluded.
    func count(for filter: Filter) -> Int {
        searchedRows.count { matches($0, filter) }
    }

    var visibleRows: [StartupItemRow] {
        searchedRows.filter { matches($0, filter) }
    }

    /// Grouped by who installed the items, ordered by what a person needs first: anything failing,
    /// then third-party apps alphabetically, then Apple's own machinery last — it is the part
    /// nobody installed and nobody should be poking at.
    var groups: [StartupOwnerGroup] {
        let grouped = Dictionary(grouping: visibleRows) { owner(for: $0).id }
        return grouped.values.compactMap { rows -> StartupOwnerGroup? in
            guard let first = rows.first else { return nil }
            return StartupOwnerGroup(
                owner: owner(for: first),
                rows: rows.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
            )
        }
        .sorted { lhs, rhs in
            let lhsAttention = lhs.rows.contains(where: needsAttention)
            let rhsAttention = rhs.rows.contains(where: needsAttention)
            if lhsAttention != rhsAttention { return lhsAttention }
            if lhs.owner.isApple != rhs.owner.isApple { return rhs.owner.isApple }
            return lhs.owner.name.localizedCaseInsensitiveCompare(rhs.owner.name) == .orderedAscending
        }
    }

    var totalCount: Int { rows.count }
    var startsItselfCount: Int { rows.count(where: \.startsByItself) }
    var runningCount: Int { rows.count { runState(for: $0).isRunning } }
    var attentionCount: Int { rows.count(where: needsAttention) }

    func runningCount(in group: StartupOwnerGroup) -> Int {
        group.rows.count { runState(for: $0).isRunning }
    }

    // MARK: - Actions

    func reveal(_ row: StartupItemRow) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.id)])
    }

    func revealOwnerApp(_ owner: StartupOwner) {
        guard let path = owner.appPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openSystemSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Screen

/// Startup Items (module 6, PLAN §3): read-only inventory, reveal, and a deep link to the System
/// Settings pane that can actually manage them. No enable/disable toggle — PLAN restricts that to
/// modules with a documented public API to back it, and none exists here yet.
///
/// The organizing principle is *who put this here*, not which directory it was found in. A person
/// looking at this screen is asking "what is running behind my back and who is responsible" — the
/// three launchd directories are the answer to a question only a developer asks, so they survive
/// as a per-row scope chip while the app that installed each item, with its own icon, carries the
/// grouping.
struct StartupItemsScreen: View {
    @State private var model = StartupItemsModel()

    var body: some View {
        VStack(spacing: 0) {
            ScreenHeader(
                title: Destination.startupItems.title,
                subtitle: Destination.startupItems.subtitle
            ) {
                HStack(spacing: SweepTokens.s2) {
                    Button("Refresh") { Task { await model.load() } }
                        .buttonStyle(.sweepQuiet)
                        .disabled(model.isRefreshing)
                    Button("Manage in System Settings") { model.openSystemSettings() }
                        .buttonStyle(.sweepQuiet)
                }
            }
            if model.hasLoaded {
                summaryBand
                filterBar
            }
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .task { await model.loadIfNeeded() }
    }

    // MARK: - Summary

    /// Four readings of the same list, above the fold. This is the screen's answer to "so how is
    /// my Mac doing" before any scrolling happens — the inventory underneath is the detail.
    private var summaryBand: some View {
        HStack(spacing: 0) {
            SummaryTile(
                symbol: "power",
                value: model.totalCount,
                caption: model.totalCount == 1 ? "background item" : "background items"
            )
            tileDivider
            SummaryTile(
                symbol: "bolt.fill",
                value: model.startsItselfCount,
                caption: "start on their own",
                help: "Items launchd starts without anyone asking — at login, on a timer, or kept alive continuously."
            )
            tileDivider
            SummaryTile(
                symbol: "play.fill",
                value: model.runningCount,
                caption: "running right now",
                tint: model.runningCount > 0 ? SweepTokens.accent : nil,
                help: "Has a live process this moment, according to launchd. Root daemons are not visible from here."
            )
            tileDivider
            SummaryTile(
                symbol: model.attentionCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                value: model.attentionCount,
                caption: model.attentionCount == 1 ? "needs a look" : "need a look",
                tint: model.attentionCount > 0 ? SweepTokens.tierCaution : nil,
                help: "Points at a program that is gone, or exited with an error the last time it ran."
            )
        }
        .padding(.horizontal, SweepTokens.s5)
        .padding(.bottom, SweepTokens.s4)
    }

    private var tileDivider: some View {
        Divider().frame(height: 30)
    }

    // MARK: - Filters

    /// Layout contract: chips never wrap or truncate, so the row that holds them must be able to
    /// shrink some other way or the whole content pane inherits their combined width as a minimum
    /// and clips against the window edge (observed: the header buttons and the fourth summary tile
    /// were cut off). The horizontal scroller has no minimum width of its own, so the pane stays
    /// free to be as narrow as the shell allows and the chips scroll instead.
    private var filterBar: some View {
        HStack(spacing: SweepTokens.s3) {
            ScrollView(.horizontal) {
                HStack(spacing: SweepTokens.s2) {
                    ForEach(StartupItemsModel.Filter.allCases) { filter in
                        FilterChip(
                            title: filter.title,
                            symbol: filter.symbol,
                            count: model.count(for: filter),
                            isSelected: model.filter == filter,
                            isAlert: filter == .attention && model.count(for: filter) > 0,
                            help: filter.detail
                        ) {
                            withAnimation(SweepMotion.row) { model.filter = filter }
                        }
                    }
                }
                .padding(.vertical, 1)
                .padding(.trailing, SweepTokens.s1)
            }
            .scrollIndicators(.never)
            SweepSearchField(text: $model.search, prompt: "Search")
                .frame(minWidth: 110, idealWidth: 180, maxWidth: 190)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, SweepTokens.s5)
        .padding(.bottom, SweepTokens.s3)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if !model.hasLoaded {
            InventoryEmptyState(symbol: "power", title: "Reading startup items\u{2026}")
        } else if model.rows.isEmpty && model.serviceRows.isEmpty {
            InventoryEmptyState(
                symbol: "checkmark.circle",
                title: "Nothing starts itself here",
                message: "No login items, launch agents or launch daemons were readable on this Mac."
            )
        } else if model.groups.isEmpty {
            InventoryEmptyState(
                symbol: "line.3.horizontal.decrease.circle",
                title: "Nothing matches",
                message: model.search.isEmpty
                    ? "No item falls under \u{201C}\(model.filter.title)\u{201D}."
                    : "No item matches \u{201C}\(model.search)\u{201D} under \u{201C}\(model.filter.title)\u{201D}."
            )
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: SweepTokens.s4) {
                    ForEach(Array(model.groups.enumerated()), id: \.element.id) { index, group in
                        ownerCard(group)
                            .staggeredEntrance(index)
                    }
                    if !model.serviceRows.isEmpty, model.filter == .all, model.search.isEmpty {
                        serviceCard
                    }
                }
                .padding(SweepTokens.s5)
            }
        }
    }

    private func ownerCard(_ group: StartupOwnerGroup) -> some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                ownerHeader(group)
                ForEach(Array(group.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, SweepTokens.s5 + SweepTokens.s4) }
                    StartupItemRowView(
                        row: row,
                        state: model.runState(for: row),
                        onReveal: { model.reveal(row) }
                    )
                }
            }
            .padding(.bottom, SweepTokens.s2)
        }
    }

    private func ownerHeader(_ group: StartupOwnerGroup) -> some View {
        HStack(spacing: SweepTokens.s3) {
            IdentityTile(image: model.icon(for: group.owner), symbol: group.owner.symbol, diameter: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(group.owner.name)
                    .font(SweepFont.rowTitleEmphasis)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(ownerSubtitle(group))
                    .font(SweepFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: SweepTokens.s3)
            if model.runningCount(in: group) > 0 {
                MetaChip(
                    symbol: "play.fill",
                    text: "\(model.runningCount(in: group)) running",
                    tint: SweepTokens.accent,
                    help: "\(model.runningCount(in: group)) of these have a live process right now."
                )
            }
            if group.owner.appPath != nil {
                Button { model.revealOwnerApp(group.owner) } label: {
                    Image(systemName: "arrow.up.forward.square")
                        .font(.system(size: 12.5, weight: .regular))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Reveal \(group.owner.name) in Finder")
                .accessibilityLabel("Reveal \(group.owner.name) in Finder")
            }
        }
        .padding(.horizontal, SweepTokens.s4)
        .padding(.top, SweepTokens.s4)
        .padding(.bottom, SweepTokens.s3)
    }

    private func ownerSubtitle(_ group: StartupOwnerGroup) -> String {
        let count = "\(SweepFormat.count(group.rows.count)) \(group.rows.count == 1 ? "item" : "items")"
        // The categories present, deduped and in the order they appear — "Updater, Cloud sync"
        // says more about what a vendor is doing to your Mac than any count does.
        var seen: Set<String> = []
        let categories = group.rows
            .map(\.category.label)
            .filter { seen.insert($0).inserted }
            .prefix(3)
            .joined(separator: ", ")
        if let subtitle = group.owner.subtitle, group.owner.kind != .app {
            return "\(count) \u{00B7} \(categories) \u{00B7} \(subtitle)"
        }
        return "\(count) \u{00B7} \(categories)"
    }

    /// Sweep's own `SMAppService` registration. Kept last and visually identical to every other
    /// owner card — this app is one more thing on the list, not a special case.
    private var serviceCard: some View {
        SectionCard {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: SweepTokens.s3) {
                    IdentityTile(
                        image: NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath),
                        symbol: "app.badge",
                        diameter: 32
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Sweep")
                            .font(SweepFont.rowTitleEmphasis)
                            .foregroundStyle(.primary)
                        Text("This app\u{2019}s own registration, read through SMAppService")
                            .font(SweepFont.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: SweepTokens.s3)
                }
                .padding(.horizontal, SweepTokens.s4)
                .padding(.top, SweepTokens.s4)
                .padding(.bottom, SweepTokens.s3)

                ForEach(Array(model.serviceRows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { Divider().padding(.leading, SweepTokens.s5 + SweepTokens.s4) }
                    HStack(spacing: SweepTokens.s3 - 2) {
                        Image(systemName: "power.circle")
                            .font(.system(size: 13.5, weight: .regular))
                            .foregroundStyle(.secondary)
                            .frame(width: 17, alignment: .center)
                        Text(row.label)
                            .font(SweepFont.rowTitle)
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer(minLength: SweepTokens.s3)
                        MetaChip(symbol: nil, text: row.statusDescription)
                    }
                    .padding(.horizontal, SweepTokens.s4)
                    .frame(height: SweepTokens.inventoryRowHeight)
                }
            }
            .padding(.bottom, SweepTokens.s2)
        }
    }

    // MARK: - Footer

    private var footer: some View {
        Group {
            if model.hasLoaded, !model.rows.isEmpty {
                VStack(spacing: 0) {
                    Divider()
                    HStack {
                        Footnote(
                            footerText,
                            symbol: model.attentionCount > 0 ? "exclamationmark.triangle" : "checkmark.circle"
                        )
                        Spacer()
                    }
                    .padding(.horizontal, SweepTokens.s5)
                    .padding(.vertical, SweepTokens.s3)
                }
                .background(.bar)
            }
        }
    }

    /// The honest caveat, stated once where it belongs: this module can read, not switch off, and
    /// root daemons are outside what an unprivileged `launchctl list` can see.
    private var footerText: String {
        if model.attentionCount > 0 {
            let noun = model.attentionCount == 1 ? "item is" : "items are"
            return "\(model.attentionCount) \(noun) broken or failing. Sweep reads these; turning one off still happens in System Settings."
        }
        return "Read from launchd, live. Sweep can show and reveal these, not switch them off yet."
    }
}

// MARK: - Row

/// One launch agent/daemon row. Two lines: what it is and what it is doing on the first, the exact
/// launchd label on the second.
///
/// Not built on the shared `InventoryRow` — that component's size column has no equivalent here
/// (there is no byte count to show) and its single-line shape has nowhere to put the state chips,
/// so this reuses only the design tokens.
private struct StartupItemRowView: View {
    let row: StartupItemRow
    let state: StartupItemRunState
    let onReveal: () -> Void

    var body: some View {
        HStack(spacing: SweepTokens.s3 - 2) {
            Image(systemName: row.category.symbol)
                .font(.system(size: 13.5, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .frame(width: 17, alignment: .center)
                .help(row.category.label)

            VStack(alignment: .leading, spacing: 3) {
                // The reveal button rides on the first line with the chips rather than centering
                // against both lines: a two-line row centers it against the gap between them,
                // which reads as a stray glyph floating between the name and its label.
                HStack(spacing: SweepTokens.s2) {
                    Text(row.displayName)
                        .font(SweepFont.rowTitle)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: SweepTokens.s2)
                    chips
                    Button(action: onReveal) {
                        Image(systemName: "arrow.up.forward.square")
                            .font(.system(size: 12.5, weight: .regular))
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Reveal this item\u{2019}s plist in Finder")
                    .accessibilityLabel("Reveal \(row.label) in Finder")
                }
                Text(row.label)
                    .font(SweepFont.monoSmall)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.horizontal, SweepTokens.s4)
        .frame(height: SweepTokens.summaryRowHeight)
        .help(tooltip)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// Layout contract: chips are atoms — `.fixedSize()`, never wrapped — and the name beside them
    /// truncates instead (the rule `TierBadge`/`LipoRunningChip` follow elsewhere).
    @ViewBuilder
    private var chips: some View {
        MetaChip(symbol: row.trigger.symbol, text: row.trigger.label, help: row.trigger.detail)
        MetaChip(symbol: row.source.scopeSymbol, text: row.source.scopeLabel, help: row.source.scopeDetail)
        if row.isBroken {
            MetaChip(
                symbol: "exclamationmark.triangle.fill",
                text: "Broken",
                tint: SweepTokens.tierExpert,
                help: "The program it points at is not on disk: \(row.programPath ?? "unknown"). It cannot start."
            )
        } else if let label = state.label, let detail = state.detail {
            MetaChip(symbol: stateSymbol, text: label, tint: stateTint, help: detail)
        }
    }

    /// Red is a fact here, not a safety tier — the same reasoning the old `BrokenBadge` carried:
    /// "the program is gone" is Sweep reporting what it read, not judging how safe deleting
    /// something would be. Amber marks a job that exited with an error last time, for the same
    /// reason. Everything else stays neutral, and "running" borrows the accent the rest of the app
    /// already uses for live, healthy states.
    private var stateTint: Color? {
        switch state {
        case .running: SweepTokens.accent
        case .failed: SweepTokens.tierCaution
        case .loaded, .notLoaded, .disabled, .unknown: nil
        }
    }

    private var stateSymbol: String? {
        switch state {
        case .running: "play.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .loaded: "checkmark"
        case .notLoaded: "pause"
        case .disabled: "nosign"
        case .unknown: nil
        }
    }

    private var tooltip: String {
        var lines = [row.label, row.category.label + " \u{00B7} " + row.trigger.detail, row.source.scopeDetail]
        if let detail = state.detail { lines.append(detail) }
        if let path = row.executablePath { lines.append("Runs: " + path) }
        lines.append("Defined in: " + row.id)
        return lines.joined(separator: "\n")
    }

    private var accessibilityText: String {
        var parts = [row.displayName, row.category.label, row.trigger.label, row.source.scopeDetail]
        if row.isBroken { parts.append("Broken: program not found") }
        else if let label = state.label { parts.append(label) }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Small parts

/// One reading in the summary band: a glyph, a big tabular number, and what it counts.
private struct SummaryTile: View {
    let symbol: String
    let value: Int
    let caption: String
    var tint: Color?
    var help: String?

    var body: some View {
        HStack(spacing: SweepTokens.s3 - 2) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint ?? Color.secondary)
                .frame(width: 26, height: 26)
                .background(Circle().fill((tint ?? Color.secondary).opacity(tint == nil ? 0.08 : 0.14)))
            VStack(alignment: .leading, spacing: 0) {
                Text("\(value)")
                    .font(SweepFont.hero(22))
                    .monospacedDigit()
                    .foregroundStyle(SweepTokens.heroInk)
                    .contentTransition(.numericText())
                Text(caption)
                    .font(SweepFont.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, SweepTokens.s3)
        .help(help ?? caption)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(value) \(caption)")
    }
}

/// A one-fact pill: trigger, scope, live state, category. Neutral by default — a tint is spent
/// only where the fact is either good news (running) or something to look at (failed, broken).
private struct MetaChip: View {
    let symbol: String?
    let text: String
    var tint: Color?
    var help: String?

    var body: some View {
        HStack(spacing: 3) {
            if let symbol {
                Image(systemName: symbol).font(.system(size: 9.5, weight: .semibold))
            }
            Text(text).font(SweepFont.badge)
        }
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(tint ?? Color.secondary)
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(Capsule().fill((tint ?? Color.secondary).opacity(tint == nil ? 0.08 : 0.14)))
        .help(help ?? text)
    }
}

/// A filter with its own count baked in, so the segmentation is readable before it is used.
private struct FilterChip: View {
    let title: String
    let symbol: String
    let count: Int
    let isSelected: Bool
    let isAlert: Bool
    let help: String
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: SweepTokens.s2 - 3) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                Text(title)
                    .font(SweepFont.caption)
                Text("\(count)")
                    .font(SweepFont.badge)
                    .monospacedDigit()
                    .foregroundStyle(isSelected ? .primary : .tertiary)
            }
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, SweepTokens.s3 - 1)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    isSelected ? tint.opacity(0.16) : (isHovering ? tint.opacity(0.08) : SweepTokens.hairline.opacity(0.7))
                )
            )
            .overlay(
                Capsule().strokeBorder(isSelected ? tint.opacity(0.32) : .clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var tint: Color { isAlert ? SweepTokens.tierCaution : SweepTokens.accent }

    private var foreground: Color {
        if isSelected || isAlert { return tint }
        return .secondary
    }
}
