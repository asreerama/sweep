import Foundation
import SweepCore
import SweepPolicy
import SweepUI

/// A root, or a subtree, the scan could not read. Reported in a footnote rather than swallowed:
/// without Full Disk Access a good share of `~/Library` is invisible, and a cleaner that hides
/// that is lying about the number it just printed.
struct SkippedLocation: Sendable, Hashable, Identifiable {
    enum Reason: Sendable, Hashable {
        case unreadable
        case rootUnavailable
        case otherVolume
        case policyDenied

        var summary: String {
            switch self {
            case .unreadable: "no permission"
            case .rootUnavailable: "unavailable"
            case .otherVolume: "another volume"
            case .policyDenied: "protected"
            }
        }
    }

    let path: String
    let reason: Reason
    var id: String { "\(reason)\u{1}\(path)" }
}

/// Live readout while a walk is running.
struct ScanTick: Sendable {
    let sequence: Int
    let claimedBytes: Int64
    let filesExamined: Int
    let claimedFiles: Int
    let currentPath: String?
}

struct ScanOutcome: Sendable {
    /// One row per rule group: what Smart Scan shows.
    let summaryGroups: [InventoryGroup]
    /// One section per rule, rows are the matched nodes: what System Junk shows.
    let ruleGroups: [InventoryGroup]
    let claimedBytes: Int64
    let claimedFiles: Int
    let filesExamined: Int
    let skipped: [SkippedLocation]
    let duration: TimeInterval
    let cancelled: Bool

    /// The catalog this scan ran against — retained so a later Clean request can be
    /// re-authorized by `CleanAdapter.swift` against the exact rules that produced these items,
    /// never a catalog re-read from disk that might have changed underneath the scan.
    let catalog: RuleCatalog
    /// `InventoryItem.id` → the identity captured for that exact node, never a descendant's
    /// (Codex G1 finding #6, NOT-CLOSED). Threaded through `ScanModel.cleanExecutionContext()` so
    /// `CleanAdapter` can bind its depth-1 rescan candidate to the reviewed object by device+inode
    /// instead of trusting whatever now occupies the same pathname.
    let reviewedIdentityByItemID: [String: FileIdentity]

    static let empty = ScanOutcome(
        summaryGroups: [], ruleGroups: [], claimedBytes: 0, claimedFiles: 0,
        filesExamined: 0, skipped: [], duration: 0, cancelled: false,
        catalog: RuleCatalog(schemaVersion: RuleCatalog.supportedSchemaVersion, rules: []),
        reviewedIdentityByItemID: [:]
    )
}

enum ScanServiceError: Error, CustomStringConvertible {
    case noCatalog
    case catalogUnreadable(String)

    var description: String {
        switch self {
        case .noCatalog:
            "No rule catalog found. Set SWEEP_RULES to a catalog.json, or build the app bundle with scripts/build-app.sh."
        case .catalogUnreadable(let reason):
            "Rule catalog rejected: \(reason)"
        }
    }
}

/// Read-only scan driver.
///
/// Everything here is `nonisolated`, so it runs on the cooperative pool and never on the main
/// actor; the caller gets throttled ticks and one final outcome. Nothing in this file imports
/// `DeletionCoordinator` or `FixtureExecution`, and nothing in it writes to the filesystem —
/// M2 is read-only by construction, not by discipline.
enum ScanService {

    static func loadCatalog(at url: URL?) throws -> RuleCatalog {
        guard let url else { throw ScanServiceError.noCatalog }
        do {
            return try RuleCatalogLoader.load(contentsOf: url)
        } catch {
            throw ScanServiceError.catalogUnreadable(String(describing: error))
        }
    }

    /// One resolved directory to walk, with the rules that can claim anything inside it.
    private struct Unit {
        let root: SweepPolicy.OperationRoot
        let url: URL
        /// Deepest a pattern under this root can reach. Patterns carry no `**` in the frozen
        /// schema's catalog, so a pattern of N components can only ever match a relative path
        /// of exactly N components: everything below that depth is claimed by an ancestor and
        /// needs no rule evaluation at all.
        let maximumPatternDepth: Int
    }

