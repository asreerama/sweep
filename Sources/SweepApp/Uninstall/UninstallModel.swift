import AppKit
import Foundation
import Observation
import OSLog
import SweepCore
import SweepUI
import SweepUninstall

/// Same subsystem/category convention as `QuarantineWatch` — one place to `log stream --predicate
/// 'subsystem == "com.aditya.sweep"'` for evidence a drop target (window or Dock) actually routed
/// to a real selection, independent of whether a screen is available to look at (this machine
/// runs headless more often than not).
private let uninstallLog = Logger(subsystem: "com.aditya.sweep", category: "uninstall")

/// Where the leftover panel currently points: nothing, an installed app, or an orphan bundle id
/// (the SmartDelete watcher's deep link — the app itself is already in the Trash, so there is no
/// `InstalledApp` to hold, only the bundle id it left behind).
enum UninstallSelectionMode: Equatable {
    case none
    case app(InstalledApp)
    case orphan(bundleIdentifier: String)
}

/// Drives the Uninstaller screen (PLAN §3 module 5, AppCleaner parity). Discovery
/// (`AppInventory`/`LeftoverMatcher`) never writes; execution goes through exactly one path —
/// `executeRemoval()` at the bottom of this file, the uninstall counterpart of `CleanAdapter` —
/// into `SweepCore.UninstallService`, which stays inert while Gate U is closed
/// (`canExecuteRemoval` is what the Remove button keys off).
@MainActor
@Observable
final class UninstallModel {
    private(set) var apps: [InstalledApp] = []
    private(set) var isLoadingApps = false
    private(set) var sizeByPath: [String: Int64] = [:]
    private(set) var lastUsedByPath: [String: Date] = [:]

    var searchQuery = ""
    var sortField: AppSortField = .name
    var sortAscending = true

    private(set) var selection: UninstallSelectionMode = .none
    private(set) var leftoverGroups: [InventoryGroup] = []
    var leftoverSelection = InventorySelection()
    var leftoverExpansion = InventoryExpansion()
    private(set) var isLoadingLeftovers = false
    private(set) var leftoverSizeByID: [String: Int64] = [:]

    var previewSheetShown = false

    private let home: URL
    private var iconByPath: [String: NSImage] = [:]
    private var sizeTask: Task<Void, Never>?
    private var leftoverTask: Task<Void, Never>?
    private var leftoverSizeTask: Task<Void, Never>?
    /// Pre-walked search-root index (see `LeftoverRootIndex`): built once in the background when the
    /// uninstaller opens so selecting an app matches against cached entries instead of re-walking
    /// `~/Library` every click. `@ObservationIgnored` — nothing in the UI observes it directly.
    @ObservationIgnored private var rootIndex: LeftoverRootIndex?
    @ObservationIgnored private var rootIndexTask: Task<Void, Never>?
    /// Prefetched pkgutil receipts (ids + per-package file lists), same session-cache pattern as
    /// `rootIndex` and for the same reason: consulting the live provider inside a click meant one
    /// `pkgutil --files` process spawn per installed package — measured at ~4.4 s for 49 packages,
    /// ~95% of the user-reported "Looking for leftovers…" stall.
    @ObservationIgnored private var receiptsCache: PrefetchedPkgutilReceipts?
    @ObservationIgnored private var receiptsTask: Task<Void, Never>?

    // MARK: - Gate U execution state

    /// True for the whole span of a live removal — the preview sheet shows progress in place.
    private(set) var isRemoving = false
    /// The finished removal's report, mapped to the shared report vocabulary; the sheet swaps to
    /// `CleanReportState` while this is non-nil.
    private(set) var removalReport: SweepUI.CleanReport?
    private(set) var removalProgressCaption: String?

    /// Whether this build can actually execute (Gate U open + runtime kill switch clear).
    var canExecuteRemoval: Bool { SweepCore.UninstallService.isEnabled }

    /// Identities captured the moment the preview sheet RENDERS (Codex Gate-U re-review: the
    /// reviewed object is the one the sheet displayed, so a same-path replacement made while
    /// the sheet is open must mismatch at execute). `executeRemoval()` refuses to run without
    /// this snapshot; it dies with the sheet.
    struct ReviewSnapshot {
        let bundleIdentity: FileIdentity
        let leftoverIdentityByPath: [String: FileIdentity]
        let selectedPaths: Set<String>
    }
    @ObservationIgnored private(set) var reviewSnapshot: ReviewSnapshot?

