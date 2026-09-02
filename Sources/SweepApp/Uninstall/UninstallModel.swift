import AppKit
import Foundation
import Observation
import OSLog
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

/// Drives the Uninstaller screen (PLAN §3 module 5, AppCleaner parity). Everything here is
/// read-only: `AppInventory`/`LeftoverMatcher` never write, and this model never calls
/// `SweepCore` — Gate U (a dedicated uninstall execution path) is next wave.
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
        let index = self.rootIndex

        leftoverTask = Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                LeftoverMatcher.candidates(for: app, homeDirectory: home, installedApps: installedApps, index: index)
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
        let index = self.rootIndex

        leftoverTask = Task {
            let allOrphans = await Task.detached(priority: .userInitiated) {
                LeftoverMatcher.orphanCandidates(installedBundleIDs: installedIDs, homeDirectory: home, index: index)
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
