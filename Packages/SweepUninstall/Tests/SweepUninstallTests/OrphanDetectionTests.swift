import XCTest
@testable import SweepUninstall

final class OrphanDetectionTests: XCTestCase {
    var tree: LeftoverFixture.Tree!

    override func setUpWithError() throws {
        tree = try LeftoverFixture.build()
    }

    override func tearDown() {
        LeftoverFixture.tearDown(tree)
        tree = nil
    }

    private let installed: Set<String> = ["com.example.foo", "com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]

    func testPlantedOrphanIsFlagged() {
        let orphans = tree.orphanCandidates(installedBundleIDs: installed)
        XCTAssertTrue(orphans.contains { $0.apparentBundleID == "com.orphan.tool" })
    }

    func testInstalledAppLeftoversAreNeverFlaggedAsOrphans() {
        let orphans = tree.orphanCandidates(installedBundleIDs: installed)
        XCTAssertFalse(orphans.contains { $0.apparentBundleID.hasPrefix("com.example.foo") && !$0.apparentBundleID.hasPrefix("com.example.foobar") },
                        "leftovers of an installed app must never surface as orphans")
        // The LaunchAgents / LaunchDaemons suffix variants (".helper", ".daemon") extend the
        // installed bundle id by whole components — still owned, not orphaned.
        XCTAssertFalse(orphans.contains { $0.apparentBundleID == "com.example.foo.helper" })
        XCTAssertFalse(orphans.contains { $0.apparentBundleID == "com.example.foo.daemon" })
    }

    func testOrphanCandidatesAlwaysReportOrphanConfidence() {
        let orphans = tree.orphanCandidates(installedBundleIDs: installed)
        XCTAssertFalse(orphans.isEmpty)
        for orphan in orphans {
            XCTAssertEqual(orphan.confidence, .orphan)
        }
    }

    func testHelperToolFalsePositiveIsFlagged() {
        let orphans = tree.orphanCandidates(installedBundleIDs: installed)
        let updater = orphans.first { $0.apparentBundleID == "com.orphan.updater" }
        XCTAssertNotNil(updater)
        XCTAssertTrue(updater?.isLikelyHelperTool ?? false, "'com.orphan.updater' should be flagged as a likely helper-tool false positive")

        let tool = orphans.first { $0.apparentBundleID == "com.orphan.tool" }
        XCTAssertNotNil(tool)
        XCTAssertFalse(tool?.isLikelyHelperTool ?? true, "'com.orphan.tool' has no helper-tool fragment and should not be flagged")
    }

    func testNameCollisionTrapIsCorrectlyOrphanedRatherThanSilentlyDropped() {
        // "com.example.foobar" is neither owned by any installed app in this fixture nor
        // matched to com.example.foo (see LeftoverMatcherTests) — it must still surface,
        // just correctly attributed as unowned instead of disappearing.
        let orphans = tree.orphanCandidates(installedBundleIDs: installed)
        XCTAssertTrue(orphans.contains { $0.apparentBundleID == "com.example.foobar" })
    }
}
