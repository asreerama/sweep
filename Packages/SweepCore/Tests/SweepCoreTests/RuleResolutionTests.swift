import XCTest
@testable import SweepCore
import SweepPolicy

final class RuleResolutionTests: XCTestCase {

    // MARK: - Glob vocabulary

    func testSingleStarStaysInsideOneComponent() {
        XCTAssertTrue(RuleGlob("*").matches("Homebrew"))
        XCTAssertFalse(RuleGlob("*").matches("Homebrew/downloads"))
        XCTAssertTrue(RuleGlob("*/cache2").matches("Profiles/cache2"))
        XCTAssertFalse(RuleGlob("*/cache2").matches("Profiles/x/cache2"))
    }

    func testDoubleStarCrossesComponents() {
        XCTAssertTrue(RuleGlob("**").matches("a/b/c"))
        XCTAssertTrue(RuleGlob("Firefox/**/cache2").matches("Firefox/Profiles/abc.default/cache2"))
        XCTAssertTrue(RuleGlob("Firefox/**").matches("Firefox"))
        XCTAssertFalse(RuleGlob("Firefox/**/cache2").matches("Chrome/Profiles/cache2"))
    }

    func testQuestionMarkMatchesOneCharacter() {
        XCTAssertTrue(RuleGlob("log?.txt").matches("log1.txt"))
        XCTAssertFalse(RuleGlob("log?.txt").matches("log12.txt"))
        XCTAssertFalse(RuleGlob("log?.txt").matches("log/1.txt"))
    }

    // MARK: - Deny-wins

    func testExclusionDeniesEvenWhenAnotherRuleMatches() {
        let catalog = RuleCatalog(rules: [
            Self.rule(id: "caches.broad", pattern: "**", tier: .safe, exclusions: ["Homebrew"]),
            Self.rule(id: "caches.homebrew", pattern: "Homebrew/**", tier: .safe),
        ])

        let decision = catalog.decision(
            forRelativePath: "Homebrew/downloads/x.tar.gz",
            root: .userCaches,
            itemType: .file
        )
        XCTAssertEqual(decision, .denied(byRuleID: "caches.broad", exclusion: "Homebrew"))
        XCTAssertTrue(decision.isDenied)
        XCTAssertNil(decision.rule)
    }

    func testExclusionScopedToItsOwnRoot() {
        let catalog = RuleCatalog(rules: [
            Self.rule(id: "caches.broad", root: .userCaches, pattern: "**", exclusions: ["Homebrew"]),
            Self.rule(id: "logs.broad", root: .userLogs, pattern: "**"),
        ])
        let decision = catalog.decision(forRelativePath: "Homebrew/x", root: .userLogs, itemType: .file)
        XCTAssertEqual(decision.rule?.id, "logs.broad", "an exclusion under userCaches must not deny userLogs")
    }

    func testMostRestrictiveTierWinsAmongMatches() {
        let catalog = RuleCatalog(rules: [
            Self.rule(id: "a.safe", pattern: "**", tier: .safe),
            Self.rule(id: "b.expert", pattern: "Xcode/**", tier: .expert),
            Self.rule(id: "c.caution", pattern: "Xcode/**", tier: .caution),
        ])
        let decision = catalog.decision(forRelativePath: "Xcode/DerivedData", root: .userCaches, itemType: .directory)
        XCTAssertEqual(decision.rule?.id, "b.expert")
    }

    func testLeastDestructiveActionWinsWithinTier() {
        let catalog = RuleCatalog(rules: [
            Self.rule(id: "a.delete", pattern: "**", tier: .safe, action: .delete),
            Self.rule(id: "b.trash", pattern: "**", tier: .safe, action: .trash),
        ])
        let decision = catalog.decision(forRelativePath: "anything", root: .userCaches, itemType: .file)
        XCTAssertEqual(decision.rule?.id, "b.trash")
    }

    func testResolutionIsIndependentOfCatalogOrder() {
        let forward = RuleCatalog(rules: [
            Self.rule(id: "a.match", pattern: "**", tier: .caution),
            Self.rule(id: "b.match", pattern: "**", tier: .caution),
        ])
        let reversed = RuleCatalog(rules: forward.rules.reversed())
        XCTAssertEqual(
            forward.decision(forRelativePath: "x", root: .userCaches, itemType: .file).rule?.id,
            reversed.decision(forRelativePath: "x", root: .userCaches, itemType: .file).rule?.id
        )
    }

    func testItemTypeFiltersMatches() {
        let catalog = RuleCatalog(rules: [
            Self.rule(id: "dirs.only", pattern: "**", itemTypes: [.directory]),
        ])
        XCTAssertEqual(catalog.decision(forRelativePath: "x", root: .userCaches, itemType: .file), .noMatch)
        XCTAssertEqual(
            catalog.decision(forRelativePath: "x", root: .userCaches, itemType: .directory).rule?.id,
            "dirs.only"
        )
    }

    func testNoMatchWhenNothingClaimsThePath() {
        let catalog = RuleCatalog(rules: [Self.rule(id: "narrow.rule", pattern: "Xcode/**")])
        XCTAssertEqual(catalog.decision(forRelativePath: "Firefox/x", root: .userCaches, itemType: .file), .noMatch)
    }

    func testRuleMatchesHelperHonorsItsOwnExclusions() {
        let rule = Self.rule(id: "caches.broad", pattern: "**", exclusions: ["Homebrew"])
        XCTAssertTrue(rule.matches(relativePath: "Firefox/x", itemType: .file))
        XCTAssertFalse(rule.matches(relativePath: "Homebrew/x", itemType: .file))
        XCTAssertTrue(rule.excludes(relativePath: "Homebrew"))
    }

    // MARK: - Helpers

    static func rule(
        id: String,
        root: SweepPolicy.OperationRoot = .userCaches,
        pattern: String,
        itemTypes: [RuleItemType] = [.file, .directory],
        tier: Tier = .safe,
        action: RuleAction = .trash,
        exclusions: [String] = []
    ) -> Rule {
        Rule(
            id: id,
            title: id,
            group: .systemJunk,
            root: root,
            pattern: pattern,
            itemTypes: itemTypes,
            tier: tier,
            action: action,
            undo: action == .trash ? .trashRestore : .regenerated,
            exclusions: exclusions,
            rationale: "test rule"
        )
    }
}
