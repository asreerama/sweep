import XCTest
@testable import SweepUninstall

/// Regression coverage for finding #11 in the adversarial review: `LeftoverMatcher.candidates`
/// previously evaluated ownership against only the single target app, so an exact bundle-id-name
/// match got promoted to `.autoSelectable` even when another installed app (same vendor, same
/// signing team, or an independent name match) could plausibly also depend on the same item.
final class AmbiguousOwnershipTests: XCTestCase {
    /// The concrete scenario named in the review: two Adobe products installed
    /// (`com.adobe.photoshop`, `com.adobe.bridge`) plus a shared "Common Files" utility whose own
    /// Application Support folder happens to equal its bundle id verbatim. Even though that
    /// folder is an exact bundle-id match for the app being evaluated, the shared "com.adobe"
    /// vendor prefix across three installed apps must cap it at `.manualReview`.
    func testVendorSiblingCapsExactMatchToManualReview() throws {
        let tree = try LeftoverFixture.buildSingleApplicationSupportFolder(named: "com.adobe.CommonFiles")
        defer { LeftoverFixture.tearDown(tree) }

        let installedApps = [
            LeftoverFixture.adobeCommonFilesApp,
            LeftoverFixture.adobePhotoshopApp,
            LeftoverFixture.adobeBridgeApp,
        ]

        let candidates = tree.candidates(
            for: LeftoverFixture.adobeCommonFilesApp,
            roots: [.applicationSupport],
            installedApps: installedApps
        )

        let match = try XCTUnwrap(candidates.first { $0.url.lastPathComponent == "com.adobe.CommonFiles" })
        XCTAssertTrue(match.evidence.contains(.exactBundleID), "the folder name is still an exact bundle-id match")
        XCTAssertTrue(match.evidence.contains(.ambiguousOwner), "a shared vendor namespace with 2 other installed apps must be flagged")
        XCTAssertEqual(match.confidence, .manualReview, "must never be auto-selectable while sibling Adobe apps are installed")
    }

    /// Without any sibling from the same vendor installed, the same exact match is safe to
    /// auto-select — the cap is specifically about ambiguity, not a blanket downgrade.
    func testExactMatchStaysAutoSelectableWithoutVendorSiblings() throws {
        let tree = try LeftoverFixture.buildSingleApplicationSupportFolder(named: "com.example.foo")
        defer { LeftoverFixture.tearDown(tree) }

        let candidates = tree.candidates(for: LeftoverFixture.fooApp, roots: [.applicationSupport], installedApps: [LeftoverFixture.fooApp])

        let match = try XCTUnwrap(candidates.first { $0.url.lastPathComponent == "com.example.foo" })
        XCTAssertFalse(match.evidence.contains(.ambiguousOwner))
        XCTAssertEqual(match.confidence, .autoSelectable)
    }

    /// Passing no inventory at all (the default) must never spuriously trigger ambiguity — this
    /// is also exactly what every pre-existing `LeftoverMatcherTests` call relies on.
    func testEmptyInstalledAppsNeverTriggersAmbiguity() throws {
        let tree = try LeftoverFixture.buildSingleApplicationSupportFolder(named: "com.example.foo")
        defer { LeftoverFixture.tearDown(tree) }

        let candidates = tree.candidates(for: LeftoverFixture.fooApp, roots: [.applicationSupport])
        let match = try XCTUnwrap(candidates.first { $0.url.lastPathComponent == "com.example.foo" })
        XCTAssertFalse(match.evidence.contains(.ambiguousOwner))
        XCTAssertEqual(match.confidence, .autoSelectable)
    }

