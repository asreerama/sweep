import XCTest
@testable import SweepCore
import SweepPolicy

/// Catalog fixtures live inline: the loader's contract is "these bytes are accepted, those
/// bytes are refused", so the bytes belong next to the assertion.
final class RuleCatalogTests: XCTestCase {

    // MARK: - Happy paths

    func testMinimalValidCatalogLoads() throws {
        let json = """
        {
          "schemaVersion": 1,
          "rules": [
            {
              "id": "user.caches.app",
              "title": "Application caches",
              "group": "systemJunk",
              "root": "userCaches",
              "pattern": "*/**",
              "itemTypes": ["file", "directory"],
              "tier": "safe",
              "action": "trash",
              "undo": "regenerated",
              "rationale": "Caches are regenerated on demand."
            }
          ]
        }
        """
        let catalog = try RuleCatalogLoader.load(data: Data(json.utf8))
        XCTAssertEqual(catalog.schemaVersion, 1)
        XCTAssertEqual(catalog.rules.count, 1)

        let rule = try XCTUnwrap(catalog[id: "user.caches.app"])
        XCTAssertEqual(rule.group, .systemJunk)
        XCTAssertEqual(rule.root, .userCaches)
        XCTAssertEqual(rule.itemTypes, [.file, .directory])
        XCTAssertEqual(rule.tier, .safe)
        XCTAssertEqual(rule.action, .trash)
        XCTAssertEqual(rule.undo, .regenerated)
        XCTAssertEqual(rule.minAgeDays, 0, "minAgeDays defaults to 0")
        XCTAssertNil(rule.requiresAppNotRunning)
        XCTAssertNil(rule.command)
        XCTAssertEqual(rule.exclusions, [])
    }

    func testFullyPopulatedCatalogLoads() throws {
        let json = """
        {
          "schemaVersion": 1,
          "rules": [
            {
              "id": "xcode.deriveddata",
              "title": "Xcode DerivedData",
              "group": "developer",
              "root": "xcodeDerivedData",
              "pattern": "*",
              "itemTypes": ["directory"],
              "minAgeDays": 14,
              "requiresAppNotRunning": "com.apple.dt.Xcode",
              "tier": "caution",
              "action": "trash",
              "undo": "trashRestore",
              "exclusions": ["ModuleCache.noindex"],
              "rationale": "Rebuilt by Xcode, but a rebuild is expensive."
            },
            {
              "id": "homebrew.cleanup",
              "title": "Homebrew cache cleanup",
              "group": "homebrew",
              "root": "homebrewCache",
              "pattern": "**",
              "itemTypes": ["file"],
              "tier": "safe",
              "action": "commandPreview",
              "command": "brewCleanup",
              "undo": "none",
              "rationale": "brew cleanup --prune=all."
            }
          ]
        }
        """
        let catalog = try RuleCatalogLoader.load(data: Data(json.utf8))
        XCTAssertEqual(catalog.rules.count, 2)

        let xcode = try XCTUnwrap(catalog[id: "xcode.deriveddata"])
        XCTAssertEqual(xcode.minAgeDays, 14)
        XCTAssertEqual(xcode.requiresAppNotRunning, "com.apple.dt.Xcode")
        XCTAssertEqual(xcode.exclusions, ["ModuleCache.noindex"])

        let brew = try XCTUnwrap(catalog[id: "homebrew.cleanup"])
        XCTAssertEqual(brew.action, .commandPreview)
        XCTAssertEqual(brew.command, .brewCleanup)
        XCTAssertEqual(catalog.rules(for: .homebrewCache).map(\.id), ["homebrew.cleanup"])
    }

    func testCatalogRoundTripsThroughEncoding() throws {
        let original = try RuleCatalogLoader.load(data: Data(Self.validCatalog().utf8))
        let encoded = try JSONEncoder().encode(original)
        let decoded = try RuleCatalogLoader.load(data: encoded)
        XCTAssertEqual(original, decoded)
    }

    func testDeleteIsAcceptedOnSafeTier() throws {
        let json = Self.validCatalog(tier: "\"safe\"", action: "\"delete\"", undo: "\"regenerated\"")
        let catalog = try RuleCatalogLoader.load(data: Data(json.utf8))
        XCTAssertEqual(catalog.rules[0].action, .delete)
    }

    // MARK: - Sad paths