    static func run(
        catalog: RuleCatalog,
        home: URL,
        onTick: @Sendable @escaping (ScanTick) -> Void
    ) async -> ScanOutcome {
        let started = Date()
        let units = buildUnits(catalog: catalog, home: home)
        let engine = ScanEngine()
        let displayHome = FileManager.default.homeDirectoryForCurrentUser.path

        var nodes: [NodeKey: Node] = [:]
        var seenInodes = Set<InodeKey>()
        var skipped: [SkippedLocation] = []
        var claimedBytes: Int64 = 0
        var claimedFiles = 0
        var filesExamined = 0
        var sequence = 0
        var lastEmit = ContinuousClock.now
        var cancelled = false

        // ~25 Hz. Enough that the counter never looks stepped, few enough that the main actor
        // is not the bottleneck of a 200,000-file walk.
        let tickInterval = Duration.milliseconds(40)

        for unit in units {
            if Task.isCancelled { cancelled = true; break }

            var decisionCache: [String: PrefixOutcome] = [:]
            let rootPrefix = unit.url.path.hasSuffix("/") ? unit.url.path : unit.url.path + "/"
            let request = ScanRequest(
                roots: [unit.url],
                honorsPolicyDenylist: true,
                progressInterval: 512
            )

            do {
                for try await event in await engine.scan(request) {
                    if Task.isCancelled { cancelled = true; break }
                    switch event {
                    case .started:
                        break

                    case .progress(let progress):
                        let now = ContinuousClock.now
                        if now - lastEmit >= tickInterval {
                            lastEmit = now
                            sequence += 1
                            onTick(ScanTick(
                                sequence: sequence,
                                claimedBytes: claimedBytes,
                                filesExamined: filesExamined,
                                claimedFiles: claimedFiles,
                                currentPath: progress.currentPath.map {
                                    SweepFormat.abbreviatingHome($0, home: displayHome)
                                }
                            ))
                        }

                    case .candidate(let candidate):
                        let isFile = candidate.identity.kind == .file
                        if isFile { filesExamined += 1 }

                        guard let relative = relativePath(of: candidate.url.path, under: rootPrefix) else {
                            continue
                        }
                        guard let claim = claim(
                            relative: relative,
                            kind: candidate.identity.kind,
                            unit: unit,
                            catalog: catalog,
                            cache: &decisionCache
                        ) else { continue }

                        if claim.rule.minAgeDays > 0 {
                            let cutoff = Date().addingTimeInterval(-Double(claim.rule.minAgeDays) * 86_400)
                            if candidate.identity.modification.date > cutoff { continue }
                        }

                        let key = NodeKey(rootPath: unit.url.path, relativePath: claim.node)
                        if nodes[key] == nil {
                            nodes[key] = Node(
                                path: unit.url.appending(path: claim.node).path,
                                name: (claim.node as NSString).lastPathComponent,
                                rule: claim.rule,
                                root: unit.root
                            )
                        }
                        // Codex G1 finding #6: capture the node's *own* identity: the candidate
                        // event whose relative path exactly equals the claimed node, whether that
                        // is a leaf-level file match or an ancestor directory the walk visits
                        // separately from its descendants, never a descendant's or a sibling's.
                        if relative == claim.node {
                            nodes[key]?.identity = candidate.identity
                        }

                        // Bytes are per inode, once. A hard link seen twice is one file's worth
                        // of disk, and an APFS clone family is charged to whoever is walked first.
                        guard isFile else { continue }
                        let inode = InodeKey(device: candidate.identity.deviceID, inode: candidate.identity.inode)
                        guard seenInodes.insert(inode).inserted else { continue }
                        nodes[key]?.bytes += candidate.allocatedSize
                        nodes[key]?.fileCount += 1
                        claimedBytes += candidate.allocatedSize
                        claimedFiles += 1

                    case .finished(let summary):
                        if summary.cancelled { cancelled = true }
                        skipped.append(contentsOf: summary.issues.compactMap(skippedLocation))
                    }
                }
            } catch let error as ScanError {
                if case .rootUnavailable(let url, _) = error {
                    skipped.append(SkippedLocation(path: url.path, reason: .rootUnavailable))
                } else {
                    skipped.append(SkippedLocation(path: unit.url.path, reason: .unreadable))
                }
            } catch is CancellationError {
                cancelled = true
            } catch {
                skipped.append(SkippedLocation(path: unit.url.path, reason: .unreadable))
            }
        }

        // Abbreviate against the *real* account home as well as the injected scan home: several
        // operation roots come from `FileManager` rather than the home argument, so a fixture
        // run still surfaces some real paths and both spellings should read as `~/…`.
        let built = buildGroups(nodes: Array(nodes.values), homes: [home.path, displayHome])
        return ScanOutcome(
            summaryGroups: built.summary,
            ruleGroups: built.byRule,
            claimedBytes: claimedBytes,
            claimedFiles: claimedFiles,
            filesExamined: filesExamined,
            skipped: dedupeSkipped(skipped),
            duration: Date().timeIntervalSince(started),
            cancelled: cancelled,
            catalog: catalog,
            reviewedIdentityByItemID: built.identityByItemID
        )
    }

    // MARK: - Units