    /// Two installed apps with completely unrelated bundle-id vendor prefixes, but the same
    /// code-signing team identifier: the shared-team signal alone must cap confidence, even
    /// though the textual "com.vendor" prefix check would miss this case entirely.
    func testSharedTeamIdentifierAcrossUnrelatedVendorPrefixesCapsConfidence() throws {
        let target = InstalledApp(
            bundleIdentifier: "com.example.foo",
            name: "Foo",
            shortVersion: "1.0",
            buildVersion: "1",
            bundlePath: URL(fileURLWithPath: "/Applications/Foo.app"),
            teamIdentifier: "SHAREDTEAM",
            signingIdentifier: nil,
            isAppleSigned: false,
            isSystemLocation: false
        )
        let otherVendorSameTeam = InstalledApp(
            bundleIdentifier: "net.other.bar",
            name: "Bar",
            shortVersion: "1.0",
            buildVersion: "1",
            bundlePath: URL(fileURLWithPath: "/Applications/Bar.app"),
            teamIdentifier: "SHAREDTEAM",
            signingIdentifier: nil,
            isAppleSigned: false,
            isSystemLocation: false
        )

        let tree = try LeftoverFixture.buildSingleApplicationSupportFolder(named: "com.example.foo")
        defer { LeftoverFixture.tearDown(tree) }

        let candidates = tree.candidates(for: target, roots: [.applicationSupport], installedApps: [target, otherVendorSameTeam])
        let match = try XCTUnwrap(candidates.first { $0.url.lastPathComponent == "com.example.foo" })
        XCTAssertTrue(match.evidence.contains(.ambiguousOwner))
        XCTAssertEqual(match.confidence, .manualReview)
    }

    /// A candidate discovered purely through a DISPLAY-NAME match (not a bundle-id match) to
    /// `target`, whose name also happens to equal a completely unrelated installed app's bundle
    /// id, must still be flagged ambiguous — isolating rule (b) ("the candidate matches another
    /// installed app's bundle id/prefix") from the vendor-prefix and team-sharing signals: the
    /// two apps here share neither a vendor prefix nor a team id.
    func testCandidateNameMatchingAnotherInstalledAppCapsConfidence() throws {
        let target = InstalledApp(
            bundleIdentifier: "com.example.foo",
            name: "Foo",
            shortVersion: "1.0",
            buildVersion: "1",
            bundlePath: URL(fileURLWithPath: "/Applications/Foo.app"),
            teamIdentifier: nil,
            signingIdentifier: nil,
            isAppleSigned: false,
            isSystemLocation: false
        )
        // A single-component "bundle id" with no relation to `com.example.*` at all, so neither
        // the vendor-prefix nor team-identifier signal can explain the flag below.
        let unrelatedApp = InstalledApp(
            bundleIdentifier: "foo",
            name: "Unrelated Foo Tool",
            shortVersion: "1.0",
            buildVersion: "1",
            bundlePath: URL(fileURLWithPath: "/Applications/Unrelated Foo Tool.app"),
            teamIdentifier: nil,
            signingIdentifier: nil,
            isAppleSigned: false,
            isSystemLocation: false
        )

        // Named after `target`'s DISPLAY NAME ("Foo"), not its bundle id, so this candidate is
        // discovered via `.nameMatch` alone — its evaluation against `target` never touches
        // `target`'s bundle id string, keeping this test isolated from rule (a)/(c).
        let tree = try LeftoverFixture.buildSingleApplicationSupportFolder(named: "Foo")
        defer { LeftoverFixture.tearDown(tree) }

        let candidates = tree.candidates(for: target, roots: [.applicationSupport], installedApps: [target, unrelatedApp])
        let match = try XCTUnwrap(candidates.first { $0.url.lastPathComponent == "Foo" })
        XCTAssertEqual(match.evidence.subtracting(.ambiguousOwner), [.nameMatch], "sanity check: discovered via name match, not bundle id")
        XCTAssertTrue(match.evidence.contains(.ambiguousOwner), "\"Foo\" is also an exact match for the unrelated installed app's bundle id \"foo\"")
        XCTAssertEqual(match.confidence, .manualReview)
    }
}

/// Regression coverage for finding #12: receipt identifier relationships that are only a
/// component-prefix match in either direction must never produce `.receiptListed` (the only
/// receipt-derived evidence `MatchConfidence.derive` promotes to `.autoSelectable`).
final class ReceiptPrefixMatchingTests: XCTestCase {
    private struct FakeReceipts: PkgutilReceiptsProviding {
        let packageIDs: [String]
        let filesByPackageID: [String: [String]]
        init(packageIDs: [String], filesByPackageID: [String: [String]] = [:]) {
            self.packageIDs = packageIDs
            self.filesByPackageID = filesByPackageID
        }
        func packageIdentifiers() -> [String] { packageIDs }
        func files(forPackageID id: String) -> [String] { filesByPackageID[id] ?? [] }
    }