    /// Called when the preview sheet appears — binds consent to exactly what it renders.
    func prepareRemovalReview() {
        reviewSnapshot = nil
        guard case .app(let app) = selection else { return }
        guard let bundleIdentity = try? FileIdentity.read(at: app.bundlePath) else { return }
        let selectedPaths = Set(leftoverGroups.flatMap { group in
            group.items.filter { leftoverSelection.contains($0.id) }.map(\.id)
        })
        var byPath: [String: FileIdentity] = [:]
        for path in selectedPaths {
            if let identity = try? FileIdentity.read(at: URL(fileURLWithPath: path)) {
                byPath[path] = identity
            }
        }
        reviewSnapshot = ReviewSnapshot(
            bundleIdentity: bundleIdentity, leftoverIdentityByPath: byPath, selectedPaths: selectedPaths
        )
    }

    func discardRemovalReview() {
        reviewSnapshot = nil
    }

    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) {
        self.home = home
    }

    var visibleApps: [InstalledApp] {
        let filtered = UninstallLogic.filterApps(apps, query: searchQuery)
        return UninstallLogic.sortApps(
            filtered, field: sortField, ascending: sortAscending,
            sizeByPath: sizeByPath, lastUsedByPath: lastUsedByPath
        )
    }

    // MARK: - Loading

    func loadApps() {
        guard !isLoadingApps, apps.isEmpty else { return }
        isLoadingApps = true
        buildRootIndex()
        Task {
            let found = await Task.detached(priority: .userInitiated) {
                AppInventory.scan().sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            }.value
            apps = found
            isLoadingApps = false
            computeSizesAndUsage(for: found)
        }
    }

    /// Walk every leftover search root once, in the background, the moment the uninstaller opens,
    /// and keep the result. Selecting an app then matches against this cached index instead of
    /// re-walking `~/Library` each time — the difference between "instant" and a multi-second
    /// per-click stall. Runs in parallel with the app-inventory scan, so it is usually ready before
    /// the user has finished reading the app list.
    private func buildRootIndex() {
        rootIndexTask?.cancel()
        let home = self.home
        rootIndexTask = Task {
            let index = await Task.detached(priority: .userInitiated) {
                LeftoverRootIndex(homeDirectory: home)
            }.value
            guard !Task.isCancelled else { return }
            self.rootIndex = index
        }
        receiptsTask?.cancel()
        receiptsTask = Task {
            let receipts = await PrefetchedPkgutilReceipts.load()
            guard !Task.isCancelled else { return }
            self.receiptsCache = receipts
        }
    }

    private func computeSizesAndUsage(for apps: [InstalledApp]) {
        sizeTask?.cancel()
        sizeTask = Task {
            await withTaskGroup(of: (String, Int64, Date?).self) { group in
                for app in apps {
                    group.addTask(priority: .utility) {
                        (app.id, AppMetadataCalculator.allocatedSize(of: app), AppMetadataCalculator.lastUsedDate(of: app))
                    }
                }
                for await (id, size, lastUsed) in group {
                    guard !Task.isCancelled else { return }
                    sizeByPath[id] = size
                    if let lastUsed { lastUsedByPath[id] = lastUsed }
                }
            }
        }
    }

    func icon(for app: InstalledApp) -> NSImage {
        if let cached = iconByPath[app.id] { return cached }
        let image = NSWorkspace.shared.icon(forFile: app.bundlePath.path)
        iconByPath[app.id] = image
        return image
    }

    func isProtected(_ app: InstalledApp) -> Bool {
        UninstallLogic.isProtected(app, sweepBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    func isRunning(_ app: InstalledApp) -> Bool {
        RunningAppChecker.isRunning(app)
    }

    func quit(_ app: InstalledApp) {
        RunningAppChecker.quit(app)
    }

    // MARK: - Selection

    /// Refuses protected apps outright (PLAN §3 module 5: they "show a lock and refuse
    /// selection") — never even runs the matcher against one.
    func select(_ app: InstalledApp) {
        guard !isProtected(app) else {
            uninstallLog.notice("refused selection: \(app.bundleIdentifier ?? app.name, privacy: .public) is protected")
            return
        }
        selection = .app(app)
        uninstallLog.notice("selected \(app.bundleIdentifier ?? app.name, privacy: .public) at \(app.bundlePath.path, privacy: .public)")
        loadLeftovers(for: app)
    }

    /// Both drop routes (window `dropDestination` and the Dock/`application(_:open:)` fallback)
    /// land here through `AppState.openUninstaller(forDroppedAppAt:)`.
    func selectDroppedApp(at url: URL) {
        uninstallLog.notice("drop target resolving \(url.path, privacy: .public)")
        // `.path` string equality, never raw `URL ==`: a `URL` built from a plain path string
        // (this one) and one `FileManager.contentsOfDirectory` just enumerated (every entry
        // `AppInventory.scan` returns) can carry different directory-hint metadata for the exact
        // same location and compare unequal under `URL.==` even though both print an identical
        // `.path` — caught empirically (this build) testing this exact method against a real
        // `/Applications/Safari.app` symlink, where the two representations' `absoluteString`
        // differed only in a trailing slash.
        let standardizedPath = url.standardizedFileURL.path
        if let existing = apps.first(where: { $0.bundlePath.standardizedFileURL.path == standardizedPath }) {
            select(existing)
            return
        }
        // Not yet in the loaded inventory (dropped from outside the scanned roots, or the list
        // is still loading): read just this one bundle, the same way `AppInventory.scan` would.
        let scanned = AppInventory.scan(directories: [url.standardizedFileURL.deletingLastPathComponent()])
        guard let match = scanned.first(where: { $0.bundlePath.standardizedFileURL.path == standardizedPath }) else {
            uninstallLog.error("drop target could not resolve an app at \(url.path, privacy: .public)")
            return
        }
        if !apps.contains(match) {
            apps.append(match)
            apps.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            computeSizesAndUsage(for: [match])
        }
        select(match)
    }

    /// SmartDelete watcher's deep link: the app is already in the Trash, so this jumps straight
    /// to orphan-mode leftover matching for the bundle id it left behind.
    func selectOrphan(bundleIdentifier: String) {
        selection = .orphan(bundleIdentifier: bundleIdentifier)
        loadOrphanLeftovers(for: bundleIdentifier)
    }

    func clearSelection() {
        leftoverTask?.cancel()
        leftoverSizeTask?.cancel()
        selection = .none
        leftoverGroups = []
        leftoverSelection = InventorySelection()
        previewSheetShown = false
        // A snapshot never outlives the review it was captured for (Codex Gate-U adjudication:
        // this used to survive here and in finishRemoval). Harmless mid-removal — executeRemoval
        // copies the snapshot's values into the request at the click, before any await.
        discardRemovalReview()
    }

    private func loadLeftovers(for app: InstalledApp) {
        leftoverTask?.cancel()
        leftoverSizeTask?.cancel()
        isLoadingLeftovers = true
        leftoverGroups = []
        leftoverSelection = InventorySelection()
        leftoverSizeByID = [:]
        let installedApps = apps
        let home = self.home

        leftoverTask = Task {
            // A click that lands before the background prefetches finish WAITS for them —
            // never falls back to the slow per-click path (a fresh root walk, or one pkgutil
            // spawn per installed package). Both tasks are normally long done by now; awaiting
            // a finished task is free.
            await rootIndexTask?.value
            await receiptsTask?.value
            let index = self.rootIndex
            let receipts = self.receiptsCache ?? PrefetchedPkgutilReceipts.empty
            let candidates = await Task.detached(priority: .userInitiated) {
                LeftoverMatcher.candidates(for: app, homeDirectory: home, receipts: receipts, installedApps: installedApps, index: index)
            }.value
            guard !Task.isCancelled, case .app(let current) = selection, current == app else { return }
            let groups = LeftoverGrouping.groups(for: candidates, home: home)
            leftoverGroups = groups
            leftoverSelection = LeftoverGrouping.preselectedIDs(in: groups)
            leftoverExpansion = .initial(for: groups)
            isLoadingLeftovers = false
            computeLeftoverSizes(candidates: candidates, home: home)
        }
    }

    private func loadOrphanLeftovers(for bundleIdentifier: String) {
        leftoverTask?.cancel()
        leftoverSizeTask?.cancel()
        isLoadingLeftovers = true
        leftoverGroups = []
        leftoverSelection = InventorySelection()
        leftoverSizeByID = [:]
        let installedIDs = Set(apps.compactMap(\.bundleIdentifier))
        let home = self.home

        leftoverTask = Task {
            // Same wait-for-prefetch contract as `loadLeftovers(for:)`.
            await rootIndexTask?.value
            await receiptsTask?.value
            let index = self.rootIndex
            let receipts = self.receiptsCache ?? PrefetchedPkgutilReceipts.empty
            let allOrphans = await Task.detached(priority: .userInitiated) {
                LeftoverMatcher.orphanCandidates(installedBundleIDs: installedIDs, homeDirectory: home, receipts: receipts, index: index)
            }.value
            let matching = allOrphans.filter { candidate in
                BundleIDMatch.isExact(candidate.apparentBundleID, bundleID: bundleIdentifier)
                    || BundleIDMatch.isComponentPrefix(candidate.apparentBundleID, bundleID: bundleIdentifier)
                    || BundleIDMatch.isComponentPrefix(bundleIdentifier, bundleID: candidate.apparentBundleID)
            }
            guard !Task.isCancelled, case .orphan(let id) = selection, id == bundleIdentifier else { return }
            let group = LeftoverGrouping.orphanGroup(for: matching, home: home)
            leftoverGroups = group.map { [$0] } ?? []
            leftoverExpansion = .initial(for: leftoverGroups)
            isLoadingLeftovers = false
            computeOrphanLeftoverSizes(candidates: matching, home: home)
        }
    }

    private func computeLeftoverSizes(candidates: [LeftoverCandidate], home: URL) {
        leftoverSizeTask = Task {
            await withTaskGroup(of: (String, Int64).self) { group in
                for candidate in candidates {
                    group.addTask(priority: .utility) { (candidate.id, FileSizeCalculator.allocatedSize(at: candidate.url)) }
                }
                for await (id, size) in group {
                    guard !Task.isCancelled else { return }
                    leftoverSizeByID[id] = size
                }
            }
            guard !Task.isCancelled, case .app = selection else { return }
            leftoverGroups = LeftoverGrouping.groups(for: candidates, home: home, sizeByID: leftoverSizeByID)
        }
    }

    private func computeOrphanLeftoverSizes(candidates: [OrphanCandidate], home: URL) {
        leftoverSizeTask = Task {
            await withTaskGroup(of: (String, Int64).self) { group in
                for candidate in candidates {
                    group.addTask(priority: .utility) { (candidate.id, FileSizeCalculator.allocatedSize(at: candidate.url)) }
                }
                for await (id, size) in group {
                    guard !Task.isCancelled else { return }
                    leftoverSizeByID[id] = size
                }
            }
            guard !Task.isCancelled, case .orphan = selection else { return }
            leftoverGroups = LeftoverGrouping.orphanGroup(for: candidates, home: home, sizeByID: leftoverSizeByID).map { [$0] } ?? []
        }
    }

    // MARK: - Derived (removal preview)

    var selectedAppTotalBytes: Int64 {
        guard case .app(let app) = selection else { return 0 }
        return sizeByPath[app.id] ?? 0
    }

    var selectedLeftoverBytes: Int64 { leftoverSelection.selectedBytes(in: leftoverGroups) }
    var selectedLeftoverCount: Int { leftoverSelection.selectedCount(in: leftoverGroups) }

    func previewSummary() -> CleanRequestSummary {
        let bundleCount: Int
        switch selection {
        case .app: bundleCount = 1
        case .orphan, .none: bundleCount = 0
        }
        let selectedItems = leftoverGroups.flatMap(\.items).filter { leftoverSelection.contains($0.id) }
        return CleanRequestSummary(
            itemCount: bundleCount + selectedLeftoverCount,
            totalBytes: selectedAppTotalBytes + selectedLeftoverBytes,
            volumes: VolumeGrouping.volumes(for: selectedItems)
        )
    }
}

// MARK: - Gate U execution (the one place SweepApp calls SweepCore.UninstallService)

extension UninstallModel {
    /// Runs the removal the preview sheet just itemized. Captures reviewed identities HERE, at
    /// confirm time, from exactly the objects the sheet displayed (Codex Gate-U re-review
    /// blocker #1: consent binds device+inode, never path strings) — the service re-reads and
    /// refuses anything that changed in between.
    func executeRemoval() {
        guard case .app(let app) = selection, !isRemoving, canExecuteRemoval else { return }
        guard let bundleIdentifier = app.bundleIdentifier else { return }

        // The identities captured when the sheet APPEARED — never re-read here: re-reading at
        // click time would bless whatever occupies the paths now, which is exactly the timing
        // hole the re-review called out. The service re-verifies these against the live disk.
        guard let snapshot = reviewSnapshot else { return }
        let selectedPaths = snapshot.selectedPaths
        let bundleIdentity = snapshot.bundleIdentity
        let reviewedByPath = snapshot.leftoverIdentityByPath

        // Every selected path was individually rendered by the itemized preview sheet the user
        // just confirmed (Codex Gate-U re-review finding #4), so each carries an explicit
        // per-item confirmation — which the service only ever consults for paths whose
        // recomputed evidence needs one.
        let request = UninstallRequest(
            bundlePath: app.bundlePath,
            expectedBundleIdentifier: bundleIdentifier,
            reviewedBundleIdentity: bundleIdentity,
            selectedLeftoverPaths: selectedPaths,
            reviewedLeftoverIdentityByPath: reviewedByPath,
            manualOverrideConfirmedPaths: selectedPaths
        )

        isRemoving = true
        removalProgressCaption = "Preparing\u{2026}"
        Task {
            var outcomes: [SweepUI.CleanItemOutcome] = []
            var finished: SweepCore.CleanReport?
            do {
                for try await event in SweepCore.UninstallService.execute(request) {
                    switch event {
                    case .started(_, let itemCount):
                        removalProgressCaption = "Removing \(SweepFormat.itemCount(itemCount))\u{2026}"
                    case .itemCompleted(let outcome):
                        outcomes.append(Self.mapOutcome(outcome))
                        if let url = outcome.url {
                            removalProgressCaption = url.lastPathComponent
                        }
                    case .progress:
                        break
                    case .finished(let report):
                        finished = report
                    }
                }
            } catch {
                // A thrown stream is pre-mutation by contract now (post-mutation interruptions
                // finish with an uncommitted report instead of throwing) — but the copy still
                // refuses to claim knowledge it lacks.
                removalReport = SweepUI.CleanReport(
                    freedBytes: 0, succeededCount: 0,
                    outcomes: outcomes + [SweepUI.CleanItemOutcome(
                        id: app.bundlePath.path, title: app.name, byteCount: 0,
                        status: .failed(reason: "The removal did not complete: \(String(describing: error)). "
                            + "Check the Trash before retrying.")
                    )]
                )
                isRemoving = false
                removalProgressCaption = nil
                return
            }

            removalReport = Self.makeRemovalReport(finished: finished, streamed: outcomes)
            isRemoving = false
            removalProgressCaption = nil
        }
    }

    /// The displayed report is built from the finished report's own outcome list, not the
    /// streamed `itemCompleted` accumulation (Codex Gate-U adjudication: the interrupted-
    /// leftover-phase path filed its "items may already be in the Trash" warning only in the
    /// finished report, and a stream-built report silently dropped it). The stream stays as
    /// the fallback for a run that never produced a finished report at all.
    static func makeRemovalReport(
        finished: SweepCore.CleanReport?, streamed: [SweepUI.CleanItemOutcome]
    ) -> SweepUI.CleanReport {
        let outcomes = finished.map { $0.outcomes.map(mapOutcome) } ?? streamed
        let succeeded = outcomes.count { if case .succeeded = $0.status { true } else { false } }
        return SweepUI.CleanReport(
            freedBytes: finished?.freedBytesEstimate ?? 0,
            succeededCount: succeeded,
            outcomes: outcomes
        )
    }

    /// Closes the report and reloads the world it changed: the app list (the bundle is gone),
    /// the leftover panel, and the pre-walked root index (those trees just changed).
    func finishRemoval() {
        removalReport = nil
        previewSheetShown = false
        discardRemovalReview()
        clearSelection()
        // The bundle and its leftovers just left the disk: reload the app inventory from
        // scratch and rebuild the pre-walked root index + receipts cache against the new truth.
        apps = []
        loadApps()
    }

    private static func mapOutcome(_ outcome: SweepCore.CleanItemOutcome) -> SweepUI.CleanItemOutcome {
        let title = outcome.url?.lastPathComponent ?? outcome.id
        let status: SweepUI.CleanItemOutcome.Status
        switch outcome.outcome {
        case .succeeded:
            status = .succeeded
        default:
            status = .failed(reason: outcome.detail ?? outcome.failureReason.map(String.init(describing:)) ?? "Did not complete.")
        }
        return SweepUI.CleanItemOutcome(
            id: outcome.id, title: title, byteCount: outcome.allocatedSize, status: status
        )
    }
}
