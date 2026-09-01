import XCTest
@testable import SweepCore
import SweepPolicy
import SweepUninstall

/// Gate U's authorization layer, tested the same way `AuthorizedCleanPlanTests` tests Gate 1's:
/// directly, against `AuthorizedUninstallPlan.authorize`, independent of the (still-closed)
/// `UninstallService.gateUOpen` flag — this suite proves the pipeline correct *before* anyone
/// ever flips it, not for the first time after (`UninstallServiceTests` covers the flag itself
/// plus the end-to-end `UninstallService.runPipeline` shape).
final class UninstallAuthorizationTests: XCTestCase {

    // MARK: - Pure protection predicates (isolated from the filesystem entirely)

    func testPureAppleBundleIdentifierPrefixCheck() {
        XCTAssertTrue(UninstallProtection.isAppleBundleIdentifier("com.apple.Safari"))
        XCTAssertFalse(UninstallProtection.isAppleBundleIdentifier("com.example.NotApple"))
        XCTAssertFalse(UninstallProtection.isAppleBundleIdentifier("com.applesauce.Fake"), "must not fire on a mere textual prefix coincidence")
    }

    func testPureSystemLocationResolutionCheck() {
        XCTAssertTrue(UninstallProtection.isUnderSystemLocation(
            URL(fileURLWithPath: "/System/Applications/Fake.app"), prefixes: ["/System/"]
        ))
        XCTAssertFalse(UninstallProtection.isUnderSystemLocation(
            URL(fileURLWithPath: "/Applications/Real.app"), prefixes: ["/System/"]
        ))
    }

    // MARK: - Protected-app refusal: fake com.apple. bundle + fake /System-resolved symlink

    func testProtectedAppleBundleIdentifierIsRefused() throws {
        let home = try FixtureHome("gateU-apple-bundle")
        let bundle = try home.makeAppBundle(name: "FakeSystemApp", bundleIdentifier: "com.apple.FakeSystemApp")
        let request = Self.request(home: home, bundlePath: bundle, expectedBundleIdentifier: "com.apple.FakeSystemApp")

        XCTAssertThrowsError(try Self.authorize(request: request, isRunning: { _ in false })) { error in
            guard case .protectedAppleBundleIdentifier(let bundleID) = error as? UninstallAuthorizationError else {
                return XCTFail("expected protectedAppleBundleIdentifier, got \(error)")
            }
            XCTAssertEqual(bundleID, "com.apple.FakeSystemApp")
        }
    }

    /// A real symlinked bundle (mirroring macOS 26's own cryptex-relocated system apps — see
    /// `AppInventory`'s extensive comments on this) whose resolved target this test injects as a
    /// protected prefix, so the check is exercised end to end without ever touching real
    /// `/System` — and with a bundle id that is deliberately *not* `com.apple.`-prefixed, so this
    /// is provably the `/System` resolution check and not the separate Apple-namespace check.
    func testProtectedSystemLocationResolvedSymlinkIsRefused() throws {
        let home = try FixtureHome("gateU-system-symlink")
        let relocated = try home.makeAppBundle(
            name: "RelocatedApp", bundleIdentifier: "com.example.Relocated", relativeDirectory: "RelocatedSystem"
        )
        try FileManager.default.createDirectory(at: home.applicationsDirectory, withIntermediateDirectories: true)
        let symlinkedBundle = home.applicationsDirectory.appending(path: "RelocatedApp.app")
        try FileManager.default.createSymbolicLink(at: symlinkedBundle, withDestinationURL: relocated)

        let request = Self.request(home: home, bundlePath: symlinkedBundle, expectedBundleIdentifier: "com.example.Relocated")
        XCTAssertThrowsError(
            try AuthorizedUninstallPlan.authorize(
                request: request, operationID: UUID(), isRunning: { _ in false },
                receipts: EmptyPkgutilReceiptsProvider(),
                protectedLocationPrefixes: [home.url("RelocatedSystem").path]
            )
        ) { error in
            guard case .protectedSystemLocation(let path) = error as? UninstallAuthorizationError else {
                return XCTFail("expected protectedSystemLocation, got \(error)")
            }
            XCTAssertEqual(path, symlinkedBundle.path)
        }
    }

