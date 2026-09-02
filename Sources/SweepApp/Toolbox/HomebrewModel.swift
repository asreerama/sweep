import Foundation
import Observation
import SweepUI

enum HomebrewLoadState: Equatable {
    case idle
    case loading
    case unavailable
    case loaded
    case failed(String)
}

/// One command the screen has previewed and is waiting on the user to confirm or cancel.
///
/// Structural preview-first (PLAN §3 Toolbox contract + task spec "all preview-first"): there is
/// no code path in `HomebrewModel` that runs `cleanup`/`autoremove`/`upgrade` without first
/// constructing one of these from a real preview fetch — `confirmPendingAction()` only ever acts
/// on `pendingAction`, and the only place that gets set is after `previewText` has already come
/// back from the gateway.
struct HomebrewPendingAction: Identifiable {
    enum Kind {
        case cleanup
        case autoremove
        case upgrade(BrewPackage)
        case upgradeAll
        case uninstall(BrewPackage)
    }

    let id = UUID()
    let kind: Kind
    let title: String
    /// `brew cleanup --prune=all --dry-run` / `brew autoremove --dry-run`'s real stdout for
    /// cleanup/autoremove; the literal command line about to run for a per-item upgrade (brew has
    /// no upgrade dry-run, but the confirm sheet already states the exact version jump from data
    /// already on screen — see `HomebrewModel.requestUpgrade`).
    let previewText: String
}

/// Screen state for Homebrew (module 9, PLAN §3): a typed GUI over `brew`, read-mostly, every
/// mutation preview-first. Owns exactly one `BrewGateway` call at a time — `isRunningAction` is
/// true for the whole span of a mutating command, which is what keeps the confirm flow from ever
/// overlapping a second command underneath it.
@MainActor
@Observable
final class HomebrewModel {
    private(set) var loadState: HomebrewLoadState = .idle
    private(set) var snapshot: BrewSnapshot = .empty
    /// Raw stdout/stderr from every command this session has run, newest last — the "quiet
    /// console disclosure" the task spec asks for. Never cleared automatically: a failed cleanup
    /// from five minutes ago is still worth scrolling back to.
    private(set) var consoleLog = ""
    private(set) var isRunningAction = false

    var pendingAction: HomebrewPendingAction?
    /// True only once `pendingAction`'s preview text actually came back from the gateway — the
    /// confirm sheet's button stays disabled until then, so a slow preview fetch can never be
    /// raced into an unpreviewed confirm.
    private(set) var isPendingActionReady = false

    /// Live progress of an "Update all" run: which package is upgrading now and how many are done,
    /// so the screen shows a determinate bar that advances as each package finishes. `nil` when no
    /// batch upgrade is running.
    private(set) var upgradeAllProgress: UpgradeAllProgress?

    /// Packages with a per-item upgrade in flight, by `BrewPackage.id`. Deliberately NOT the
    /// exclusive `isRunningAction` machinery: one package upgrading must not lock the other rows'
    /// Upgrade buttons (user-reported), and brew's own per-keg locking makes parallel single
    /// upgrades safe — the worst case is one process briefly waiting on brew's internal lock.
    private(set) var upgradingPackageIDs: Set<String> = []

    struct UpgradeAllProgress: Equatable {
        var total: Int
        var completed: Int
        var current: String?
        var fraction: Double { total == 0 ? 0 : Double(completed) / Double(total) }
    }

    private let gateway: any BrewGateway

    init(gateway: any BrewGateway = HomebrewModel.defaultGateway()) {
        self.gateway = gateway
    }

    /// `SWEEP_TOOLBOX_BREW_FIXTURE=1` swaps in realistic static data (task spec: "fixture data
    /// acceptable for Homebrew if machine brew is slow") — same env-var-gated pattern as
    /// `SWEEP_UI_STRESS`/`SWEEP_HOME` elsewhere in this app, never engaged in a normal launch.
    static func defaultGateway() -> any BrewGateway {
        if ProcessInfo.processInfo.environment["SWEEP_TOOLBOX_BREW_FIXTURE"] != nil {
            return FixtureBrewGateway()
        }
        return RealBrewGateway()
    }

    var isAvailable: Bool { gateway.isAvailable }

    /// True while a re-fetch of an already-loaded listing is in flight. Separate from `loadState`
    /// on purpose: flipping `loadState` back to `.loading` after an upgrade blanked the whole
    /// listing to the "Checking Homebrew…" empty state for the duration of the re-snapshot
    /// (user-reported). A refresh over visible content keeps the stale listing on screen and swaps
    /// the new snapshot in place; only the first-ever load shows the empty loading state.
    private(set) var isRefreshing = false

