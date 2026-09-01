import Foundation
import SweepUninstall
import XCTest
@testable import SweepApp

/// Pure logic behind the Uninstaller screen (module 5, PLAN §3, AppCleaner parity): app
/// filter/sort, the protection check, on-disk size measurement, and leftover-evidence grouping.
/// `UninstallModel` itself (the `@Observable` driver) is exercised only indirectly here — its
/// bodies are thin wiring over exactly these functions, same split the rest of the app uses
/// (`LargeOldFilesLogicTests`, `StartupItemsLogicTests`).
final class UninstallerLogicTests: XCTestCase {

    // MARK: - Fixtures

    private func app(
        id name: String = "Example",
        bundleID: String? = "com.example.app",
        path: String? = nil,
        appleSigned: Bool = false,
        systemLocation: Bool = false
    ) -> InstalledApp {
        InstalledApp(
            bundleIdentifier: bundleID,
            name: name,
            shortVersion: "1.0",
            buildVersion: "1",
            bundlePath: URL(fileURLWithPath: path ?? "/Applications/\(name).app"),
            teamIdentifier: nil,
            signingIdentifier: nil,
            isAppleSigned: appleSigned,
            isSystemLocation: systemLocation
        )
    }

    // MARK: - Filtering

    func testFilterAppsMatchesNameCaseInsensitively() {
        let apps = [app(id: "Photoshop"), app(id: "Xcode", bundleID: "com.apple.dt.xcode")]
        XCTAssertEqual(UninstallLogic.filterApps(apps, query: "photo").map(\.name), ["Photoshop"])
    }

    func testFilterAppsMatchesBundleIdentifier() {
        let apps = [app(id: "Photoshop", bundleID: "com.adobe.photoshop"), app(id: "Xcode", bundleID: "com.apple.dt.xcode")]
        XCTAssertEqual(UninstallLogic.filterApps(apps, query: "apple.dt").map(\.name), ["Xcode"])
    }

    func testEmptyQueryReturnsEverything() {
        let apps = [app(id: "A"), app(id: "B")]
        XCTAssertEqual(UninstallLogic.filterApps(apps, query: "  ").count, 2)
    }

    // MARK: - Sorting

    func testSortByNameAscendingAndDescending() {
        let apps = [app(id: "Zeta"), app(id: "Alpha"), app(id: "Mu")]
        XCTAssertEqual(
            UninstallLogic.sortApps(apps, field: .name, ascending: true, sizeByPath: [:], lastUsedByPath: [:]).map(\.name),
            ["Alpha", "Mu", "Zeta"]
        )
        XCTAssertEqual(
            UninstallLogic.sortApps(apps, field: .name, ascending: false, sizeByPath: [:], lastUsedByPath: [:]).map(\.name),
            ["Zeta", "Mu", "Alpha"]
        )
    }

    func testSortBySizePushesUnknownSizesLast() {
        let known = app(id: "Known")
        let unknown = app(id: "Unknown")
        let sizeByPath = [known.id: Int64(1_000)]
        let sorted = UninstallLogic.sortApps(
            [unknown, known], field: .size, ascending: true, sizeByPath: sizeByPath, lastUsedByPath: [:]
        )
        XCTAssertEqual(sorted.map(\.name), ["Known", "Unknown"], "unknown size sorts last regardless of direction")

        let sortedDescending = UninstallLogic.sortApps(
            [unknown, known], field: .size, ascending: false, sizeByPath: sizeByPath, lastUsedByPath: [:]
        )
        XCTAssertEqual(sortedDescending.map(\.name), ["Known", "Unknown"])
    }

    func testSortBySizeOrdersLargestLastWhenAscending() {
        let small = app(id: "Small")
        let large = app(id: "Large")
        let sizeByPath = [small.id: Int64(10), large.id: Int64(1_000_000)]
        let sorted = UninstallLogic.sortApps([large, small], field: .size, ascending: true, sizeByPath: sizeByPath, lastUsedByPath: [:])
        XCTAssertEqual(sorted.map(\.name), ["Small", "Large"])
    }