    private static func buildUnits(catalog: RuleCatalog, home: URL) -> [Unit] {
        // `commandPreview` rules describe a typed command adapter, not a tree to enumerate;
        // walking their roots would be pure cost. That also keeps the helper-only system roots
        // (`/Library/Caches`, `/var/log`) out of an unprivileged read-only scan.
        let walkable = catalog.rules.filter { $0.action != .commandPreview }
        var units: [Unit] = []
        for root in Set(walkable.map(\.root)) {
            let depth = walkable
                .filter { $0.root == root }
                .map { patternDepth($0.pattern) }
                .max() ?? 1
            for resolved in SweepPolicy.resolvedRoots(for: root, home: home) {
                units.append(Unit(root: root, url: resolved.url, maximumPatternDepth: depth))
            }
        }
        // Deepest path first. `browserCaches` lives inside `userCaches`; walking the narrower
        // root first means Chrome's bytes are charged to the Chrome rule, and inode dedup keeps
        // the broader rule from counting them a second time.
        return units.sorted { $0.url.path.count > $1.url.path.count }
    }

    private static func patternDepth(_ pattern: String) -> Int {
        let components = pattern.split(separator: "/", omittingEmptySubsequences: true)
        if components.contains("**") { return Int.max }
        return max(1, components.count)
    }

    // MARK: - Attribution

    private enum PrefixOutcome {
        case denied
        case noMatch
        case matched(Rule)
    }

    private struct Claim {
        let rule: Rule
        /// Relative path of the node the rule claimed — the unit a user would select and, one
        /// day, delete. Everything below it is charged to it.
        let node: String
    }

    /// Deepest rule wins.
    ///
    /// A file at `pip/http/abc` is under `*` (all user caches) and under `pip/*` (the pip
    /// cache). Charging it to the shallower rule would fold every dev-tool cache into one
    /// undifferentiated "User Application Caches" blob, so the most specific rule that claims
    /// any prefix of the path takes it. An exclusion at any depth removes the item outright:
    /// deny-wins, same as `RuleCatalog.decision`.
    private static func claim(
        relative: String,
        kind: FileKind,
        unit: Unit,
        catalog: RuleCatalog,
        cache: inout [String: PrefixOutcome]
    ) -> Claim? {
        let components = relative.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty else { return nil }
        let reach = min(components.count, unit.maximumPatternDepth)

        var winner: Claim?
        var prefix = ""
        for index in 0..<reach {
            prefix = index == 0 ? String(components[index]) : prefix + "/" + components[index]
            let isLeaf = index == components.count - 1
            let itemType: RuleItemType = isLeaf ? (kind == .directory ? .directory : .file) : .directory

            let outcome: PrefixOutcome
            if itemType == .directory, let cached = cache[prefix] {
                outcome = cached
            } else {
                outcome = decide(prefix, itemType, unit.root, catalog)
                if itemType == .directory { cache[prefix] = outcome }
            }

            switch outcome {
            case .denied: return nil
            case .noMatch: continue
            case .matched(let rule): winner = Claim(rule: rule, node: prefix)
            }
        }
        return winner
    }

    private static func decide(
        _ relative: String,
        _ itemType: RuleItemType,
        _ root: SweepPolicy.OperationRoot,
        _ catalog: RuleCatalog
    ) -> PrefixOutcome {
        switch catalog.decision(forRelativePath: relative, root: root, itemType: itemType) {
        case .denied: .denied
        case .noMatch: .noMatch
        case .matched(let rule): .matched(rule)
        }
    }

    private static func relativePath(of path: String, under rootPrefix: String) -> String? {
        guard path.hasPrefix(rootPrefix) else { return nil }
        let relative = String(path.dropFirst(rootPrefix.count))
        return relative.isEmpty ? nil : relative
    }

    // MARK: - Grouping

    private struct NodeKey: Hashable {
        let rootPath: String
        let relativePath: String
    }

    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Node {
        let path: String
        let name: String
        let rule: Rule
        let root: SweepPolicy.OperationRoot
        var bytes: Int64 = 0
        var fileCount: Int = 0
        /// The node's own identity (Codex G1 finding #6), captured when the walk visits the
        /// node's own path directly. `nil` only if that never happened (e.g. a permission error
        /// on the node itself); such a node is excluded from `identityByItemID` and a later Clean
        /// request for it fails closed for lack of a reviewed identity to bind to.
        var identity: FileIdentity?
    }

