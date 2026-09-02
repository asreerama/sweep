import AppKit
import SweepCore
import SweepUI
import SwiftUI

// MARK: - Pure logic (unit-testable; see Tests/SweepAppTests/LargeOldFilesLogicTests.swift)

/// Minimum-size filter, module 4 (PLAN §3). Decimal bytes, matching every other size in the app
/// (`SweepFormat` — 1 MB = 1,000,000 B, not 1,048,576).
enum LargeFileSizeThreshold: Int64, CaseIterable, Identifiable, Sendable {
    case mb50 = 50_000_000
    case mb100 = 100_000_000
    case mb500 = 500_000_000
    case gb1 = 1_000_000_000

    var id: Self { self }
    var bytes: Int64 { rawValue }

    var label: String {
        switch self {
        case .mb50: "50 MB"
        case .mb100: "100 MB"
        case .mb500: "500 MB"
        case .gb1: "1 GB"
        }
    }

    /// The floor the walk itself filters to. Every threshold above this is a free in-memory
    /// re-filter of the same collected entries, not a second disk walk.
    static let smallest: LargeFileSizeThreshold = .mb50
}

/// "age sort" (PLAN §3 module 4): size is a filter, age is only ever a sort key.
enum LargeFileSortOrder: String, CaseIterable, Identifiable, Sendable {
    case largestFirst
    case oldestFirst

    var id: Self { self }

    var label: String {
        switch self {
        case .largestFirst: "Largest first"
        case .oldestFirst: "Oldest first"
        }
    }
}

/// One file at or above `LargeFileSizeThreshold.smallest`, decoupled from `SweepCore.ScanCandidate`
/// so the filter/sort/group logic below is plain-value testable without a scan engine.
struct LargeFileEntry: Sendable, Equatable {
    let id: String
    let name: String
    /// Home-abbreviated display path (`~/Movies/…`), never the raw absolute path — that stays
    /// only in `id`, for the reveal action.
    let path: String
    let bytes: Int64
    let modified: Date
}

enum LargeFilesLogic {

    /// Size filter (picker) + age/size sort (PLAN §3: "size threshold picker; age sort").
    static func filterAndSort(
        _ entries: [LargeFileEntry],
        threshold: LargeFileSizeThreshold,
        sortOrder: LargeFileSortOrder
    ) -> [LargeFileEntry] {
        let filtered = entries.filter { $0.bytes >= threshold.bytes }
        switch sortOrder {
        case .largestFirst: return filtered.sorted { $0.bytes > $1.bytes }
        case .oldestFirst: return filtered.sorted { $0.modified < $1.modified }
        }
    }

    /// The top-level folder a home-abbreviated display path falls under (`"~/Downloads/x"` →
    /// `"Downloads"`), used only to group the flat result list into something scannable. Anything
    /// outside home (a second volume, say) buckets to one shared "Other locations" group rather
    /// than one group per exotic mount point.
    static func topLevelBucket(forDisplayPath path: String) -> String {
        guard path.hasPrefix("~/") else { return path == "~" ? "Home" : "Other locations" }
        let rest = path.dropFirst(2)
        guard let first = rest.split(separator: "/", maxSplits: 1).first, !first.isEmpty else {
            return "Home"
        }
        return String(first)
    }

    static func symbol(forBucket bucket: String) -> String {
        switch bucket {
        case "Downloads": "arrow.down.circle"
        case "Movies": "film"
        case "Music": "music.note"
        case "Desktop": "menubar.dock.rectangle"
        case "Documents": "doc.text"
        case "Pictures": "photo"
        case "Library": "gearshape"
        case "Home": "house"
        default: "folder"
        }
    }

    /// Groups already-filtered entries by top-level bucket. Every item is tier `.caution`: unlike
    /// System Junk's caches, a large video or archive under Documents/Movies/Downloads is real
    /// user content, never a candidate for auto-selection even after Gate 1 (PLAN §3 "primary
    /// modules may auto-select tier-safe items" — nothing here is ever safe-tier).
    static func buildGroups(from entries: [LargeFileEntry]) -> [InventoryGroup] {
        var byBucket: [String: [InventoryItem]] = [:]
        var order: [String] = []
        for entry in entries {
            let bucket = topLevelBucket(forDisplayPath: entry.path)
            if byBucket[bucket] == nil { order.append(bucket) }
            byBucket[bucket, default: []].append(
                InventoryItem(
                    id: entry.id,
                    title: entry.name,
                    detail: entry.path,
                    symbol: "doc",
                    byteCount: entry.bytes,
                    tier: .caution
                )
            )
        }
        return order
            .map { bucket in
                InventoryGroup(id: bucket, title: bucket, symbol: symbol(forBucket: bucket), items: byBucket[bucket] ?? [])
            }
            .sorted { $0.byteCount > $1.byteCount }
    }
}

