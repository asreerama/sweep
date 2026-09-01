import XCTest
@testable import SweepCore

/// ``RuleCatalogLoader/loadBundled(from:)`` against this repo's real `rules/` directory,
/// located from this file's compile-time path the same way `SchemaDriftTests` locates
/// `rules/schema.json`.
final class RuleCatalogLoaderBundledTests: XCTestCase {

    /// `.../Packages/SweepCore/Tests/SweepCoreTests/RuleCatalogLoaderBundledTests.swift` up to
    /// the repo root, then down into `rules/`.
    static var rulesDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // SweepCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // SweepCore
            .deletingLastPathComponent()  // Packages
            .deletingLastPathComponent()  // repo root
            .appending(path: "rules")
    }

    func testLoadsTheRepoRulesDirectory() throws {
        let directory = Self.rulesDirectory
        guard FileManager.default.fileExists(atPath: directory.path) else {
            throw XCTSkip("rules/ not reachable from \(directory.path)")
        }

        let catalog = try RuleCatalogLoader.loadBundled(from: directory)

        XCTAssertEqual(catalog.schemaVersion, RuleCatalog.supportedSchemaVersion)
        XCTAssertFalse(catalog.rules.isEmpty)
    }

    func testMissingSchemaFileIsReportedEvenWhenCatalogIsPresent() throws {
        let tree = try TempTree("loadBundled-missing-schema")
        try tree.write("catalog.json", contents: """
        {"schemaVersion": 1, "rules": []}
        """)

        XCTAssertThrowsError(try RuleCatalogLoader.loadBundled(from: tree.root)) { error in
            guard case .unreadable = error as? RuleCatalogError else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    func testMissingCatalogFileIsReportedWhenSchemaIsPresent() throws {
        let tree = try TempTree("loadBundled-missing-catalog")
        try tree.write("schema.json", contents: "{}")

        XCTAssertThrowsError(try RuleCatalogLoader.loadBundled(from: tree.root)) { error in
            guard case .unreadable = error as? RuleCatalogError else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
    }

    func testLoadsFromADirectoryWithBothFiles() throws {
        let tree = try TempTree("loadBundled-both")
        try tree.write("schema.json", contents: "{}")
        try tree.write("catalog.json", contents: """
        {
          "schemaVersion": 1,
          "rules": [
            {
              "id": "user.caches.app",
              "title": "Application caches",
              "group": "systemJunk",
              "root": "userCaches",
              "pattern": "*/**",
              "itemTypes": ["file"],
              "tier": "safe",
              "action": "trash",
              "undo": "regenerated",
              "rationale": "Caches are regenerated on demand."
            }
          ]
        }
        """)

        let catalog = try RuleCatalogLoader.loadBundled(from: tree.root)
        XCTAssertEqual(catalog.rules.count, 1)
        XCTAssertEqual(catalog[id: "user.caches.app"]?.group, .systemJunk)
    }
}