    func testUnknownTopLevelFieldRejected() {
        let json = """
        {"schemaVersion": 1, "rules": [], "extra": true}
        """
        expectFailure(json, .unknownField(container: "catalog", field: "extra"))
    }

    func testUnknownRuleFieldRejected() {
        let json = Self.validCatalog(extraRuleFields: "\"dangerLevel\": 9,")
        expectFailure(json, .unknownField(container: "rule", field: "dangerLevel"))
    }

    func testUnknownActionRejected() {
        let json = Self.validCatalog(action: "\"shred\"")
        expectFailure(json, .unknownValue(ruleID: "user.caches.app", field: "action", value: "shred"))
    }

    func testUnknownRootRejected() {
        let json = Self.validCatalog(root: "\"slashEtc\"")
        expectFailure(json, .unknownValue(ruleID: "user.caches.app", field: "root", value: "slashEtc"))
    }

    func testUnknownTierRejected() {
        let json = Self.validCatalog(tier: "\"reckless\"")
        expectFailure(json, .unknownValue(ruleID: "user.caches.app", field: "tier", value: "reckless"))
    }

    func testUnsupportedSchemaVersionRejected() {
        let json = Self.validCatalog(schemaVersion: "2")
        expectFailure(json, .unsupportedSchemaVersion(2))
    }

    func testMissingRequiredFieldRejected() {
        let json = """
        {
          "schemaVersion": 1,
          "rules": [
            {
              "id": "user.caches.app",
              "title": "Application caches",
              "group": "systemJunk",
              "root": "userCaches",
              "pattern": "*",
              "itemTypes": ["file"],
              "tier": "safe",
              "action": "trash",
              "rationale": "No undo field."
            }
          ]
        }
        """
        expectFailure(json, .missingField(ruleID: nil, field: "undo"))
    }

    func testDeleteOutsideSafeTierRejected() {
        let json = Self.validCatalog(tier: "\"caution\"", action: "\"delete\"")
        expectFailure(json, .deleteRequiresSafeTier(ruleID: "user.caches.app", tier: "caution"))
    }

    func testDeleteOnExpertTierRejected() {
        let json = Self.validCatalog(tier: "\"expert\"", action: "\"delete\"")
        expectFailure(json, .deleteRequiresSafeTier(ruleID: "user.caches.app", tier: "expert"))
    }

    func testCommandPreviewWithoutCommandRejected() {
        let json = Self.validCatalog(action: "\"commandPreview\"")
        expectFailure(json, .commandRequired(ruleID: "user.caches.app"))
    }

    func testCommandOnNonCommandActionRejected() {
        let json = Self.validCatalog(extraRuleFields: "\"command\": \"brewCleanup\",")
        expectFailure(json, .commandNotAllowed(ruleID: "user.caches.app", action: "trash"))
    }

    func testUnknownCommandRejected() {
        let json = Self.validCatalog(
            action: "\"commandPreview\"",
            extraRuleFields: "\"command\": \"rmRf\","
        )
        expectFailure(json, .unknownValue(ruleID: "user.caches.app", field: "command", value: "rmRf"))
    }

    func testInvalidRuleIDRejected() {
        for badID in ["Caches", "ab", "user caches", "user_caches", "-leading", String(repeating: "a", count: 66)] {
            expectFailure(Self.validCatalog(id: "\"\(badID)\""), .invalidRuleID(badID))
        }
    }

    func testDuplicateRuleIDRejected() {
        let json = """
        {
          "schemaVersion": 1,
          "rules": [
            \(Self.ruleBody()),
            \(Self.ruleBody())
          ]
        }
        """
        expectFailure(json, .duplicateRuleID("user.caches.app"))
    }

    func testPatternEscapingRootRejected() {
        expectFailure(
            Self.validCatalog(pattern: "\"../../etc\""),
            .invalidGlob(ruleID: "user.caches.app", field: "pattern", glob: "../../etc", reason: "`..` component")
        )
        expectFailure(
            Self.validCatalog(pattern: "\"/etc/passwd\""),
            .invalidGlob(ruleID: "user.caches.app", field: "pattern", glob: "/etc/passwd", reason: "leading /")
        )
        expectFailure(
            Self.validCatalog(pattern: "\"~/Documents\""),
            .invalidGlob(ruleID: "user.caches.app", field: "pattern", glob: "~/Documents", reason: "tilde expansion")
        )
    }

