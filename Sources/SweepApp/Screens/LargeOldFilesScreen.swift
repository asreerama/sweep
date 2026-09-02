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
    /// Device+inode captured at scan time. The trash path re-reads the live file and refuses
    /// one that changed or vanished since the scan — the same identity discipline every other
    /// mutation in this app follows. `nil` only in unit-test fixtures, where no real file backs
    /// the entry.
    let identity: FileIdentity?

    init(id: String, name: String, path: String, bytes: Int64, modified: Date, identity: FileIdentity? = nil) {
        self.id = id
        self.name = name
        self.path = path
        self.bytes = bytes
        self.modified = modified
        self.identity = identity
    }
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
        /// Entries found since the previous tick (user-directed: results stream into the list
        /// as the walk runs instead of hiding behind the ring for minutes). Hits at or above
        /// the floor are rare relative to files examined, so a tick's batch is small.
        let newEntries: [LargeFileEntry]
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
        var pendingEntries: [LargeFileEntry] = []
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
                            currentPath: progress.currentPath.map { SweepFormat.abbreviatingHome($0, home: displayHome) },
                            newEntries: pendingEntries
                        ))
                        pendingEntries = []
                    }

                case .candidate(let candidate):
                    guard candidate.identity.kind == .file, candidate.allocatedSize >= floorBytes else { continue }
                    let inode = InodeKey(device: candidate.identity.deviceID, inode: candidate.identity.inode)
                    guard seenInodes.insert(inode).inserted else { continue }
                    claimedBytes += candidate.allocatedSize
                    let entry = LargeFileEntry(
                        id: candidate.url.path,
                        name: candidate.url.lastPathComponent,
                        path: SweepFormat.abbreviatingHome(candidate.url.path, home: displayHome),
                        bytes: candidate.allocatedSize,
                        modified: candidate.identity.modification.date,
                        identity: candidate.identity
                    )
                    entries.append(entry)
                    pendingEntries.append(entry)

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

    // MARK: Trash flow (user-directed: results are actionable, including mid-scan)

    /// Opt-in only: everything here is tier `.caution` (real user content), so nothing is ever
    /// pre-selected — the exact opposite default from System Junk's safe tier.
    var selection = InventorySelection()
    var confirmTrashShown = false
    private(set) var isTrashing = false
    private(set) var trashReport: SweepUI.CleanReport?
    /// Ids trashed while the walk was still running: `finish(_:)` must not resurrect them when
    /// it replaces `rawEntries` with the walk's own complete list.
    private var trashedIDs = Set<String>()

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
        selection = InventorySelection()
        trashedIDs = []
        trashReport = nil

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
        if !tick.newEntries.isEmpty {
            rawEntries.append(contentsOf: tick.newEntries)
        }
    }

    private func finish(_ outcome: LargeFilesScanService.Outcome) {
        task = nil
        // The walk's own list is the complete truth — minus anything the user already trashed
        // while it was still running (streaming makes that possible now).
        rawEntries = outcome.entries.filter { !trashedIDs.contains($0.id) }
        filesExamined = outcome.filesExamined
        claimedBytes = outcome.claimedBytes
        skippedPolicyCount = outcome.skippedPolicyCount
        wasCancelled = outcome.cancelled
        currentPath = nil
        phase = .results
    }

    // MARK: - Trash execution

    var selectedCount: Int { selection.selectedCount(in: groups) }
    var selectedBytes: Int64 { selection.selectedBytes(in: groups) }

    /// Moves every selected (and currently visible under the threshold) file to the Trash —
    /// reversible by design, one identity-checked `trashItem` per file, with per-item honesty
    /// in the report. No Gate-1 catalog authorization applies here: these are user-picked
    /// files the user is looking at, not rule-matched junk, and the mutation is a reversible
    /// move confirmed explicitly — the same consent shape as the Uninstaller's itemized sheet.
    func executeTrash() {
        guard !isTrashing else { return }
        let items = groups.flatMap(\.items).filter { selection.contains($0.id) }
        guard !items.isEmpty else { return }
        let identityByID = Dictionary(uniqueKeysWithValues: rawEntries.map { ($0.id, $0.identity) })
        isTrashing = true

        Task {
            let result = await Task.detached(priority: .userInitiated) {
                Self.performTrash(items: items, identityByID: identityByID)
            }.value
            for id in result.trashedIDs {
                trashedIDs.insert(id)
                selection.set(id, selected: false)
            }
            rawEntries.removeAll { result.trashedIDs.contains($0.id) }
            trashReport = SweepUI.CleanReport(
                freedBytes: result.freedBytes,
                succeededCount: result.trashedIDs.count,
                outcomes: result.outcomes
            )
            isTrashing = false
        }
    }

    func dismissTrashReport() { trashReport = nil }

    private struct TrashResult: Sendable {
        let outcomes: [SweepUI.CleanItemOutcome]
        let trashedIDs: Set<String>
        let freedBytes: Int64
    }

    private nonisolated static func performTrash(
        items: [InventoryItem], identityByID: [String: FileIdentity?]
    ) -> TrashResult {
        var outcomes: [SweepUI.CleanItemOutcome] = []
        var trashed = Set<String>()
        var freed: Int64 = 0
        for item in items {
            let url = URL(fileURLWithPath: item.id)
            // Same discipline as every other mutation in this app: the thing being trashed
            // must be the thing the scan showed. A changed or vanished file settles as a
            // per-item refusal, never a silent skip and never a trash of whatever sits there
            // now.
            if let reviewed = identityByID[item.id] ?? nil {
                guard let live = try? FileIdentity.read(at: url), live.isSameFile(as: reviewed) else {
                    outcomes.append(SweepUI.CleanItemOutcome(
                        id: item.id, title: item.title, byteCount: 0,
                        status: .failed(reason: "It changed or disappeared since the scan \u{2014} rescan to act on it.")
                    ))
                    continue
                }
            }
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashed.insert(item.id)
                freed += item.byteCount
                outcomes.append(SweepUI.CleanItemOutcome(
                    id: item.id, title: item.title, byteCount: item.byteCount, status: .succeeded
                ))
            } catch {
                outcomes.append(SweepUI.CleanItemOutcome(
                    id: item.id, title: item.title, byteCount: 0,
                    status: .failed(reason: (error as NSError).localizedDescription)
                ))
            }
        }
        return TrashResult(outcomes: outcomes, trashedIDs: trashed, freedBytes: freed)
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
                    // Live during the scan too: threshold and sort are in-memory re-filters of
                    // entries already streamed in, never a second walk.
                    Picker("Minimum size", selection: $model.threshold) {
                        ForEach(LargeFileSizeThreshold.allCases) { threshold in
                            Text(threshold.label).tag(threshold)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 84)

                    Picker("Sort", selection: $model.sortOrder) {
                        ForEach(LargeFileSortOrder.allCases) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(width: 116)

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
        // Reset expansion only when the set of groups changes, not on every streamed batch —
        // resetting per batch would fight the user's own collapse/show-more choices all scan.
        .onChange(of: model.groups.map(\.id)) { _, _ in expansion = .initial(for: model.groups) }
        .onChange(of: model.threshold) { _, _ in expansion = .initial(for: model.groups) }
        .onChange(of: model.sortOrder) { _, _ in expansion = .initial(for: model.groups) }
        .onDisappear { model.cancel() }
        .confirmationDialog(
            "Move \(SweepFormat.count(model.selectedCount)) \(model.selectedCount == 1 ? "file" : "files") to the Trash?",
            isPresented: $model.confirmTrashShown, titleVisibility: .visible
        ) {
            Button("Move to Trash", role: .destructive) { model.executeTrash() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Frees \(SweepFormat.bytes(model.selectedBytes)). Everything goes to the Trash \u{2014} restore from there to undo.")
        }
        .sheet(isPresented: Binding(
            get: { model.trashReport != nil },
            set: { if !$0 { model.dismissTrashReport() } }
        )) {
            if let report = model.trashReport {
                CleanReportState(report: report, onDone: { model.dismissTrashReport() })
                    .padding(SweepTokens.s5)
                    .frame(width: 480)
            }
        }
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
            // Results stream in as the walk runs (user-directed: no minutes-long ring). The
            // ring appears only for the opening moments before the first hit lands; from then
            // on the list itself is the progress surface, with a slim live strip above it.
            if model.rawEntries.isEmpty {
                scanningState
            } else {
                VStack(spacing: 0) {
                    streamingStrip
                    Divider()
                    listOrEmpty
                }
            }
        case .results:
            listOrEmpty
        }
    }

    @ViewBuilder
    private var listOrEmpty: some View {
        if visibleGroups.isEmpty {
            InventoryEmptyState(
                symbol: query.isEmpty ? "checkmark.circle" : "magnifyingglass",
                title: query.isEmpty ? "Nothing at or above \(model.threshold.label)" : "No matches",
                message: query.isEmpty
                    ? "Try a lower minimum size, or rescan."
                    : "Nothing in the results matches \u{201C}\(query)\u{201D}."
            )
        } else {
            RevealableInventoryList(
                groups: visibleGroups, selection: $model.selection, expansion: $expansion, onReveal: reveal
            )
        }
    }

    /// The live progress readout while results are already on screen: counter, current path,
    /// and the running claimed total — the ring's information, one line tall.
    private var streamingStrip: some View {
        @Bindable var model = model
        return HStack(spacing: SweepTokens.s3) {
            ProgressView().controlSize(.small)
            Text(model.scanningCaption)
                .font(SweepFont.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            PathTicker(path: model.currentPath, width: 300)
            Spacer(minLength: SweepTokens.s3)
            Text(SweepFormat.bytes(model.claimedBytes))
                .font(SweepFont.mono)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
        }
        .padding(.horizontal, SweepTokens.s5)
        .padding(.vertical, SweepTokens.s2 + 2)
        .background(.bar)
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
                // Live (user-directed): identity-checked, reversible move to Trash with an
                // explicit confirmation — enabled the moment anything is selected, including
                // while the walk is still streaming results in.
                Button(model.isTrashing ? "Moving\u{2026}" : "Move to Trash") { model.confirmTrashShown = true }
                    .buttonStyle(.sweepPrimary(minWidth: 132))
                    .disabled(model.selectedCount == 0 || model.isTrashing)
                if model.selectedCount > 0 {
                    Text("\(SweepFormat.count(model.selectedCount)) selected \u{00B7} \(SweepFormat.bytes(model.selectedBytes))")
                        .font(SweepFont.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                }
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
    @Binding var selection: InventorySelection
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
                            selection: selection.state(of: group),
                            onToggleSelection: {
                                selection.setAll(group, selected: selection.state(of: group) != .all)
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
                }
                Color.clear.frame(height: SweepTokens.s4)
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func row(_ item: InventoryItem) -> some View {
        HStack(spacing: SweepTokens.s1) {
            InventoryRow(
                item: item,
                selection: Binding(
                    get: { selection.contains(item.id) },
                    set: { selection.set(item.id, selected: $0) }
                ),
                indented: true
            )
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
