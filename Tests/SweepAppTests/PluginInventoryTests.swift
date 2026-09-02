import SweepUI
import XCTest
@testable import SweepApp

/// Pure logic behind `PluginsScreen` (Toolbox "Plugins" module): the `pluginkit -m -v` output
/// parser, owner-app attribution, category/scope/tier assignment, and the `/System` exclusion
/// policy. Nothing here touches the filesystem or spawns a process — `PluginFilesystemScanner`
/// and `PluginKitRunner` are thin, already-injectable I/O wrappers with nothing worth mocking,
/// matching the "no disk" scope this suite is asked for.
final class PluginInventoryTests: XCTestCase {

    // MARK: - pluginkit parser

    /// One captured-style fixture carrying every shape the real `man pluginkit` format allows:
    /// an unflagged row, `+`/`-`/`!` elections, a `(null)` version, odd/uneven column padding, a
    /// path containing spaces, and a line that is not `pluginkit` output at all.
    private let pluginKitFixture = [
        "     com.example.plain.extension(1.0)\tAAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\t2026-01-01 00:00:00 +0000\t/Applications/PlainApp.app/Contents/PlugIns/Plain.appex",
        "+    com.example.enabled.extension(2.3.1)\t11111111-2222-3333-4444-555555555555\t2026-02-02 02:02:02 +0000\t/Applications/EnabledApp.app/Contents/PlugIns/Enabled.appex",
        "-    com.example.ignored.extension(0.1)\t66666666-7777-8888-9999-000000000000\t2026-03-03 03:03:03 +0000\t/Applications/IgnoredApp.app/Contents/PlugIns/Ignored.appex",
        "!    com.example.debug.extension(0.9)\tFEEDFACE-CAFE-BABE-F00D-DEADBEEF0000\t2026-04-04 04:04:04 +0000\t/Applications/DebugApp.app/Contents/PlugIns/Debug.appex",
        "     com.example.nullversion.extension((null))\tCACACACA-1111-2222-3333-444444444444\t2026-05-05 05:05:05 +0000\t/Applications/NullVersionApp.app/Contents/PlugIns/NullVersion.appex",
        "+       com.example.wide.extension(1.0)\t  22222222-3333-4444-5555-666666666666  \t 2026-06-06 06:06:06 +0000 \t/Applications/WideApp.app/Contents/PlugIns/Wide.appex",
        " com.example.spacedpath.extension(1.2)\t99999999-8888-7777-6666-555555555555\t2026-07-07 07:07:07 +0000\t/Applications/Spaced App.app/Contents/PlugIns/My Extension Name.appex",
        "this line is not pluginkit output at all and has no tabs",
        "     com.apple.something.system(1.0)\t01234567-89AB-CDEF-0123-456789ABCDEF\t2026-08-08 08:08:08 +0000\t/System/Library/PrivateFrameworks/Something.framework/PlugIns/Something.appex",
    ].joined(separator: "\n")