// MARK: - Scan (impure; walks the disk via SweepCore.ScanEngine)

/// Read-only, unattributed volume walk for Large & Old Files.
///
/// Unlike `ScanService` (System Junk/Smart Scan's rule-catalog walk), this is not rule-driven:
/// it walks the whole home directory once, keeping every file at or above
/// `LargeFileSizeThreshold.smallest`, so later threshold/sort changes in the UI are free
/// in-memory re-filters instead of new disk walks. `honorsPolicyDenylist: true` means
/// Documents, Desktop, Pictures, iCloud Drive, `~/Library/CloudStorage` and the mail store are
/// never descended into — the module's "skips cloud-backed paths" contract is enforced by the
/// walker itself, not by a filter here.
enum LargeFilesScanService {
    struct Tick: Sendable {
        let sequence: Int
        let filesExamined: Int
        let claimedBytes: Int64
        let currentPath: String?
    }

    struct Outcome: Sendable {
        let entries: [LargeFileEntry]
        let filesExamined: Int
        let claimedBytes: Int64
        /// Distinct denylisted roots the walk refused to enter (Documents, iCloud Drive, …).
        let skippedPolicyCount: Int
        let duration: TimeInterval
        let cancelled: Bool
    }

    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    static func run(
        home: URL,
        floorBytes: Int64,
        onTick: @Sendable @escaping (Tick) -> Void
    ) async -> Outcome {
        let started = Date()
        let engine = ScanEngine()
        let displayHome = home.path
        let request = ScanRequest(
            roots: [home],
            includesDirectories: false,
            honorsPolicyDenylist: true,
            progressInterval: 512
        )

        var entries: [LargeFileEntry] = []
        var seenInodes = Set<InodeKey>()
        var policyDenied = Set<String>()
        var filesExamined = 0
        var claimedBytes: Int64 = 0
        var sequence = 0
        var lastTick = ContinuousClock.now
        var cancelled = false

        do {
            for try await event in await engine.scan(request) {
                if Task.isCancelled { cancelled = true; break }
                switch event {
                case .started:
                    break

                case .progress(let progress):
                    filesExamined = progress.itemsSeen
                    let now = ContinuousClock.now
                    if now - lastTick >= .milliseconds(40) {
                        lastTick = now
                        sequence += 1
                        onTick(Tick(
                            sequence: sequence,
                            filesExamined: filesExamined,
                            claimedBytes: claimedBytes,
                            currentPath: progress.currentPath.map { SweepFormat.abbreviatingHome($0, home: displayHome) }
                        ))
                    }

                case .candidate(let candidate):
                    guard candidate.identity.kind == .file, candidate.allocatedSize >= floorBytes else { continue }
                    let inode = InodeKey(device: candidate.identity.deviceID, inode: candidate.identity.inode)
                    guard seenInodes.insert(inode).inserted else { continue }
                    claimedBytes += candidate.allocatedSize
                    entries.append(LargeFileEntry(
                        id: candidate.url.path,
                        name: candidate.url.lastPathComponent,
                        path: SweepFormat.abbreviatingHome(candidate.url.path, home: displayHome),
                        bytes: candidate.allocatedSize,
                        modified: candidate.identity.modification.date
                    ))

                case .finished(let summary):
                    if summary.cancelled { cancelled = true }
                    for issue in summary.issues where issue.reason == .policyDenied {
                        policyDenied.insert(issue.url.path)
                    }
                }
            }
        } catch is CancellationError {
            cancelled = true
        } catch {
            // A root-level failure (home unreadable, wrong volume) still returns whatever was
            // collected before the error. There is no separate "failed" phase to route to here,
            // unlike System Junk's missing-catalog case: a partial home walk is still useful
            // information, and this module has no destructive path to gate on the strength of a
            // walk error either way.
        }

        return Outcome(
            entries: entries,
            filesExamined: filesExamined,
            claimedBytes: claimedBytes,
            skippedPolicyCount: policyDenied.count,
            duration: Date().timeIntervalSince(started),
            cancelled: cancelled
        )
    }
}

enum LargeFilesPhase: Equatable {
    case idle
    case scanning
    case results
}

@MainActor
@Observable
final class LargeFilesModel {
    private(set) var phase: LargeFilesPhase = .idle
    private(set) var rawEntries: [LargeFileEntry] = []
    private(set) var filesExamined = 0
    private(set) var claimedBytes: Int64 = 0
    private(set) var currentPath: String?
    private(set) var skippedPolicyCount = 0
    private(set) var wasCancelled = false

    var threshold: LargeFileSizeThreshold = .mb100
    var sortOrder: LargeFileSortOrder = .largestFirst