    private static func buildGroups(
        nodes: [Node],
        homes: [String]
    ) -> (summary: [InventoryGroup], byRule: [InventoryGroup], identityByItemID: [String: FileIdentity]) {
        // Empty nodes are directories a rule claimed that turned out to hold nothing. They are
        // true, and they are noise; a scan result listing 400 zero-byte caches buries the four
        // that matter.
        let populated = nodes.filter { $0.bytes > 0 }

        var itemsByRule: [String: [InventoryItem]] = [:]
        var ruleByID: [String: Rule] = [:]
        var itemsByGroup: [RuleGroup: [InventoryItem]] = [:]
        var identityByItemID: [String: FileIdentity] = [:]

        for node in populated.sorted(by: { $0.bytes > $1.bytes }) {
            let item = InventoryItem(
                id: node.path,
                title: node.name,
                detail: homes.reduce(node.path) { SweepFormat.abbreviatingHome($0, home: $1) },
                symbol: symbol(for: node.root),
                byteCount: node.bytes,
                tier: tier(node.rule.tier)
            )
            itemsByRule[node.rule.id, default: []].append(item)
            ruleByID[node.rule.id] = node.rule
            itemsByGroup[node.rule.group, default: []].append(item)
            if let identity = node.identity {
                identityByItemID[node.path] = identity
            }
        }

        let byRule = itemsByRule
            .compactMap { id, items -> InventoryGroup? in
                guard let rule = ruleByID[id] else { return nil }
                return InventoryGroup(id: id, title: rule.title, symbol: symbol(for: rule.root), items: items)
            }
            .sorted { $0.byteCount > $1.byteCount }

        let summary = itemsByGroup
            .map { group, items in
                InventoryGroup(id: group.rawValue, title: displayName(group), symbol: symbol(for: group), items: items)
            }
            .sorted { $0.byteCount > $1.byteCount }

        return (summary, byRule, identityByItemID)
    }

    private static func dedupeSkipped(_ skipped: [SkippedLocation]) -> [SkippedLocation] {
        var seen = Set<String>()
        return skipped.filter { seen.insert($0.id).inserted }
    }

    private static func skippedLocation(_ issue: WalkIssue) -> SkippedLocation? {
        switch issue.reason {
        case .unreadable, .identityUnavailable: SkippedLocation(path: issue.url.path, reason: .unreadable)
        case .volumeBoundary: SkippedLocation(path: issue.url.path, reason: .otherVolume)
        case .policyDenied: SkippedLocation(path: issue.url.path, reason: .policyDenied)
        }
    }

    // MARK: - Core → UI vocabulary

    static func tier(_ tier: Tier) -> SweepTier {
        switch tier {
        case .safe: .safe
        case .caution: .caution
        case .expert: .expert
        }
    }

    static func displayName(_ group: RuleGroup) -> String {
        switch group {
        case .systemJunk: "System Junk"
        case .developer: "Developer"
        case .homebrew: "Homebrew"
        case .largeFiles: "Large & Old Files"
        case .uninstall: "Uninstaller"
        case .maintenance: "Maintenance"
        }
    }

    /// Plain-language line under a Smart Scan category row (PLAN §5 volume-raise) — what this
    /// category actually is, not the rule-engine name for it. One per `RuleGroup`, since that is
    /// the granularity Smart Scan's summary shows; a per-app line ("Spotify's temporary files")
    /// would need copy for every rule in the catalog, which lives in SweepCore, not here.
    static func friendlySubtitle(for group: RuleGroup) -> String {
        switch group {
        case .systemJunk: "Caches, logs and crash reports quietly piling up in the background."
        case .developer: "Old build output and simulator data Xcode never clears on its own."
        case .homebrew: "Downloaded formula and cask archives left behind after installing."
        case .largeFiles: "Big, old files taking up space you've probably forgotten about."
        case .uninstall: "Leftovers from apps that are already gone."
        case .maintenance: "Small housekeeping tasks that keep things running smoothly."
        }
    }

    /// `group.id` for a Smart Scan summary group is the `RuleGroup`'s raw value (`buildGroups`,
    /// below) — this is the lookup a screen actually has in hand.
    static func friendlySubtitle(forSummaryGroupID id: String) -> String? {
        RuleGroup(rawValue: id).map(friendlySubtitle(for:))
    }

    static func symbol(for group: RuleGroup) -> String {
        switch group {
        case .systemJunk: "trash"
        case .developer: "hammer"
        case .homebrew: "mug"
        case .largeFiles: "doc.zipper"
        case .uninstall: "xmark.bin"
        case .maintenance: "wrench.and.screwdriver"
        }
    }

    static func symbol(for root: SweepPolicy.OperationRoot) -> String {
        switch root {
        case .userCaches, .sandboxedAppCaches, .systemCaches: "shippingbox"
        case .userLogs, .systemLogs: "doc.text"
        case .crashReports: "exclamationmark.triangle"
        case .xcodeDerivedData, .xcodeDeviceSupport, .developerToolCaches: "hammer"
        case .homebrewCache: "mug"
        case .browserCaches: "safari"
        case .trash: "trash"
        }
    }
}
