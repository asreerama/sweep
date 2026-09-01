import SweepCore
import SweepUI
import XCTest
@testable import SweepApp

/// `DeveloperEnvironmentCatalog` (Developer screen, module 10, PLAN §3): the per-rule → per-
/// environment collapse, and the real-catalog coverage tripwire that keeps it from silently
/// drifting out of sync with `rules/catalog.json`'s `developer` group.
final class DeveloperEnvironmentTests: XCTestCase {

    // MARK: - Real-catalog coverage (tripwire, mirrors SchemaDriftTests' style)

    /// `rules/catalog.json`, located from this file's compile-time path — same technique
    /// `SchemaDriftTests.schemaURL` uses for `rules/schema.json`, one directory shallower since
    /// this file lives at `Tests/SweepAppTests/...` (repo root's Tests/, not a package's Tests/).
    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/SweepAppTests/DeveloperEnvironmentTests.swift
            .deletingLastPathComponent()          // SweepAppTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // repo root
            .appending(path: "rules/catalog.json")
    }

    private func developerRuleIDs() throws -> Set<String> {
        let url = Self.catalogURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("rules/catalog.json not reachable from \(url.path)")
        }
        let catalog = try RuleCatalogLoader.load(contentsOf: url)
        return Set(catalog.rules.filter { $0.group == .developer }.map(\.id))
    }

    /// A new `developer`-group rule that forgets to land in `DeveloperEnvironmentCatalog
    /// .definitions` would otherwise just silently never appear on the Developer screen — no
    /// crash, no warning, an environment that quietly under-reports. This is the test that turns
    /// that into a build failure instead.
    func testEveryDeveloperRuleInTheRealCatalogHasAnEnvironment() throws {
        let ruleIDs = try developerRuleIDs()
        let mapped = Set(DeveloperEnvironmentCatalog.definitions.flatMap(\.ruleIDs))
        let unmapped = ruleIDs.subtracting(mapped)
        XCTAssertTrue(
            unmapped.isEmpty,
            "developer rule(s) with no environment mapping: \(unmapped.sorted()) — add them to "
                + "DeveloperEnvironmentCatalog.definitions"
        )
    }

    /// The reverse drift: a rule id renamed or removed from the catalog that this file's mapping
    /// never noticed. Not fatal to the app (`buildGroups` drops unknown ids safely), but a stale
    /// entry here means a real environment lost its live sizes without anyone noticing.
    func testEveryDefinitionRuleIDExistsInTheRealCatalog() throws {
        let ruleIDs = try developerRuleIDs()
        let mapped = Set(DeveloperEnvironmentCatalog.definitions.flatMap(\.ruleIDs))
        let stale = mapped.subtracting(ruleIDs)
        XCTAssertTrue(stale.isEmpty, "environment definitions reference rule ids no longer in the catalog: \(stale.sorted())")
    }

    func testDefinitionIDsAreUnique() {
        let ids = DeveloperEnvironmentCatalog.definitions.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "duplicate environment id in DeveloperEnvironmentCatalog.definitions")
    }

    func testNoRuleIDIsClaimedByTwoEnvironments() {
        var seen: [String: String] = [:]
        for definition in DeveloperEnvironmentCatalog.definitions {
            for ruleID in definition.ruleIDs {
                if let owner = seen[ruleID] {
                    XCTFail("rule id \(ruleID) claimed by both \(owner) and \(definition.id)")
                }
                seen[ruleID] = definition.id
            }
        }
    }

    // MARK: - buildGroups (pure, synthetic input)

    private func ruleGroup(id: String, bytes: Int64) -> InventoryGroup {
        InventoryGroup(id: id, title: id, symbol: "folder", items: [
            InventoryItem(id: "/fixture/\(id)", title: id, byteCount: bytes, tier: .safe),
        ])
    }

    func testBuildGroupsHidesEnvironmentsWithNothingInstalled() {
        // No rule groups at all → no environments. "Environments with nothing installed hide"
        // (task spec) falls out of construction rather than a separate empty check.
        XCTAssertTrue(DeveloperEnvironmentCatalog.buildGroups(fromRuleGroups: []).isEmpty)
    }

    func testBuildGroupsMergesMultipleRulesIntoOneEnvironment() {
        // vscode-cache + vscode-gpucache + vscode-cached-data + vscode-cached-extensions all
        // collapse into the single "Visual Studio Code" environment.
        let groups = DeveloperEnvironmentCatalog.buildGroups(fromRuleGroups: [
            ruleGroup(id: "vscode-cache", bytes: 100),
            ruleGroup(id: "vscode-gpucache", bytes: 200),
            ruleGroup(id: "vscode-cached-data", bytes: 50),
        ])
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.id, "vscode")
        XCTAssertEqual(groups.first?.title, "Visual Studio Code")
        XCTAssertEqual(groups.first?.itemCount, 3)
        XCTAssertEqual(groups.first?.byteCount, 350)
    }

    func testBuildGroupsKeepsUnrelatedEnvironmentsSeparate() {
        let groups = DeveloperEnvironmentCatalog.buildGroups(fromRuleGroups: [
            ruleGroup(id: "npm-cache", bytes: 100),
            ruleGroup(id: "jetbrains-ide-cache", bytes: 900),
        ])
        XCTAssertEqual(Set(groups.map(\.id)), ["node", "jetbrains"])
    }

    func testBuildGroupsSortsByByteCountDescending() {
        let groups = DeveloperEnvironmentCatalog.buildGroups(fromRuleGroups: [
            ruleGroup(id: "npm-cache", bytes: 100),
            ruleGroup(id: "gradle-cache", bytes: 900),
            ruleGroup(id: "zed-cache", bytes: 500),
        ])
        XCTAssertEqual(groups.map(\.id), ["gradle", "zed", "node"])
    }

    func testBuildGroupsDropsRuleIDsWithNoKnownEnvironment() {
        // Defensive: a rule id this file has never heard of (catalog drift ahead of a mapping
        // update) must not crash a real user's scan — it is simply excluded.
        let groups = DeveloperEnvironmentCatalog.buildGroups(fromRuleGroups: [
            ruleGroup(id: "some-future-rule-nobody-mapped-yet", bytes: 100),
            ruleGroup(id: "npm-cache", bytes: 50),
        ])
        XCTAssertEqual(groups.map(\.id), ["node"])
    }
}