    private var task: Task<Void, Never>?
    private var lastSequence = 0

    var groups: [InventoryGroup] {
        LargeFilesLogic.buildGroups(
            from: LargeFilesLogic.filterAndSort(rawEntries, threshold: threshold, sortOrder: sortOrder)
        )
    }

    var skippedSummary: String? {
        guard skippedPolicyCount > 0 else { return nil }
        let noun = skippedPolicyCount == 1 ? "location" : "locations"
        return "\(skippedPolicyCount) \(noun) skipped (cloud/protected)."
    }

    var scanningCaption: String { "\(SweepFormat.count(filesExamined)) files examined" }

    var resultsCaption: String {
        "\(SweepFormat.count(rawEntries.count)) files at or above \(LargeFileSizeThreshold.smallest.label)"
    }

    func start() {
        guard task == nil else { return }
        phase = .scanning
        rawEntries = []
        filesExamined = 0
        claimedBytes = 0
        currentPath = nil
        skippedPolicyCount = 0
        wasCancelled = false
        lastSequence = 0

        let home = ScanEnvironment.resolve().home
        let floor = LargeFileSizeThreshold.smallest.bytes

        task = Task { [weak self] in
            let outcome = await LargeFilesScanService.run(home: home, floorBytes: floor) { [weak self] tick in
                guard let self else { return }
                Task { @MainActor in self.applyTick(tick) }
            }
            self?.finish(outcome)
        }
    }

    func cancel() { task?.cancel() }

    func rescan() {
        cancel()
        task = nil
        start()
    }

    private func applyTick(_ tick: LargeFilesScanService.Tick) {
        guard phase == .scanning, tick.sequence > lastSequence else { return }
        lastSequence = tick.sequence
        filesExamined = tick.filesExamined
        claimedBytes = tick.claimedBytes
        currentPath = tick.currentPath
    }

    private func finish(_ outcome: LargeFilesScanService.Outcome) {
        task = nil
        rawEntries = outcome.entries
        filesExamined = outcome.filesExamined
        claimedBytes = outcome.claimedBytes
        skippedPolicyCount = outcome.skippedPolicyCount
        wasCancelled = outcome.cancelled
        currentPath = nil
        phase = .results
    }
}

// MARK: - Screen

/// Large & Old Files (module 4, PLAN §3): volume scan, size/age filters, reveal + (locked) trash.
struct LargeOldFilesScreen: View {
    @State private var model = LargeFilesModel()
    @State private var query = ""
    @State private var expansion = InventoryExpansion()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleGroups: [InventoryGroup] {
        InventoryAggregate.filter(model.groups, query: query)
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            ScreenHeader(
                title: Destination.largeFiles.title,
                subtitle: Destination.largeFiles.subtitle
            ) {
                HStack(spacing: SweepTokens.s2) {
                    if model.phase == .results, !model.groups.isEmpty {
                        SweepSearchField(text: $query, prompt: "Filter paths").frame(width: 240)
                    }
                    Picker("Minimum size", selection: $model.threshold) {
                        ForEach(LargeFileSizeThreshold.allCases) { threshold in
                            Text(threshold.label).tag(threshold)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 84)
                    .disabled(model.phase == .scanning)

                    Picker("Sort", selection: $model.sortOrder) {
                        ForEach(LargeFileSortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 116)
                    .disabled(model.phase == .scanning)

                    if model.phase == .scanning {
                        Button("Stop") { model.cancel() }.buttonStyle(.sweepQuiet)
                    } else {
                        Button(model.phase == .idle ? "Scan" : "Rescan") { model.rescan() }
                            .buttonStyle(.sweepQuiet)
                    }
                }
            }

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            footer
        }
        .animation(reduceMotion ? SweepMotion.crossfade : SweepMotion.layout, value: model.phase)
        .onChange(of: model.groups) { _, newValue in expansion = .initial(for: newValue) }
        .onChange(of: model.threshold) { _, _ in expansion = .initial(for: model.groups) }
        .onChange(of: model.sortOrder) { _, _ in expansion = .initial(for: model.groups) }
        .onDisappear { model.cancel() }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            InventoryEmptyState(
                symbol: "doc.zipper",
                title: "No scan yet",
                message: "Walks your home folder for files at or above \(LargeFileSizeThreshold.smallest.label). "
                    + "Documents, Desktop, Pictures and anything cloud-backed are never read."
            )
        case .scanning:
            scanningState
        case .results:
            if visibleGroups.isEmpty {
                InventoryEmptyState(
                    symbol: query.isEmpty ? "checkmark.circle" : "magnifyingglass",
                    title: query.isEmpty ? "Nothing at or above \(model.threshold.label)" : "No matches",
                    message: query.isEmpty
                        ? "Try a lower minimum size, or rescan."
                        : "Nothing in the results matches \u{201C}\(query)\u{201D}."
                )
            } else {
                RevealableInventoryList(groups: visibleGroups, expansion: $expansion, onReveal: reveal)
            }
        }
    }