    /// True while the concurrent per-package disk walk is still filling sizes in — the screen
    /// shows a size placeholder instead of a misleading "0 B" for exactly this span.
    private(set) var isSizing = false
    /// True while `brew outdated` is still deciding which rows get an "Update available" chip.
    private(set) var isCheckingUpdates = false

    /// Staged load (user-reported "the Homebrew listing is still slow — PearClean gets it
    /// instantly"): the old single-await refresh held the whole screen on a spinner for the
    /// full ~4.6 s snapshot. Now the filesystem listing renders in milliseconds, then the two
    /// slow reads — sizing and the update check — run concurrently and merge into the visible
    /// snapshot as each lands. Known sizes and update info from the previous snapshot are
    /// carried forward across a re-refresh so nothing on screen ever blanks or flickers back
    /// to a placeholder.
    func refresh() async {
        guard gateway.isAvailable else {
            loadState = .unavailable
            snapshot = .empty
            return
        }
        guard !isRefreshing else { return }
        let hadContent = loadState == .loaded
        if !hadContent { loadState = .loading }
        isRefreshing = true
        defer { isRefreshing = false }

        let listing: BrewSnapshot
        do {
            listing = try await gateway.listing()
        } catch {
            // A background refresh of a listing the user is looking at must not blank it either:
            // keep the stale content, surface the failure in the console.
            if hadContent {
                appendConsole("Refresh failed: \(String(describing: error))")
            } else {
                loadState = .failed(String(describing: error))
            }
            return
        }
        snapshot = Self.merged(listing: listing, carryingForwardFrom: snapshot)
        loadState = .loaded

        isSizing = true
        isCheckingUpdates = true
        async let pendingSizes = gateway.sizes(for: listing.packages)
        async let pendingCheck = gateway.updateCheck()

        snapshot = Self.applying(sizes: await pendingSizes, to: snapshot)
        isSizing = false

        do {
            snapshot = Self.applying(check: try await pendingCheck, to: snapshot)
        } catch {
            appendConsole("Update check failed: \(String(describing: error))")
        }
        isCheckingUpdates = false
    }

    // MARK: - Staged-snapshot merging (internal, unit-tested directly)