    func testExclusionEscapingRootRejected() {
        expectFailure(
            Self.validCatalog(extraRuleFields: "\"exclusions\": [\"../secrets\"],"),
            .invalidGlob(ruleID: "user.caches.app", field: "exclusions", glob: "../secrets", reason: "`..` component")
        )
    }

    func testOverlongTitleRejected() {
        let long = String(repeating: "t", count: 81)
        expectFailure(
            Self.validCatalog(title: "\"\(long)\""),
            .fieldTooLong(ruleID: "user.caches.app", field: "title", limit: 80)
        )
    }

    func testOverlongRationaleRejected() {
        let long = String(repeating: "r", count: 301)
        expectFailure(
            Self.validCatalog(rationale: "\"\(long)\""),
            .fieldTooLong(ruleID: "user.caches.app", field: "rationale", limit: 300)
        )
    }

    func testEmptyItemTypesRejected() {
        expectFailure(Self.validCatalog(itemTypes: "[]"), .emptyItemTypes(ruleID: "user.caches.app"))
    }

    func testNegativeMinimumAgeRejected() {
        expectFailure(
            Self.validCatalog(extraRuleFields: "\"minAgeDays\": -1,"),
            .negativeMinimumAge(ruleID: "user.caches.app")
        )
    }

    func testMalformedJSONRejected() {
        XCTAssertThrowsError(try RuleCatalogLoader.load(data: Data("{ not json".utf8))) { error in
            guard case .malformedJSON = error as? RuleCatalogError else {
                return XCTFail("expected malformedJSON, got \(error)")
            }
        }
    }

    func testUnreadableCatalogFileReported() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "no-such-catalog-\(UUID()).json")
        XCTAssertThrowsError(try RuleCatalogLoader.load(contentsOf: missing)) { error in
            guard case .unreadable = error as? RuleCatalogError else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    func testProgrammaticallyBuiltInvalidRuleFailsValidation() {
        let rule = Rule(
            id: "bad.rule",
            title: "Direct delete on caution tier",
            group: .systemJunk,
            root: .userCaches,
            pattern: "*",
            itemTypes: [.file],
            tier: .caution,
            action: .delete,
            undo: .none,
            rationale: "Should not validate."
        )
        XCTAssertThrowsError(try rule.validate()) { error in
            XCTAssertEqual(
                error as? RuleCatalogError,
                .deleteRequiresSafeTier(ruleID: "bad.rule", tier: "caution")
            )
        }
    }

    // MARK: - Helpers

    private func expectFailure(
        _ json: String,
        _ expected: RuleCatalogError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try RuleCatalogLoader.load(data: Data(json.utf8)), file: file, line: line) { error in
            XCTAssertEqual(error as? RuleCatalogError, expected, file: file, line: line)
        }
    }

    static func ruleBody(
        id: String = "\"user.caches.app\"",
        title: String = "\"Application caches\"",
        root: String = "\"userCaches\"",
        pattern: String = "\"*/**\"",
        itemTypes: String = "[\"file\", \"directory\"]",
        tier: String = "\"safe\"",
        action: String = "\"trash\"",
        undo: String = "\"regenerated\"",
        rationale: String = "\"Caches are regenerated on demand.\"",
        extraRuleFields: String = ""
    ) -> String {
        """
        {
          "id": \(id),
          "title": \(title),
          "group": "systemJunk",
          "root": \(root),
          "pattern": \(pattern),
          "itemTypes": \(itemTypes),
          \(extraRuleFields)
          "tier": \(tier),
          "action": \(action),
          "undo": \(undo),
          "rationale": \(rationale)
        }
        """
    }

    static func validCatalog(
        schemaVersion: String = "1",
        id: String = "\"user.caches.app\"",
        title: String = "\"Application caches\"",
        root: String = "\"userCaches\"",
        pattern: String = "\"*/**\"",
        itemTypes: String = "[\"file\", \"directory\"]",
        tier: String = "\"safe\"",
        action: String = "\"trash\"",
        undo: String = "\"regenerated\"",
        rationale: String = "\"Caches are regenerated on demand.\"",
        extraRuleFields: String = ""
    ) -> String {
        """
        {
          "schemaVersion": \(schemaVersion),
          "rules": [
            \(ruleBody(
                id: id,
                title: title,
                root: root,
                pattern: pattern,
                itemTypes: itemTypes,
                tier: tier,
                action: action,
                undo: undo,
                rationale: rationale,
                extraRuleFields: extraRuleFields
            ))
          ]
        }
        """
    }
}