    func testParsesUnflaggedLine() {
        let entries = PluginKitParser.parse(pluginKitFixture)
        let entry = entries.first { $0.identifier == "com.example.plain.extension" }
        XCTAssertEqual(entry?.election, PluginKitElection.none)
        XCTAssertEqual(entry?.version, "1.0")
        XCTAssertEqual(entry?.uuid, "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        XCTAssertEqual(entry?.path, "/Applications/PlainApp.app/Contents/PlugIns/Plain.appex")
    }

    func testParsesUseIgnoreAndDebugFlags() {
        let entries = PluginKitParser.parse(pluginKitFixture)
        XCTAssertEqual(entries.first { $0.identifier == "com.example.enabled.extension" }?.election, .use)
        XCTAssertEqual(entries.first { $0.identifier == "com.example.ignored.extension" }?.election, .ignore)
        XCTAssertEqual(entries.first { $0.identifier == "com.example.debug.extension" }?.election, .debug)
    }

    func testNullVersionParsesAsNilNotTheLiteralString() {
        let entries = PluginKitParser.parse(pluginKitFixture)
        let entry = entries.first { $0.identifier == "com.example.nullversion.extension" }
        XCTAssertNotNil(entry)
        XCTAssertNil(entry?.version)
    }

    func testTolerantOfOddColumnPadding() {
        let entries = PluginKitParser.parse(pluginKitFixture)
        let entry = entries.first { $0.identifier == "com.example.wide.extension" }
        XCTAssertEqual(entry?.election, .use)
        XCTAssertEqual(entry?.uuid, "22222222-3333-4444-5555-666666666666", "surrounding whitespace inside a field must be trimmed")
        XCTAssertEqual(entry?.path, "/Applications/WideApp.app/Contents/PlugIns/Wide.appex")
    }

    func testPathContainingSpacesIsKeptIntact() {
        let entries = PluginKitParser.parse(pluginKitFixture)
        let entry = entries.first { $0.identifier == "com.example.spacedpath.extension" }
        XCTAssertEqual(entry?.path, "/Applications/Spaced App.app/Contents/PlugIns/My Extension Name.appex")
    }

    func testGarbageLineIsSkippedNotCrashed() {
        let entries = PluginKitParser.parse(pluginKitFixture)
        XCTAssertFalse(entries.contains { $0.identifier.contains("not pluginkit output") })
    }

    func testParseCountExcludesOnlyTheGarbageLine() {
        // Nine fixture lines in, one of them pure garbage: every real line must survive parsing.
        let entries = PluginKitParser.parse(pluginKitFixture)
        XCTAssertEqual(entries.count, 8)
    }

    func testEmptyOutputParsesToNoEntries() {
        XCTAssertTrue(PluginKitParser.parse("").isEmpty)
    }

    // MARK: - Owner-app attribution

    func testOwnerAppExtractsNameFromContainingAppBundle() {
        XCTAssertEqual(
            PluginAppExtensionOwner.name(fromPath: "/Applications/Foo.app/Contents/PlugIns/x.appex"),
            "Foo"
        )
    }

    func testOwnerAppHandlesNestedAppBundles() {
        XCTAssertEqual(
            PluginAppExtensionOwner.name(fromPath: "/System/Applications/Podcasts.app/Contents/PlugIns/com.apple.podcasts.SpotlightIndexExtension.appex"),
            "Podcasts"
        )
    }

    func testOwnerAppFallsBackToSystemWhenNoAppBundleInPath() {
        XCTAssertEqual(
            PluginAppExtensionOwner.name(fromPath: "/System/Library/PrivateFrameworks/Something.framework/PlugIns/Something.appex"),
            "System"
        )
    }

    // MARK: - App extension item building (parser + owner attribution, still no disk)

    func testAppExtensionItemsAreReadOnlyWithLivesInsideDetail() {
        let items = PluginAppExtensionBuilder.buildItems(from: pluginKitFixture)
        let item = items.first { $0.name == "com.example.plain.extension" }
        XCTAssertEqual(item?.category, .appExtension)
        XCTAssertEqual(item?.owner, "PlainApp")
        XCTAssertEqual(item?.detail, "Lives inside PlainApp")
        XCTAssertEqual(item?.isRemovable, false)
        XCTAssertNil(item?.tier)
        XCTAssertEqual(item?.byteCount, 0)
    }

    func testAppExtensionItemsSortByOwnerThenName() {
        let items = PluginAppExtensionBuilder.buildItems(from: pluginKitFixture)
        let owners = items.map { $0.owner ?? "" }
        XCTAssertEqual(owners, owners.sorted(), "rows must already be grouped by owner for a stable read")
    }

    // MARK: - Category / scope / tier assignment

    func testFilesystemSurfacesCoverAllFiveInventoriedCategories() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let categories = Set(PluginSurfaceCatalog.filesystemSurfaces(home: home).map(\.category))
        XCTAssertEqual(categories, [.spotlightImporter, .quickLookGenerator, .preferencePane, .audioPlugin, .internetPlugin])
    }