    func testSortByLastUsedPushesUnknownLast() {
        let recent = app(id: "Recent")
        let never = app(id: "NeverTracked")
        let lastUsedByPath = [recent.id: Date()]
        let sorted = UninstallLogic.sortApps(
            [never, recent], field: .lastUsed, ascending: false, sizeByPath: [:], lastUsedByPath: lastUsedByPath
        )
        XCTAssertEqual(sorted.map(\.name), ["Recent", "NeverTracked"])
    }

    // MARK: - Protection

    func testAppleSignedAppIsProtected() {
        XCTAssertTrue(UninstallLogic.isProtected(app(appleSigned: true), sweepBundleIdentifier: nil))
    }

    func testSystemLocationAppIsProtected() {
        XCTAssertTrue(UninstallLogic.isProtected(app(systemLocation: true), sweepBundleIdentifier: nil))
    }

    func testSweepItselfIsProtected() {
        let sweep = app(id: "Sweep", bundleID: "com.aditya.sweep")
        XCTAssertTrue(UninstallLogic.isProtected(sweep, sweepBundleIdentifier: "com.aditya.sweep"))
    }

    func testOrdinaryThirdPartyAppIsNotProtected() {
        XCTAssertFalse(UninstallLogic.isProtected(app(path: "/Applications/Ordinary.app"), sweepBundleIdentifier: "com.aditya.sweep"))
    }

    /// Defense in depth for a real gap found on this machine: `SweepUninstall`'s own
    /// `isAppleSigned`/`isSystemLocation` both came back false for the real, installed
    /// `/Applications/Safari.app` (a macOS 26 cryptex-relocated symlink) — see
    /// `testRealSafariOnThisMachineIsProtectedDespiteUpstreamHeuristicGaps` below for the
    /// end-to-end proof against the actual bundle.
    func testAppleBundleIdentifierPrefixIsProtectedEvenWithoutTheUpstreamSignals() {
        let apple = app(id: "Safari", bundleID: "com.apple.Safari", path: "/Applications/Safari.app")
        XCTAssertTrue(UninstallLogic.isProtected(apple, sweepBundleIdentifier: "com.aditya.sweep"))
    }

    func testNonAppleBundleIdentifierIsUnaffectedByThePrefixCheck() {
        let thirdParty = app(id: "NotApple", bundleID: "com.example.notapple", path: "/Applications/NotApple.app")
        XCTAssertFalse(UninstallLogic.isProtected(thirdParty, sweepBundleIdentifier: "com.aditya.sweep"))
    }

    /// End-to-end proof against the real bundle the gap was found against: `AppInventory.scan`'s
    /// own `isAppleSigned`/`isSystemLocation` for this exact machine's Safari are asserted false
    /// first, specifically so this test fails loudly (rather than silently passing for the wrong
    /// reason) the day either upstream heuristic starts correctly catching it on its own.
    func testRealSafariOnThisMachineIsProtectedDespiteUpstreamHeuristicGaps() throws {
        let safariPath = "/Applications/Safari.app"
        guard FileManager.default.fileExists(atPath: safariPath) else {
            throw XCTSkip("Safari.app not present in /Applications on this machine")
        }
        let apps = AppInventory.scan(directories: [URL(fileURLWithPath: "/Applications")])
        guard let safari = apps.first(where: { $0.bundlePath.path == safariPath }) else {
            throw XCTSkip("Safari.app not discovered by AppInventory.scan on this machine")
        }
        XCTAssertFalse(safari.isAppleSigned, "documents the upstream gap this test defends against; remove this line if it starts failing")
        XCTAssertFalse(safari.isSystemLocation, "documents the upstream gap this test defends against; remove this line if it starts failing")
        XCTAssertTrue(UninstallLogic.isProtected(safari, sweepBundleIdentifier: "com.aditya.sweep"))
    }

    // MARK: - File size

    func testAllocatedSizeOfMissingPathIsZero() {
        let missing = URL(fileURLWithPath: "/private/tmp/sweep-uninstaller-tests-missing-\(UUID().uuidString)")
        XCTAssertEqual(FileSizeCalculator.allocatedSize(at: missing), 0)
    }

