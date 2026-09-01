import Foundation
import SweepUI

/// The Developer screen's lens over the rule catalog's `developer` group (PLAN §3 module 10):
/// "per-environment groups... Same rules engine underneath as System Junk, different lens."
///
/// `ScanService`/`ScanEngine` already produce one `InventoryGroup` per matched *rule*
/// (`DeveloperScanModel` runs that exact pipeline, scoped to `RuleGroup.developer`). This file
/// is the "different lens": a fixed, hand-authored map from rule id to the human tool/environment
/// it belongs to, so five VS Code cache rules collapse into one "Visual Studio Code" section
/// instead of five near-identical rows a user has to mentally merge themselves.
///
/// Pure data, pure functions — no filesystem, no `SweepCore` — so the mapping is testable without
/// a scan (see `Tests/SweepAppTests/DeveloperEnvironmentTests.swift`).
struct DeveloperEnvironmentDefinition: Identifiable, Sendable {
    let id: String
    let title: String
    let symbol: String
    /// Rule ids this environment collapses. Order doesn't matter for grouping; it does for the
    /// catalog-coverage test's readability.
    let ruleIDs: [String]
}

enum DeveloperEnvironmentCatalog {

    /// One entry per dev tool/environment the current `rules/catalog.json` `developer` group
    /// knows about. A rule id that stops existing simply stops contributing (an environment with
    /// nothing installed hides — see `buildGroups` below); a *new* developer rule that forgets to
    /// land here is caught by `DeveloperEnvironmentTests.testEveryDeveloperRuleHasAnEnvironment`,
    /// not silently dropped in production.
    static let definitions: [DeveloperEnvironmentDefinition] = [
        DeveloperEnvironmentDefinition(id: "node", title: "Node.js", symbol: "terminal", ruleIDs: ["npm-cache"]),
        DeveloperEnvironmentDefinition(id: "yarn", title: "Yarn", symbol: "shippingbox", ruleIDs: ["yarn-cache"]),
        DeveloperEnvironmentDefinition(id: "deno", title: "Deno", symbol: "bolt", ruleIDs: ["deno-cache"]),
        DeveloperEnvironmentDefinition(
            id: "python", title: "Python", symbol: "chevron.left.forwardslash.chevron.right",
            ruleIDs: ["pip-cache", "poetry-cache"]
        ),
        DeveloperEnvironmentDefinition(id: "uv", title: "uv", symbol: "bolt.circle", ruleIDs: ["uv-cache"]),
        DeveloperEnvironmentDefinition(
            id: "gradle", title: "Gradle", symbol: "hammer", ruleIDs: ["gradle-cache", "gradle-wrapper"]
        ),
        DeveloperEnvironmentDefinition(
            id: "android-studio", title: "Android Studio", symbol: "cube.box", ruleIDs: ["android-studio-cache"]
        ),
        DeveloperEnvironmentDefinition(
            id: "jetbrains", title: "JetBrains IDEs", symbol: "cube",
            ruleIDs: ["jetbrains-ide-cache", "jetbrains-ide-logs"]
        ),
        DeveloperEnvironmentDefinition(
            id: "vscode", title: "Visual Studio Code", symbol: "curlybraces",
            ruleIDs: ["vscode-cache", "vscode-gpucache", "vscode-cached-data", "vscode-cached-extensions"]
        ),
        DeveloperEnvironmentDefinition(
            id: "cursor", title: "Cursor", symbol: "cursorarrow.rays",
            ruleIDs: ["cursor-cache", "cursor-gpucache", "cursor-cached-data"]
        ),
        DeveloperEnvironmentDefinition(id: "zed", title: "Zed", symbol: "bolt.fill", ruleIDs: ["zed-cache"]),
        DeveloperEnvironmentDefinition(
            id: "cocoapods", title: "CocoaPods", symbol: "shippingbox.fill", ruleIDs: ["cocoapods-cache"]
        ),
        DeveloperEnvironmentDefinition(id: "carthage", title: "Carthage", symbol: "archivebox", ruleIDs: ["carthage-cache"]),
        DeveloperEnvironmentDefinition(
            id: "composer", title: "Composer (PHP)", symbol: "puzzlepiece", ruleIDs: ["composer-cache"]
        ),
        DeveloperEnvironmentDefinition(
            id: "dart-flutter", title: "Dart & Flutter", symbol: "puzzlepiece.extension", ruleIDs: ["pub-cache"]
        ),
        DeveloperEnvironmentDefinition(id: "nix", title: "Nix", symbol: "atom", ruleIDs: ["nix-user-cache"]),
    ]

    private static let environmentByRuleID: [String: DeveloperEnvironmentDefinition] = {
        var map: [String: DeveloperEnvironmentDefinition] = [:]
        for definition in definitions {
            for ruleID in definition.ruleIDs { map[ruleID] = definition }
        }
        return map
    }()

    /// Collapses per-rule groups (`InventoryGroup.id == Rule.id`, exactly what `ScanService`'s
    /// `ruleGroups` output looks like) into per-environment groups.
    ///
    /// A rule with nothing matched never appears in `ruleGroups` at all (`ScanService.buildGroups`
    /// filters populated nodes only), so an environment collapses to zero contributing rules and
    /// is simply never constructed here — "environments with nothing installed hide" falls out of
    /// this by construction, not from a separate empty-check.
    ///
    /// A rule id with no known environment (catalog drift ahead of this file) is dropped rather
    /// than crashing a real user's scan; `DeveloperEnvironmentTests` is what should catch that
    /// drift before it ships.
    static func buildGroups(fromRuleGroups ruleGroups: [InventoryGroup]) -> [InventoryGroup] {
        var itemsByEnvironment: [String: [InventoryItem]] = [:]
        var order: [String] = []

        for ruleGroup in ruleGroups {
            guard let environment = environmentByRuleID[ruleGroup.id] else { continue }
            if itemsByEnvironment[environment.id] == nil { order.append(environment.id) }
            itemsByEnvironment[environment.id, default: []].append(contentsOf: ruleGroup.items)
        }

        let byID = Dictionary(uniqueKeysWithValues: definitions.map { ($0.id, $0) })
        return order
            .compactMap { id -> InventoryGroup? in
                guard let definition = byID[id], let items = itemsByEnvironment[id], !items.isEmpty else { return nil }
                return InventoryGroup(id: definition.id, title: definition.title, symbol: definition.symbol, items: items)
            }
            .sorted { $0.byteCount > $1.byteCount }
    }
}
