import XCTest
@testable import SweepUninstall

final class OwnershipEvidenceTests: XCTestCase {
    func testExactBundleIDAloneIsAutoSelectable() {
        XCTAssertEqual(MatchConfidence.derive(from: [.exactBundleID]), .autoSelectable)
    }

    func testReceiptListedAloneIsAutoSelectable() {
        XCTAssertEqual(MatchConfidence.derive(from: [.receiptListed]), .autoSelectable)
    }

    func testPrefixMatchAloneIsManualReview() {
        XCTAssertEqual(MatchConfidence.derive(from: [.prefixMatch]), .manualReview)
    }

    func testNameMatchAloneIsManualReview() {
        XCTAssertEqual(MatchConfidence.derive(from: [.nameMatch]), .manualReview)
    }

    func testSharedGroupContainerCapsConfidenceEvenWithExactBundleID() {
        XCTAssertEqual(MatchConfidence.derive(from: [.exactBundleID, .sharedGroupContainer]), .manualReview)
    }

    func testLaunchDaemonCapsConfidenceEvenWithReceiptListed() {
        XCTAssertEqual(MatchConfidence.derive(from: [.receiptListed, .launchDaemon]), .manualReview)
    }

    func testEmptyEvidenceIsOrphan() {
        XCTAssertEqual(MatchConfidence.derive(from: []), .orphan)
    }
}

final class BundleIDMatchTests: XCTestCase {
    func testExactRequiresAllComponentsEqual() {
        XCTAssertTrue(BundleIDMatch.isExact("com.example.foo", bundleID: "com.example.foo"))
        XCTAssertTrue(BundleIDMatch.isExact("COM.EXAMPLE.FOO", bundleID: "com.example.foo"), "comparison is case-insensitive")
        XCTAssertFalse(BundleIDMatch.isExact("com.example.foobar", bundleID: "com.example.foo"))
    }

    func testComponentPrefixRequiresWholeTrailingComponents() {
        XCTAssertTrue(BundleIDMatch.isComponentPrefix("com.example.foo.helper", bundleID: "com.example.foo"))
        XCTAssertFalse(BundleIDMatch.isComponentPrefix("com.example.foobar", bundleID: "com.example.foo"),
                       "same component count, differing final component, must not be treated as a prefix")
        XCTAssertFalse(BundleIDMatch.isComponentPrefix("com.example.foo", bundleID: "com.example.foo.helper"),
                       "must be one-directional: shorter-than-bundleID is never a prefix match")
    }

    func testComponentPrefixRejectsTooShortBundleID() {
        // A single-component "bundle id" (no real reverse-DNS specificity) must not turn every
        // longer name into a prefix match.
        XCTAssertFalse(BundleIDMatch.isComponentPrefix("com.anything.at.all", bundleID: "com"))
    }
}

final class NameNormalizationTests: XCTestCase {
    func testAlphanumericDropsPunctuationAndLowercases() {
        XCTAssertEqual(NameNormalization.alphanumeric("Visual Studio Code - Insiders"), "visualstudiocodeinsiders")
        XCTAssertEqual(NameNormalization.alphanumeric("Code - Insiders"), "codeinsiders")
        XCTAssertEqual(NameNormalization.alphanumeric("Code"), "code")
    }

    func testStemStripsExtensionOnly() {
        XCTAssertEqual(NameNormalization.stem(of: URL(fileURLWithPath: "/Applications/Xcode.app")), "Xcode")
        XCTAssertEqual(NameNormalization.stem(of: URL(fileURLWithPath: "/tmp/com.example.foo.plist")), "com.example.foo")
    }
}

final class ConditionsTableTests: XCTestCase {
    func testXcodeConditionExcludesKnownThirdPartyTools() {
        let conditions = ConditionsTable.conditions(for: "com.apple.dt.xcode")
        XCTAssertTrue(conditions.contains { $0.excludeNameFragments.contains(NameNormalization.alphanumeric("xcodes")) })
        XCTAssertTrue(conditions.contains { $0.excludeNameFragments.contains(NameNormalization.alphanumeric("Cleaner for Xcode")) })
    }

    func testUnknownBundleIDHasNoConditions() {
        XCTAssertTrue(ConditionsTable.conditions(for: "com.totally.unknown.app").isEmpty)
    }

    func testNilOrEmptyBundleIDHasNoConditions() {
        XCTAssertTrue(ConditionsTable.conditions(for: nil).isEmpty)
        XCTAssertTrue(ConditionsTable.conditions(for: "").isEmpty)
    }
}