    func testAllocatedSizeSumsFilesInADirectoryTree() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-uninstaller-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0x41, count: 5_000).write(to: root.appendingPathComponent("a.bin"))
        let nested = root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 7_000).write(to: nested.appendingPathComponent("b.bin"))

        let size = FileSizeCalculator.allocatedSize(at: root)
        // Allocated size is block-rounded (APFS), so it is never less than the logical total.
        XCTAssertGreaterThanOrEqual(size, 12_000)
    }

    func testAllocatedSizeOfASingleFile() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-uninstaller-tests-\(UUID().uuidString).bin")
        try Data(repeating: 0x43, count: 2_000).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertGreaterThanOrEqual(FileSizeCalculator.allocatedSize(at: file), 2_000)
    }

    // MARK: - Leftover grouping

    func testBucketPrecedencePrefersAmbiguousOwnerOverEverythingElse() {
        let evidence: OwnershipEvidence = [.exactBundleID, .receiptListed, .ambiguousOwner]
        XCTAssertEqual(LeftoverGrouping.bucket(for: evidence), .possiblyShared)
    }

    func testBucketPrecedenceSharedContainerBeforeExactMatch() {
        XCTAssertEqual(LeftoverGrouping.bucket(for: [.sharedGroupContainer, .exactBundleID]), .sharedContainer)
    }

    func testBucketExactBundleIDAlone() {
        XCTAssertEqual(LeftoverGrouping.bucket(for: [.exactBundleID]), .exactMatch)
    }

    func testBucketReceiptListedAlone() {
        XCTAssertEqual(LeftoverGrouping.bucket(for: [.receiptListed]), .receipt)
    }

    func testBucketPrefixAndReceiptPrefixShareABucket() {
        XCTAssertEqual(LeftoverGrouping.bucket(for: [.prefixMatch]), .prefixMatch)
        XCTAssertEqual(LeftoverGrouping.bucket(for: [.receiptPrefixMatch]), .prefixMatch)
    }

    func testBucketNameMatchFallback() {
        XCTAssertEqual(LeftoverGrouping.bucket(for: [.nameMatch]), .nameMatch)
    }

    func testOnlyExactAndReceiptKindsArePreselectedByDefault() {
        for kind in LeftoverGroupKind.allCases {
            let expected = kind == .exactMatch || kind == .receipt
            XCTAssertEqual(kind.isPreselectedByDefault, expected, "\(kind) preselection")
        }
    }

    func testGroupsBuildsOneGroupPerBucketAndPreselectsOnlyExactAndReceipt() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let candidates = [
            LeftoverCandidate(
                url: home.appendingPathComponent("Library/Caches/com.example.app"),
                root: .caches, attributedBundleID: "com.example.app", evidence: [.exactBundleID]
            ),
            LeftoverCandidate(
                url: home.appendingPathComponent("Library/Application Support/ExampleApp"),
                root: .applicationSupport, attributedBundleID: "com.example.app", evidence: [.nameMatch]
            ),
        ]
        let groups = LeftoverGrouping.groups(for: candidates, home: home)
        XCTAssertEqual(Set(groups.map(\.id)), [LeftoverGroupKind.exactMatch.rawValue, LeftoverGroupKind.nameMatch.rawValue])

        let selection = LeftoverGrouping.preselectedIDs(in: groups)
        XCTAssertTrue(selection.contains(candidates[0].id))
        XCTAssertFalse(selection.contains(candidates[1].id))
    }

    func testGroupsNeverProduceAnOrphanBucket() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let candidate = LeftoverCandidate(
            url: home.appendingPathComponent("Library/Caches/com.example.app"),
            root: .caches, attributedBundleID: "com.example.app", evidence: [.exactBundleID]
        )
        let groups = LeftoverGrouping.groups(for: [candidate], home: home)
        XCTAssertFalse(groups.contains { $0.id == LeftoverGroupKind.orphan.rawValue })
    }

    /// `OrphanCandidate` has no public initializer (SweepUninstall mints it only from a real
    /// walk), so getting one here means running `LeftoverMatcher.orphanCandidates` against a
    /// disposable fixture tree, same as `SweepUninstallTests/OrphanDetectionTests.swift` does.
    func testOrphanGroupFlagsLikelyHelperTools() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("sweep-uninstaller-orphan-\(UUID().uuidString)")
        let launchAgents = home.appendingPathComponent("Library/LaunchAgents")
        try FileManager.default.createDirectory(at: launchAgents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        FileManager.default.createFile(atPath: launchAgents.appendingPathComponent("com.example.helper.plist").path, contents: Data())

        let candidates = LeftoverMatcher.orphanCandidates(
            installedBundleIDs: [], roots: [.launchAgents], homeDirectory: home, receipts: EmptyPkgutilReceiptsProvider()
        )
        XCTAssertEqual(candidates.count, 1)

        let group = LeftoverGrouping.orphanGroup(for: candidates, home: home)
        XCTAssertEqual(group?.items.first?.title, "com.example.helper (possible helper tool)")
        XCTAssertEqual(group?.tier, .caution)
    }

    func testOrphanGroupIsNilWhenNoCandidates() {
        XCTAssertNil(LeftoverGrouping.orphanGroup(for: [], home: URL(fileURLWithPath: "/Users/tester")))
    }

    func testGroupsUseProvidedSizesByID() {
        let home = URL(fileURLWithPath: "/Users/tester")
        let candidate = LeftoverCandidate(
            url: home.appendingPathComponent("Library/Caches/com.example.app"),
            root: .caches, attributedBundleID: "com.example.app", evidence: [.exactBundleID]
        )
        let groups = LeftoverGrouping.groups(for: [candidate], home: home, sizeByID: [candidate.id: 42_000])
        XCTAssertEqual(groups.first?.items.first?.byteCount, 42_000)
    }

    // MARK: - Running-app check

    func testUnknownBundleIsNeverReportedRunning() {
        let ghost = app(id: "GhostApp", bundleID: "com.example.definitely-not-running-\(UUID().uuidString)", path: "/Applications/GhostApp.app")
        XCTAssertFalse(RunningAppChecker.isRunning(ghost, runningApplications: []))
    }

    // MARK: - Drop-route integration (`UninstallModel.selectDroppedApp`)
    //
    // Both drop targets (PLAN §3 module 5: the window's `dropDestination` and the Dock/
    // `application(_:open:)` fallback) call `AppState.openUninstaller(forDroppedAppAt:)`, which
    // is one line onto `UninstallModel.selectDroppedApp(at:)` — the actual custom logic either
    // route depends on, so it is what these tests target directly. Real-machine verification
    // during this build (`open -a Sweep /Applications/Safari.app`, log-verified via `os_log`)
    // found that AppKit's own document-open Apple Event carries an EMPTY path for an
    // application-bundle target on this machine's macOS 26.5 build even though Launch Services'
    // registration record (`lsregister -dump`) is correct — an environment/OS-level gap in the
    // Dock/`open -a` route specifically, not in this model. These tests instead exercise exactly
    // what happens once a real URL does reach the model, which is the same for every route.

    @MainActor
    func testSelectDroppedAppRefusesAProtectedSystemApp() throws {
        guard FileManager.default.fileExists(atPath: "/Applications/Safari.app") else {
            throw XCTSkip("Safari.app not present in /Applications on this machine")
        }
        let model = UninstallModel()
        model.selectDroppedApp(at: URL(fileURLWithPath: "/Applications/Safari.app"))
        XCTAssertEqual(model.selection, .none, "a protected app must never be selected, even via a drop route")
        XCTAssertTrue(model.apps.contains { $0.bundlePath.path == "/Applications/Safari.app" }, "the app is still resolved into the list")
    }

    @MainActor
    func testSelectDroppedAppSelectsAnOrdinaryAppAndLoadsLeftovers() async throws {
        guard FileManager.default.fileExists(atPath: "/Applications/AppCleaner.app") else {
            throw XCTSkip("AppCleaner.app not present in /Applications on this machine")
        }
        let model = UninstallModel()
        model.selectDroppedApp(at: URL(fileURLWithPath: "/Applications/AppCleaner.app"))
        guard case .app(let app) = model.selection else {
            return XCTFail("expected AppCleaner.app to be selected")
        }
        XCTAssertEqual(app.bundlePath.path, "/Applications/AppCleaner.app")

        let deadline = Date().addingTimeInterval(15)
        while model.isLoadingLeftovers, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(model.isLoadingLeftovers, "leftover matching should finish well within 15s for one app")
    }
}
