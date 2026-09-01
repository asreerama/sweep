import XCTest
@testable import SweepUninstall

final class LeftoverMatcherTests: XCTestCase {
    var tree: LeftoverFixture.Tree!

    override func setUpWithError() throws {
        tree = try LeftoverFixture.build()
    }

    override func tearDown() {
        LeftoverFixture.tearDown(tree)
        tree = nil
    }

    // MARK: - True positives

    func testExactBundleIDMatchAcrossStandardRoots() {
        let candidates = tree.candidates(for: LeftoverFixture.fooApp)
        let exactRoots: [SearchRoot] = [.applicationSupport, .caches, .preferences, .containers, .webKit, .httpStorages]
        for root in exactRoots {
            let matchesInRoot = candidates.filter { $0.root == root && $0.evidence.contains(.exactBundleID) }
            XCTAssertFalse(matchesInRoot.isEmpty, "expected an exact bundle id match for com.example.foo under \(root)")
        }
    }

    func testSavedApplicationStateSuffixIsPrefixMatchNotExact() {
        // "com.example.foo.savedState" is not literally the bundle id — it's the bundle id
        // plus macOS's own ".savedState" suffix — so this is prefix evidence, same tier as a
        // LaunchAgent's ".helper" suffix, not an exact match.
        let candidates = tree.candidates(for: LeftoverFixture.fooApp)
        let match = candidates.first { $0.root == .savedApplicationState }
        XCTAssertNotNil(match, "expected com.example.foo.savedState to be discovered")
        XCTAssertEqual(match?.evidence, [.prefixMatch])
        XCTAssertEqual(match?.confidence, .manualReview)
    }

    func testExactMatchesAreAutoSelectable() {
        let candidates = tree.candidates(for: LeftoverFixture.fooApp)
        let exact = candidates.filter { $0.evidence.contains(.exactBundleID) }
        XCTAssertFalse(exact.isEmpty)
        for candidate in exact {
            XCTAssertEqual(candidate.confidence, .autoSelectable, "\(candidate.url.path) should be auto-selectable")
        }
    }

    func testLaunchAgentHelperSuffixIsPrefixMatch() {
        let candidates = tree.candidates(for: LeftoverFixture.fooApp)
        let match = candidates.first { $0.root == .launchAgents }
        XCTAssertNotNil(match, "expected com.example.foo.helper.plist to be discovered")
        XCTAssertEqual(match?.evidence, [.prefixMatch])
        XCTAssertEqual(match?.confidence, .manualReview)
    }

    func testLaunchDaemonIsAlwaysManualReviewEvenOnPrefixMatch() {
        let candidates = tree.candidates(for: LeftoverFixture.fooApp)
        let match = candidates.first { $0.root == .libraryLaunchDaemons }
        XCTAssertNotNil(match, "expected the LaunchDaemons fixture entry to be discovered")
        XCTAssertEqual(match?.evidence, [.launchDaemon])
        XCTAssertEqual(match?.confidence, .manualReview)
    }

    func testGroupContainerIsAlwaysManualReviewEvenOnExactMatch() {
        let candidates = tree.candidates(for: LeftoverFixture.fooApp)
        let match = candidates.first { $0.root == .groupContainers }
        XCTAssertNotNil(match, "expected group.com.example.foo to be discovered")
        XCTAssertEqual(match?.evidence, [.sharedGroupContainer])
        XCTAssertEqual(match?.confidence, .manualReview)
    }

    // MARK: - Adversarial traps

    func testNameCollisionTrapIsRejected() {
        let candidates = tree.candidates(for: LeftoverFixture.fooApp)
        XCTAssertFalse(
            candidates.contains { $0.url.lastPathComponent.hasPrefix("com.example.foobar") },
            "com.example.foobar leftovers must never be attributed to com.example.foo despite the shared 'com.example.foo' prefix substring"
        )
    }

    func testVSCodeDoesNotClaimInsidersFolder() {
        let candidates = tree.candidates(for: LeftoverFixture.vsCodeApp)
        XCTAssertFalse(
            candidates.contains { $0.url.lastPathComponent == "Code - Insiders" },
            "VS Code must never claim the Insiders folder"
        )
    }

    func testInsidersDoesNotClaimPlainCodeFolder() {
        let candidates = tree.candidates(for: LeftoverFixture.vsCodeInsidersApp)
        XCTAssertFalse(
            candidates.contains { $0.url.lastPathComponent == "Code" },
            "Insiders must never claim the plain VS Code folder"
        )
    }

    func testVSCodeClaimsItsOwnCodeFolderViaConditions() {
        let candidates = tree.candidates(for: LeftoverFixture.vsCodeApp)
        XCTAssertTrue(candidates.contains { $0.url.lastPathComponent == "Code" }, "VS Code should still find its own Application Support/Code folder")
    }

    func testInsidersClaimsItsOwnFolderViaConditions() {
        let candidates = tree.candidates(for: LeftoverFixture.vsCodeInsidersApp)
        XCTAssertTrue(candidates.contains { $0.url.lastPathComponent == "Code - Insiders" })
    }

    // MARK: - Evidence / confidence classification

    func testNameOnlyMatchesAreNeverAutoSelectable() {
        let candidates = tree.candidates(for: LeftoverFixture.vsCodeApp) + tree.candidates(for: LeftoverFixture.vsCodeInsidersApp)
        let nameOnly = candidates.filter { $0.evidence == [.nameMatch] }
        XCTAssertFalse(nameOnly.isEmpty)
        for candidate in nameOnly {
            XCTAssertEqual(candidate.confidence, .manualReview)
        }
    }

    func testOnlyExactBundleIDOrReceiptListedCanBeAutoSelectable() {
        let apps = [LeftoverFixture.fooApp, LeftoverFixture.vsCodeApp, LeftoverFixture.vsCodeInsidersApp]
        var sawAutoSelectable = false
        for app in apps {
            for candidate in tree.candidates(for: app) where candidate.confidence == .autoSelectable {
                sawAutoSelectable = true
                XCTAssertTrue(candidate.evidence.contains(.exactBundleID) || candidate.evidence.contains(.receiptListed))
                XCTAssertFalse(candidate.evidence.contains(.sharedGroupContainer))
                XCTAssertFalse(candidate.evidence.contains(.launchDaemon))
            }
        }
        XCTAssertTrue(sawAutoSelectable, "expected at least one auto-selectable candidate across fixtures")
    }
}