    private var scanningState: some View {
        VStack(spacing: SweepTokens.s5) {
            ScanRing(state: .scanning, diameter: SweepTokens.moduleRingDiameter) {
                HeroByteCounter(byteCount: model.claimedBytes, size: SweepTokens.moduleRingCounterSize)
            }
            Text(model.scanningCaption)
                .font(SweepFont.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
            PathTicker(path: model.currentPath, width: 420)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: SweepTokens.s3) {
                // Trash action present, per module spec, but locked: same treatment Smart Scan
                // and System Junk use ahead of Gate 1 — a disabled primary button plus a plain
                // stated reason, not a banner to dismiss.
                Button("Move to Trash") {}
                    .buttonStyle(.sweepPrimary(minWidth: 132))
                    .disabled(true)
                    .help("Cleaning arrives at Gate 1")
                    .accessibilityHint("Disabled. Cleaning arrives at Gate 1.")
                GateNotice("Cleaning arrives at Gate 1")
                Spacer(minLength: SweepTokens.s3)
                if model.phase == .results, !model.groups.isEmpty {
                    Text(model.resultsCaption)
                        .font(SweepFont.mono)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, SweepTokens.s5)
            .padding(.vertical, SweepTokens.s3)
            if let note = model.skippedSummary, model.phase == .results {
                Footnote(note, symbol: "icloud.slash")
                    .padding(.horizontal, SweepTokens.s5)
                    .padding(.bottom, SweepTokens.s3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.bar)
    }

    /// Read-only, sandboxed-safe: hands the item off to Finder rather than touching it directly.
    private func reveal(_ item: InventoryItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.id)])
    }
}

/// A reveal-capable variant of the shared `InventoryList` template.
///
/// `InventoryList` (SweepUI) has no per-row action slot and its "Show all" row
/// (`InventoryShowMoreRow`) is `internal` to that module, so this rebuilds the same shape locally
/// — same `GroupHeader`/`InventoryRow`, same `InventoryExpansion`/`InventoryBudget` bounded
/// paging — with one added trailing button per row. If `InventoryRow`/`InventoryList` grow a
/// trailing-action slot later, this can be deleted in favor of the shared component.
private struct RevealableInventoryList: View {
    let groups: [InventoryGroup]
    @Binding var expansion: InventoryExpansion
    let onReveal: (InventoryItem) -> Void

    var body: some View {
        ScrollView(.vertical) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(groups) { group in
                    Section {
                        if !expansion.isCollapsed(group) {
                            ForEach(group.items.prefix(expansion.visibleCount(for: group))) { item in
                                row(item)
                            }
                            .padding(.bottom, 1)
                            if expansion.hasMore(group) {
                                showMoreRow(group)
                            }
                        }
                    } header: {
                        GroupHeader(
                            group: group,
                            isExpanded: Binding(
                                get: { !expansion.isCollapsed(group) },
                                set: { shouldExpand in
                                    guard shouldExpand != !expansion.isCollapsed(group) else { return }
                                    expansion.toggleCollapsed(group, in: groups)
                                }
                            )
                        )
                    }
                }
                Color.clear.frame(height: SweepTokens.s4)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ item: InventoryItem) -> some View {
        HStack(spacing: SweepTokens.s1) {
            InventoryRow(item: item, indented: true)
            Button {
                onReveal(item)
            } label: {
                Image(systemName: "arrow.up.forward.square")
                    .font(.system(size: 12.5, weight: .regular))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Reveal in Finder")
            .accessibilityLabel("Reveal \(item.title) in Finder")
            .padding(.trailing, SweepTokens.s3)
        }
    }

    private func showMoreRow(_ group: InventoryGroup) -> some View {
        let shown = expansion.visibleCount(for: group)
        return Button {
            withAnimation(SweepMotion.row) {
                expansion.showMore(group, in: groups)
            }
        } label: {
            HStack(spacing: SweepTokens.s2) {
                Color.clear.frame(width: SweepTokens.rowDisclosureIndent, height: 1)
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13.5, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 17, alignment: .center)
                Text("Show all \(SweepFormat.count(group.itemCount))")
                    .font(SweepFont.rowTitle)
                    .foregroundStyle(Color.accentColor)
                Text("\(SweepFormat.count(shown)) of \(SweepFormat.count(group.itemCount)) shown")
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
        .accessibilityLabel("Show all \(group.itemCount) items, \(shown) currently shown")
    }
}
