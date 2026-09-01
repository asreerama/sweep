import XCTest
@testable import SweepCore
import SweepPolicy

/// The model types must mirror rules/schema.json exactly. The schema is frozen, so this test
/// is a tripwire: if either side moves, the loader silently stops matching the catalogs the
/// app ships and this fails first.
final class SchemaDriftTests: XCTestCase {

    /// rules/schema.json, located from this file's compile-time path (the package has no
    /// resource bundle and the schema is owned outside it).
    static var schemaURL: URL {
        URL(fileURLWithPath: #filePath)          // .../Packages/SweepCore/Tests/SweepCoreTests/SchemaDriftTests.swift
            .deletingLastPathComponent()         // SweepCoreTests
            .deletingLastPathComponent()         // Tests
            .deletingLastPathComponent()         // SweepCore
            .deletingLastPathComponent()         // Packages
            .deletingLastPathComponent()         // repo root
            .appending(path: "rules/schema.json")
    }

    private func ruleProperties() throws -> [String: [String: Any]] {
        let url = Self.schemaURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("rules/schema.json not reachable from \(url.path)")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(object as? [String: Any])
        let defs = try XCTUnwrap(root["$defs"] as? [String: Any])
        let rule = try XCTUnwrap(defs["rule"] as? [String: Any])
        return try XCTUnwrap(rule["properties"] as? [String: [String: Any]])
    }

    private func schemaEnum(_ field: String, in properties: [String: [String: Any]]) throws -> Set<String> {
        let property = try XCTUnwrap(properties[field], "schema has no `\(field)` property")
        if let values = property["enum"] as? [String] { return Set(values) }
        // itemTypes is an array whose items carry the enum.
        let items = try XCTUnwrap(property["items"] as? [String: Any], "`\(field)` has no enum")
        return Set(try XCTUnwrap(items["enum"] as? [String]))
    }

    func testEnumsMatchTheFrozenSchema() throws {
        let properties = try ruleProperties()

        XCTAssertEqual(try schemaEnum("group", in: properties), Set(RuleGroup.allCases.map(\.rawValue)))
        XCTAssertEqual(try schemaEnum("root", in: properties), Set(SweepPolicy.OperationRoot.allCases.map(\.rawValue)))
        XCTAssertEqual(try schemaEnum("itemTypes", in: properties), Set(RuleItemType.allCases.map(\.rawValue)))
        XCTAssertEqual(try schemaEnum("tier", in: properties), Set(Tier.allCases.map(\.rawValue)))
        XCTAssertEqual(try schemaEnum("action", in: properties), Set(RuleAction.allCases.map(\.rawValue)))
        XCTAssertEqual(try schemaEnum("command", in: properties), Set(RuleCommand.allCases.map(\.rawValue)))
        XCTAssertEqual(try schemaEnum("undo", in: properties), Set(RuleUndo.allCases.map(\.rawValue)))
    }

    func testModelCoversEveryDeclaredProperty() throws {
        let properties = try ruleProperties()
        let modelled = Set(Rule.CodingKeys.allCases.map(\.stringValue))
        XCTAssertEqual(
            Set(properties.keys),
            modelled,
            "Rule must model exactly the schema's properties; additionalProperties is false"
        )
    }

    func testRequiredFieldsAreNonOptionalInTheModel() throws {
        let url = Self.schemaURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("rules/schema.json not reachable")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(object as? [String: Any])
        let defs = try XCTUnwrap(root["$defs"] as? [String: Any])
        let rule = try XCTUnwrap(defs["rule"] as? [String: Any])
        let required = Set(try XCTUnwrap(rule["required"] as? [String]))

        // Dropping any of these from a catalog must be a hard failure, which the loader proves
        // by refusing a catalog missing it.
        for field in required.sorted() {
            let json = Self.catalogOmitting(field)
            XCTAssertThrowsError(try RuleCatalogLoader.load(data: Data(json.utf8)), "omitting `\(field)` was accepted") { error in
                guard let catalogError = error as? RuleCatalogError else {
                    return XCTFail("unexpected error type for `\(field)`: \(error)")
                }
                switch catalogError {
                case .missingField, .invalidRuleID, .malformedJSON:
                    break
                default:
                    XCTFail("omitting `\(field)` produced \(catalogError)")
                }
            }
        }
    }

    func testSchemaVersionIsPinned() throws {
        let url = Self.schemaURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("rules/schema.json not reachable")
        }
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
        let root = try XCTUnwrap(object as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let schemaVersion = try XCTUnwrap(properties["schemaVersion"] as? [String: Any])
        XCTAssertEqual(schemaVersion["const"] as? Int, RuleCatalog.supportedSchemaVersion)
    }

    private static func catalogOmitting(_ field: String) -> String {
        var fields: [String: String] = [
            "id": "\"user.caches.app\"",
            "title": "\"Application caches\"",
            "group": "\"systemJunk\"",
            "root": "\"userCaches\"",
            "pattern": "\"*/**\"",
            "itemTypes": "[\"file\"]",
            "tier": "\"safe\"",
            "action": "\"trash\"",
            "undo": "\"regenerated\"",
            "rationale": "\"Regenerated on demand.\"",
        ]
        fields[field] = nil
        let body = fields.map { "\"\($0.key)\": \($0.value)" }.joined(separator: ",\n      ")
        return """
        {
          "schemaVersion": 1,
          "rules": [
            {
              \(body)
            }
          ]
        }
        """
    }
}