    // MARK: - Running-app refusal

    func testRunningAppRefusesAuthorizationBeforeAnythingElseIsBuilt() throws {
        let home = try FixtureHome("gateU-running")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Running")
        let request = Self.request(home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.Running")

        XCTAssertThrowsError(
            try Self.authorize(request: request, isRunning: { $0 == "com.example.Running" })
        ) { error in
            guard case .appIsRunning(let bundleID) = error as? UninstallAuthorizationError else {
                return XCTFail("expected appIsRunning, got \(error)")
            }
            XCTAssertEqual(bundleID, "com.example.Running")
        }

        // Succeeds once it is not running — proves the refusal above really was the running
        // check, not some other property of this fixture.
        let plan = try Self.authorize(request: request, isRunning: { _ in false })
        XCTAssertEqual(plan.bundle.candidate.url.path, bundle.path)
    }

    // MARK: - Info.plist identity cross-check

    func testBundleIdentifierMismatchIsRefused() throws {
        let home = try FixtureHome("gateU-id-mismatch")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Real")
        let request = Self.request(home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.SomethingElse")

        XCTAssertThrowsError(try Self.authorize(request: request, isRunning: { _ in false })) { error in
            guard case .bundleIdentifierMismatch(let expected, let found) = error as? UninstallAuthorizationError else {
                return XCTFail("expected bundleIdentifierMismatch, got \(error)")
            }
            XCTAssertEqual(expected, "com.example.SomethingElse")
            XCTAssertEqual(found, "com.example.Real")
        }
    }

    // MARK: - Forged-evidence refusal: a name-only match cannot enter a plan without an override token

    func testForgedLeftoverSelectionCannotEnterPlanAtAll() throws {
        let home = try FixtureHome("gateU-forged-leftover")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Forge")
        // Nothing on disk matches this path at all — not even a weak evidence bit — mirroring a
        // caller fabricating a `LeftoverCandidate` out of thin air.
        let forgedPath = home.url("Library/Caches/does-not-exist-\(UUID().uuidString)").path

        let request = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.Forge",
            selectedLeftoverPaths: [forgedPath]
        )
        let plan = try Self.authorize(request: request, isRunning: { _ in false })

        XCTAssertTrue(plan.leftovers.isEmpty)
        XCTAssertEqual(plan.unresolvedLeftovers.count, 1)
        guard case .leftoverNotIndependentlyMatched(let path) = plan.unresolvedLeftovers[0].error else {
            return XCTFail("expected leftoverNotIndependentlyMatched, got \(plan.unresolvedLeftovers[0].error)")
        }
        XCTAssertEqual(path, forgedPath)
    }

    /// The other half of "name-only match cannot enter a plan without override token": a
    /// *real*, independently-matched name-only leftover (`.nameMatch` evidence only —
    /// `MatchConfidence.manualReview`) is still refused without an explicit per-item
    /// confirmation, and admitted — with a minted `ManualOverrideToken` — once one is given.
    func testNameOnlyLeftoverRequiresExplicitManualOverride() throws {
        let home = try FixtureHome("gateU-name-only")
        let bundle = try home.makeAppBundle(name: "NameOnlyApp", bundleIdentifier: "com.example.namedonly.totallydifferent")
        // Folder name matches the app's DISPLAY NAME, not its bundle id.
        let leftover = try home.makeLeftover(root: .applicationSupport, name: "NameOnlyApp")

        let withoutOverride = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.namedonly.totallydifferent",
            selectedLeftoverPaths: [leftover.path]
        )
        let refusedPlan = try Self.authorize(request: withoutOverride, isRunning: { _ in false })
        XCTAssertTrue(refusedPlan.leftovers.isEmpty, "a name-only match must never enter the plan without an override token")
        guard case .leftoverManualConfirmationRequired(let path) = refusedPlan.unresolvedLeftovers.first?.error else {
            return XCTFail("expected leftoverManualConfirmationRequired, got \(refusedPlan.unresolvedLeftovers)")
        }
        XCTAssertEqual(path, leftover.path)

        let operationID = UUID()
        let withOverride = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.namedonly.totallydifferent",
            selectedLeftoverPaths: [leftover.path], manualOverrideConfirmedPaths: [leftover.path]
        )
        let admittedPlan = try Self.authorize(request: withOverride, operationID: operationID, isRunning: { _ in false })
        XCTAssertTrue(admittedPlan.unresolvedLeftovers.isEmpty)
        let admitted = try XCTUnwrap(admittedPlan.leftovers.first)
        guard case .leftover(let evidence, let override) = admitted.role else {
            return XCTFail("expected a leftover role, got \(admitted.role)")
        }
        XCTAssertTrue(evidence.contains(.nameMatch))
        XCTAssertFalse(evidence.contains(.exactBundleID))
        let token = try XCTUnwrap(override, "a manual-review admission must mint an override token")
        XCTAssertEqual(token.path, leftover.path)
        XCTAssertEqual(token.operationID, operationID)
    }

    func testExactBundleIDLeftoverIsAdmittedWithoutAnOverrideToken() throws {
        let home = try FixtureHome("gateU-exact-bundle-id")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Exact")
        let leftover = try home.makeLeftover(root: .applicationSupport, name: "com.example.Exact")

        let request = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.Exact",
            selectedLeftoverPaths: [leftover.path]
        )
        let plan = try Self.authorize(request: request, isRunning: { _ in false })

        XCTAssertTrue(plan.unresolvedLeftovers.isEmpty, "\(plan.unresolvedLeftovers)")
        let admitted = try XCTUnwrap(plan.leftovers.first)
        guard case .leftover(let evidence, let override) = admitted.role else {
            return XCTFail("expected a leftover role, got \(admitted.role)")
        }
        XCTAssertTrue(evidence.contains(.exactBundleID))
        XCTAssertNil(override, "an autoSelectable match never mints an override token")
    }

    /// PLAN §3 module 5: `/Library/LaunchDaemons` "requires privileged launchctl bootout
    /// handling, never a plain delete," and `pkgutil --forget` is explicitly never implicit
    /// cleanup — both roots are excluded from admission outright, however strong their evidence.
    func testLaunchDaemonsRootIsNeverAdmittedEvenWithExactBundleIDEvidence() throws {
        let home = try FixtureHome("gateU-excluded-roots")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Daemon")
        let daemonsDirectory = home.url("LaunchDaemons")
        try FileManager.default.createDirectory(at: daemonsDirectory, withIntermediateDirectories: true)
        let daemonPlist = daemonsDirectory.appending(path: "com.example.Daemon.plist")
        try Data("fixture".utf8).write(to: daemonPlist)

        let request = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.Daemon",
            selectedLeftoverPaths: [daemonPlist.path], systemLaunchDaemonsDirectory: daemonsDirectory
        )
        let plan = try Self.authorize(request: request, isRunning: { _ in false })

        XCTAssertTrue(plan.leftovers.isEmpty, "a /Library/LaunchDaemons entry must never be admitted into a Gate U plan")
        guard case .leftoverNotIndependentlyMatched = plan.unresolvedLeftovers.first?.error else {
            return XCTFail("expected leftoverNotIndependentlyMatched, got \(plan.unresolvedLeftovers)")
        }
    }

    // MARK: - Identity-swap refusal between authorize and execute

    func testIdentitySwapBetweenAuthorizeAndExecuteIsRefused() async throws {
        let home = try FixtureHome("gateU-identity-swap")
        try TrashAvailabilityProbe.skipIfUnavailable(near: home.url("probe"))
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Swap")
        let leftover = try home.makeLeftover(root: .applicationSupport, name: "com.example.Swap")

        let request = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.Swap",
            selectedLeftoverPaths: [leftover.path]
        )
        let plan = try Self.authorize(request: request, isRunning: { _ in false })
        XCTAssertEqual(plan.leftovers.count, 1)

        // Swap the leftover out from under its own path *after* authorization captured its
        // identity, before it is ever handed to the coordinator: remove it and put a fresh
        // directory with the same name in its place. Same path, different inode.
        try FileManager.default.removeItem(at: leftover)
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data("replacement".utf8).write(to: leftover.appending(path: "different-content.bin"))

        let report = try await Self.execute(plan: plan, journalURL: home.url("uninstall-journal.jsonl"))

        // Compared against `plan`'s own (already-resolved, `/private/var/...`) paths, not the raw
        // fixture URL: `SweepPolicy.authorize(externalRoot:)` resolves symlinks/firmlinks when it
        // builds `resolvedPath`, so that — not the lexical fixture spelling — is the ground truth
        // for what the coordinator actually reports against.
        let leftoverPath = try XCTUnwrap(plan.leftovers.first).resolvedPath.path
        let leftoverOutcome = try XCTUnwrap(report.results.first { $0.item.url.path == leftoverPath })
        XCTAssertNotEqual(leftoverOutcome.outcome, .succeeded, "the swapped-in replacement must never be trashed as the reviewed object")
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: leftover.appending(path: "different-content.bin").path),
            "the replacement survives untouched"
        )

        // The bundle, untouched by the swap, still proceeds normally — the swap only refuses the
        // one item whose identity actually changed.
        let bundleOutcome = try XCTUnwrap(report.results.first { $0.item.url.path == plan.bundle.resolvedPath.path })
        XCTAssertEqual(bundleOutcome.outcome, .succeeded, "\(bundleOutcome)")
    }

    // MARK: - Helpers

    static func request(
        home: FixtureHome,
        bundlePath: URL,
        expectedBundleIdentifier: String,
        selectedLeftoverPaths: Set<String> = [],
        manualOverrideConfirmedPaths: Set<String> = [],
        systemLaunchDaemonsDirectory: URL? = nil
    ) -> UninstallRequest {
        UninstallRequest(
            bundlePath: bundlePath, expectedBundleIdentifier: expectedBundleIdentifier,
            selectedLeftoverPaths: selectedLeftoverPaths, manualOverrideConfirmedPaths: manualOverrideConfirmedPaths,
            journalURL: home.url("unused-journal.jsonl"), home: home.root,
            applicationsDirectories: [home.applicationsDirectory],
            systemLaunchDaemonsDirectory: systemLaunchDaemonsDirectory ?? home.url("LaunchDaemons")
        )
    }

    /// Defaults `receipts:` to a provider that never spawns a real `pkgutil` subprocess, keeping
    /// this suite hermetic — production (`UninstallService`/`AuthorizedUninstallPlan.authorize`
    /// itself) still defaults to the real, `pkgutil`-backed provider.
    static func authorize(
        request: UninstallRequest,
        operationID: UUID = UUID(),
        isRunning: @escaping @Sendable (String) -> Bool,
        now: @Sendable () -> Date = Date.init
    ) throws -> AuthorizedUninstallPlan {
        try AuthorizedUninstallPlan.authorize(
            request: request, operationID: operationID, isRunning: isRunning, now: now,
            receipts: EmptyPkgutilReceiptsProvider()
        )
    }

    /// Replicates the wiring `UninstallService.run` does after authorization succeeds —
    /// leftovers-first-bundle-last ordering, one `DeletionCoordinator` in `.trashOnly` mode, one
    /// real `WALJournal` — without going through `UninstallService` itself, so this suite can
    /// exercise the boundary between "authorize captured this identity" and "the coordinator
    /// re-validates it" directly.
    static func execute(plan: AuthorizedUninstallPlan, journalURL: URL) async throws -> DeletionReport {
        let journal = try await WALJournal(url: journalURL)
        let coordinator = try DeletionCoordinator(mode: .trashOnly(anchors: plan.anchors), journal: journal)
        let deletionPlan = DeletionPlan(operationID: UUID(), items: plan.orderedItems.map(\.deletionItem))
        do {
            let report = try await coordinator.execute(deletionPlan)
            await journal.close()
            return report
        } catch {
            await journal.close()
            throw error
        }
    }
}