    private func app(bundleID: String, bundleName: String = "App.app") -> InstalledApp {
        InstalledApp(
            bundleIdentifier: bundleID,
            name: bundleName,
            shortVersion: "1.0",
            buildVersion: "1",
            bundlePath: URL(fileURLWithPath: "/Applications/\(bundleName)"),
            teamIdentifier: nil,
            signingIdentifier: nil,
            isAppleSigned: false,
            isSystemLocation: false
        )
    }

    /// Direction 1: a broad suite receipt (`com.vendor`) for a specific product
    /// (`com.vendor.product`).
    func testBroadReceiptForNarrowCandidateIsPrefixMatchNotExact() throws {
        let target = app(bundleID: "com.vendor.product")
        let receipts = FakeReceipts(packageIDs: ["com.vendor"])

        let candidates = LeftoverMatcher.candidates(
            for: target,
            roots: [.pkgReceipt],
            receipts: receipts
        )

        let match = try XCTUnwrap(candidates.first)
        XCTAssertEqual(match.evidence, [.receiptPrefixMatch])
        XCTAssertFalse(match.evidence.contains(.receiptListed))
        XCTAssertEqual(match.confidence, .manualReview)
    }

    /// Direction 2 (the inverse): a narrow, product-specific receipt (`com.vendor.product.extra`)
    /// for a broader app id (`com.vendor.product`).
    func testNarrowReceiptForBroaderCandidateIsPrefixMatchNotExact() throws {
        let target = app(bundleID: "com.vendor.product")
        let receipts = FakeReceipts(packageIDs: ["com.vendor.product.extra"])

        let candidates = LeftoverMatcher.candidates(
            for: target,
            roots: [.pkgReceipt],
            receipts: receipts
        )

        let match = try XCTUnwrap(candidates.first)
        XCTAssertEqual(match.evidence, [.receiptPrefixMatch])
        XCTAssertFalse(match.evidence.contains(.receiptListed))
        XCTAssertEqual(match.confidence, .manualReview)
    }

    /// Control: an exact receipt id match is untouched by this change — still `.receiptListed`,
    /// still auto-selectable.
    func testExactReceiptIdentifierIsStillAutoSelectable() throws {
        let target = app(bundleID: "com.vendor.product")
        let receipts = FakeReceipts(packageIDs: ["com.vendor.product"])

        let candidates = LeftoverMatcher.candidates(
            for: target,
            roots: [.pkgReceipt],
            receipts: receipts
        )

        let match = try XCTUnwrap(candidates.first)
        XCTAssertEqual(match.evidence, [.receiptListed])
        XCTAssertEqual(match.confidence, .autoSelectable)
    }

    /// Control: `pkgutil --files` proof the receipt installed the exact app bundle is still
    /// strong (`.receiptListed`) evidence even though the package id itself is only a
    /// prefix-level relationship.
    func testFilesProofUpgradesAPrefixOnlyReceiptToReceiptListed() throws {
        let target = app(bundleID: "com.vendor.product", bundleName: "Product.app")
        let receipts = FakeReceipts(
            packageIDs: ["com.vendor"],
            filesByPackageID: ["com.vendor": ["./Applications/Product.app"]]
        )

        let candidates = LeftoverMatcher.candidates(
            for: target,
            roots: [.pkgReceipt],
            receipts: receipts
        )

        let match = try XCTUnwrap(candidates.first)
        XCTAssertEqual(match.evidence, [.receiptListed])
        XCTAssertEqual(match.confidence, .autoSelectable)
    }

    /// A completely unrelated package id produces no candidate at all.
    func testUnrelatedReceiptProducesNoCandidate() {
        let target = app(bundleID: "com.vendor.product")
        let receipts = FakeReceipts(packageIDs: ["com.totally.unrelated"])

        let candidates = LeftoverMatcher.candidates(for: target, roots: [.pkgReceipt], receipts: receipts)
        XCTAssertTrue(candidates.isEmpty)
    }
}