    /// Phase 1: the fresh filesystem listing over whatever the screen already knows. Sizes and
    /// update info carry forward by package id so a re-refresh never regresses visible data —
    /// with one guard: carried update info goes stale the moment the on-disk version catches up
    /// to it, so a package upgraded seconds ago must not keep its "Update available" chip while
    /// the fresh `brew outdated` is still in flight.
    static func merged(listing: BrewSnapshot, carryingForwardFrom old: BrewSnapshot) -> BrewSnapshot {
        let oldByID = Dictionary(old.packages.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let packages = listing.packages.map { fresh -> BrewPackage in
            guard let prior = oldByID[fresh.id] else { return fresh }
            let installed = fresh.installedVersion ?? prior.installedVersion
            let latest = prior.latestVersion == installed ? nil : prior.latestVersion
            return BrewPackage(
                id: fresh.id, name: fresh.name, isCask: fresh.isCask,
                installedVersion: installed, latestVersion: latest, sizeBytes: prior.sizeBytes
            )
        }
        return BrewSnapshot(packages: packages, cache: old.cache, prefix: listing.prefix)
    }

    /// Phase 2: fresh disk sizes by package id; a package the walk did not size keeps what it had.
    static func applying(sizes: [String: Int64], to snapshot: BrewSnapshot) -> BrewSnapshot {
        BrewSnapshot(
            packages: snapshot.packages.map { package in
                guard let bytes = sizes[package.id] else { return package }
                return BrewPackage(
                    id: package.id, name: package.name, isCask: package.isCask,
                    installedVersion: package.installedVersion, latestVersion: package.latestVersion,
                    sizeBytes: bytes
                )
            },
            cache: snapshot.cache, prefix: snapshot.prefix
        )
    }

    /// Phase 3: `brew outdated`'s verdict replaces any carried update info wholesale — a package
    /// absent from the response is up to date, clearing stale carried chips.
    static func applying(check: BrewUpdateCheck, to snapshot: BrewSnapshot) -> BrewSnapshot {
        let formulaByName = Dictionary(check.outdated.formulae.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let caskByName = Dictionary(check.outdated.casks.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        let packages = snapshot.packages.map { package -> BrewPackage in
            let entry = (package.isCask ? caskByName : formulaByName)[package.name]
            return BrewPackage(
                id: package.id, name: package.name, isCask: package.isCask,
                installedVersion: entry?.installedVersions.last ?? package.installedVersion,
                latestVersion: entry.map(\.currentVersion),
                sizeBytes: package.sizeBytes
            )
        }
        return BrewSnapshot(packages: packages, cache: check.cache ?? snapshot.cache, prefix: snapshot.prefix)
    }

    // MARK: - Preview-first actions

    func requestCleanup() {
        beginPreview(kind: .cleanup, title: "Clean Homebrew Cache")
        Task { await loadPreview(kind: .cleanup, title: "Clean Homebrew Cache") {
            try await self.gateway.cleanupPreview()
        } }
    }

    func requestAutoremove() {
        beginPreview(kind: .autoremove, title: "Remove Unused Dependencies")
        Task { await loadPreview(kind: .autoremove, title: "Remove Unused Dependencies") {
            try await self.gateway.autoremovePreview()
        } }
    }

    /// No `brew upgrade --dry-run` exists, so there is nothing to fetch here — but the sheet is
    /// still shown before anything runs, and its content (the exact version jump) is data this
    /// screen already has on hand from the last refresh, which is what "preview" means for this
    /// one action.
    func requestUpgrade(_ package: BrewPackage) {
        let jump = package.latestVersion.map { "\(package.installedVersion ?? "current") \u{2192} \($0)" }
            ?? "the latest version"
        let command = "brew upgrade \(package.isCask ? "--cask " : "")\(package.name)"
        pendingAction = HomebrewPendingAction(
            kind: .upgrade(package),
            title: "Upgrade \(package.name)",
            previewText: "Will upgrade \(package.name): \(jump)\n\n\(command)"
        )
        isPendingActionReady = true
    }

    /// The trash icon's confirmation: what will be removed, how big it is, and the exact command —
    /// shown before anything runs, same preview-first contract as every other mutation. Content is
    /// data already on hand, so the sheet is ready immediately.
    func requestUninstall(_ package: BrewPackage) {
        let kindNoun = package.isCask ? "Mac app" : "command-line tool"
        let version = package.installedVersion.map { " \($0)" } ?? ""
        let command = "brew uninstall \(package.isCask ? "--cask " : "")\(package.name)"
        pendingAction = HomebrewPendingAction(
            kind: .uninstall(package),
            title: "Uninstall \(package.name)",
            previewText: "Will completely remove \(package.name)\(version) — a \(kindNoun) taking "
                + "\(SweepFormat.bytes(package.sizeBytes)) on disk. Homebrew can reinstall it later, "
                + "but its settings and data may not survive.\n\n\(command)"
        )
        isPendingActionReady = true
    }

    /// Preview-first, same contract as the others: show exactly which packages will upgrade (data
    /// already on hand from the last refresh) before anything runs. The batch upgrades one package
    /// at a time so the screen can report live per-package progress.
    func requestUpgradeAll() {
        let outdated = snapshot.outdated
        guard !outdated.isEmpty, upgradingPackageIDs.isEmpty else { return }
        let lines = outdated.map { package -> String in
            let jump = package.latestVersion.map { "\(package.installedVersion ?? "current") \u{2192} \($0)" } ?? "latest"
            return "\u{2022} \(package.name)  (\(jump))"
        }.joined(separator: "\n")
        let noun = outdated.count == 1 ? "package" : "packages"
        pendingAction = HomebrewPendingAction(
            kind: .upgradeAll,
            title: "Update All (\(outdated.count))",
            previewText: "Will upgrade \(outdated.count) \(noun), one at a time:\n\n\(lines)"
        )
        isPendingActionReady = true
    }

    /// Sets the "Checking…" placeholder synchronously, before the async fetch even starts, so
    /// the confirm sheet appears the instant the user taps Cleanup/Autoremove rather than after a
    /// runloop hop — and so a caller that checks `pendingAction` right after calling
    /// `requestCleanup()`/`requestAutoremove()` (this screen's own `.sheet(item:)`, and
    /// `HomebrewModelTests`) never observes a window where nothing is pending yet.
    private func beginPreview(kind: HomebrewPendingAction.Kind, title: String) {
        pendingAction = HomebrewPendingAction(kind: kind, title: title, previewText: "Checking\u{2026}")
        isPendingActionReady = false
    }

    private func loadPreview(kind: HomebrewPendingAction.Kind, title: String, fetch: () async throws -> String) async {
        do {
            let text = try await fetch()
            // A rescan/cancel could have raced ahead while the preview was in flight; only apply
            // it if the user is still looking at the same pending action.
            guard pendingAction?.kind.matches(kind) == true else { return }
            pendingAction = HomebrewPendingAction(kind: kind, title: title, previewText: text)
            isPendingActionReady = true
        } catch {
            guard pendingAction?.kind.matches(kind) == true else { return }
            pendingAction = nil
            appendConsole("\(title) preview failed: \(String(describing: error))")
        }
    }

    func cancelPendingAction() {
        pendingAction = nil
        isPendingActionReady = false
    }

    func confirmPendingAction() {
        guard let action = pendingAction, isPendingActionReady else { return }
        // Per-item upgrades run outside the exclusive-action machinery so several can be in
        // flight at once and the rest of the screen stays usable.
        if case .upgrade(let package) = action.kind {
            pendingAction = nil
            isPendingActionReady = false
            runItemUpgrade(package)
            return
        }
        guard !isRunningAction else { return }
        pendingAction = nil
        isPendingActionReady = false
        isRunningAction = true
        Task {
            if case .upgradeAll = action.kind {
                await runUpgradeAll()
            } else {
                await runSingle(action)
            }
            isRunningAction = false
            await refresh()
        }
    }

    /// One package's upgrade, tracked per row (`upgradingPackageIDs`) rather than through
    /// `isRunningAction`. The snapshot refresh waits for the *last* in-flight upgrade to land so
    /// parallel upgrades don't thrash the package list mid-run.
    private func runItemUpgrade(_ package: BrewPackage) {
        guard !upgradingPackageIDs.contains(package.id) else { return }
        upgradingPackageIDs.insert(package.id)
        Task {
            do {
                let output = try await gateway.upgrade(package)
                appendConsole("$ brew upgrade \(package.name)\n\(output.isEmpty ? "(no output)" : output)")
            } catch {
                appendConsole("$ brew upgrade \(package.name)\n\(String(describing: error))")
            }
            upgradingPackageIDs.remove(package.id)
            if upgradingPackageIDs.isEmpty, !isRunningAction {
                await refresh()
            }
        }
    }

    private func runSingle(_ action: HomebrewPendingAction) async {
        do {
            let output: String
            switch action.kind {
            case .cleanup: output = try await gateway.cleanup()
            case .autoremove: output = try await gateway.autoremove()
            case .upgrade(let package): output = try await gateway.upgrade(package)
            case .uninstall(let package): output = try await gateway.uninstall(package)
            case .upgradeAll: return
            }
            appendConsole("$ \(action.title)\n\(output.isEmpty ? "(no output)" : output)")
        } catch {
            appendConsole("$ \(action.title)\n\(String(describing: error))")
        }
    }

    /// Upgrades every outdated package sequentially, publishing progress after each one so the
    /// screen's bar advances live. One package failing never aborts the batch — its error goes to
    /// the console and the run moves on.
    private func runUpgradeAll() async {
        let outdated = snapshot.outdated
        upgradeAllProgress = UpgradeAllProgress(total: outdated.count, completed: 0, current: nil)
        for package in outdated {
            upgradeAllProgress?.current = package.name
            do {
                let output = try await gateway.upgrade(package)
                appendConsole("$ brew upgrade \(package.name)\n\(output.isEmpty ? "(no output)" : output)")
            } catch {
                appendConsole("$ brew upgrade \(package.name)\n\(String(describing: error))")
            }
            upgradeAllProgress?.completed += 1
        }
        upgradeAllProgress = nil
    }

    private func appendConsole(_ text: String) {
        consoleLog = consoleLog.isEmpty ? text : consoleLog + "\n\n" + text
    }
}

extension HomebrewPendingAction.Kind {
    /// Same-action identity check (cleanup/autoremove are singletons; an upgrade matches only the
    /// same package) — used to guard a preview fetch that raced against the user cancelling or
    /// requesting a different action while it was in flight.
    func matches(_ other: HomebrewPendingAction.Kind) -> Bool {
        switch (self, other) {
        case (.cleanup, .cleanup), (.autoremove, .autoremove), (.upgradeAll, .upgradeAll): true
        case (.upgrade(let lhs), .upgrade(let rhs)): lhs.id == rhs.id
        case (.uninstall(let lhs), .uninstall(let rhs)): lhs.id == rhs.id
        default: false
        }
    }
}