    func testEveryFilesystemCategoryHasAUserAndASystemRoot() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let surfaces = PluginSurfaceCatalog.filesystemSurfaces(home: home)
        for category in [PluginCategory.spotlightImporter, .quickLookGenerator, .preferencePane, .internetPlugin] {
            let scopes = Set(surfaces.filter { $0.category == category }.map(\.scope))
            XCTAssertEqual(scopes, [.user, .system], "\(category) must scan both a user and a system root")
        }
    }

    func testAudioPluginSurfaceCoversComponentsVSTAndVST3ForBothScopes() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let audioSurfaces = PluginSurfaceCatalog.filesystemSurfaces(home: home).filter { $0.category == .audioPlugin }
        XCTAssertEqual(audioSurfaces.count, 6, "3 kinds \u{00D7} 2 scopes")
        let extensions = Set(audioSurfaces.flatMap(\.extensions))
        XCTAssertEqual(extensions, ["component", "vst", "vst3"])
    }

    func testSpotlightSurfacesPointAtTheExpectedDirectoriesAndExtension() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let surfaces = PluginSurfaceCatalog.filesystemSurfaces(home: home).filter { $0.category == .spotlightImporter }
        let userSurface = surfaces.first { $0.scope == .user }
        let systemSurface = surfaces.first { $0.scope == .system }
        XCTAssertEqual(userSurface?.directory.path, "/Users/tester/Library/Spotlight")
        XCTAssertEqual(systemSurface?.directory.path, "/Library/Spotlight")
        XCTAssertEqual(userSurface?.extensions, ["mdimporter"])
    }

    func testUserScopeIsSafeAndSystemScopeIsCaution() {
        XCTAssertEqual(PluginScope.user.tier, .safe)
        XCTAssertEqual(PluginScope.system.tier, .caution)
    }

    // MARK: - Grouping

    private func item(
        id: String,
        category: PluginCategory,
        scope: PluginScope? = .user,
        tier: SweepTier? = .safe,
        bytes: Int64 = 1_000,
        removable: Bool = true
    ) -> PluginItem {
        PluginItem(
            id: id, name: id, path: id, detail: id, owner: nil,
            category: category, scope: scope, tier: tier, byteCount: bytes, isRemovable: removable
        )
    }

    func testBuildGroupsOmitsEmptyCategoriesAndKeepsSpecOrder() {
        let items = [
            item(id: "/a", category: .audioPlugin),
            item(id: "/b", category: .spotlightImporter),
        ]
        let groups = PluginInventoryLogic.buildGroups(from: items)
        XCTAssertEqual(groups.map(\.category), [.spotlightImporter, .audioPlugin], "spec order, not insertion order")
    }

    func testBuildGroupsOnEmptyInputIsEmpty() {
        XCTAssertTrue(PluginInventoryLogic.buildGroups(from: []).isEmpty)
    }

    func testGroupTierIsTheWorstTierAmongItsItems() {
        let items = [
            item(id: "/a", category: .preferencePane, tier: .safe),
            item(id: "/b", category: .preferencePane, tier: .caution),
        ]
        let group = PluginInventoryLogic.buildGroups(from: items).first
        XCTAssertEqual(group?.tier, .caution)
    }

    func testGroupByteCountSumsItsItems() {
        let items = [
            item(id: "/a", category: .quickLookGenerator, bytes: 400),
            item(id: "/b", category: .quickLookGenerator, bytes: 600),
        ]
        let group = PluginInventoryLogic.buildGroups(from: items).first
        XCTAssertEqual(group?.byteCount, 1_000)
    }

    func testAppExtensionOnlyGroupDefaultsToSafeTierSinceItHasNoTierOpinion() {
        // `PluginsScreen` never actually renders a tier badge for this category (see its header
        // logic) — this only pins the fallback so `PluginCategoryGroup.tier` never crashes or
        // silently picks an arbitrary case when every item's tier is `nil`.
        let items = [item(id: "/a", category: .appExtension, tier: nil, removable: false)]
        let group = PluginInventoryLogic.buildGroups(from: items).first
        XCTAssertEqual(group?.tier, .safe)
    }

    // MARK: - /System exclusion

    func testIsUnderSystemMatchesTheRootAndEveryDescendant() {
        XCTAssertTrue(PluginPathPolicy.isUnderSystem("/System"))
        XCTAssertTrue(PluginPathPolicy.isUnderSystem("/System/Library/PrivateFrameworks/x.framework"))
        XCTAssertFalse(PluginPathPolicy.isUnderSystem("/Library/Spotlight/x.mdimporter"))
        XCTAssertFalse(PluginPathPolicy.isUnderSystem("/Users/tester/Library/QuickLook/x.qlgenerator"))
        XCTAssertFalse(PluginPathPolicy.isUnderSystem("/Applications/SystemThemedApp.app"), "must not match on the substring alone")
    }

    func testExcludingSystemDropsOnlySystemRows() {
        let items = [
            item(id: "/Library/Spotlight/a.mdimporter", category: .spotlightImporter),
            item(id: "/System/Library/PrivateFrameworks/b.framework/PlugIns/b.appex", category: .appExtension, scope: nil, tier: nil, removable: false),
        ]
        let survivors = PluginInventoryLogic.excludingSystem(items)
        XCTAssertEqual(survivors.map(\.id), ["/Library/Spotlight/a.mdimporter"])
    }

    func testAppExtensionsUnderSystemAreExcludedEndToEnd() {
        let items = PluginAppExtensionBuilder.buildItems(from: pluginKitFixture)
        let survivors = PluginInventoryLogic.excludingSystem(items)
        XCTAssertTrue(items.contains { PluginPathPolicy.isUnderSystem($0.path) }, "fixture must actually exercise a /System row")
        XCTAssertFalse(survivors.contains { PluginPathPolicy.isUnderSystem($0.path) })
        XCTAssertEqual(survivors.count, items.count - 1)
    }

    // MARK: - Removal outcome shape (no disk: this only checks the non-removable refusal path)

    func testRemovalRefusesANonRemovableItemWithoutTouchingDisk() {
        let readOnlyItem = item(id: "/Applications/Foo.app/Contents/PlugIns/x.appex", category: .appExtension, scope: nil, tier: nil, removable: false)
        let outcome = PluginRemovalService.trash(readOnlyItem)
        XCTAssertEqual(outcome, .failed("this item lives inside its owning app and cannot be removed from here"))
    }
}
