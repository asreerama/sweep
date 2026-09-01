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
        // Codex Gate-U finding #6: the token binds to the matcher's own canonical path, never the
        // caller's raw selection string — self-consistently checked against what was actually
        // admitted, rather than assuming the fixture path needs no firmlink normalization.
        XCTAssertEqual(token.canonicalPath, admitted.candidate.url.path)
        XCTAssertEqual(token.callerPath, leftover.path)
        XCTAssertEqual(token.operationID, operationID)
    }

    /// Codex Gate-U finding #1: exact-bundle-id admission now requires a `VerifiedBundle` — an
    /// ad-hoc-signed fixture whose signing identifier agrees with its own bundle id.
    func testExactBundleIDLeftoverIsAdmittedWithoutAnOverrideToken() throws {
        let home = try FixtureHome("gateU-exact-bundle-id")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Exact", codeSign: true)
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

    /// Codex Gate-U finding #1: the SAME exact-bundle-id evidence, for an UNSIGNED bundle, must
    /// drop to manual review instead of auto-admitting — the bundle itself may still be
    /// explicitly trashed (that is `authorizeBundle`'s decision alone, unaffected), but none of
    /// its leftovers may auto-admit without a verified signature.
    func testExactBundleIDLeftoverIsCappedToManualReviewWhenBundleIsUnsigned() throws {
        let home = try FixtureHome("gateU-exact-bundle-id-unsigned")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Unsigned")
        let leftover = try home.makeLeftover(root: .applicationSupport, name: "com.example.Unsigned")

        let request = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.Unsigned",
            selectedLeftoverPaths: [leftover.path]
        )
        let refusedPlan = try Self.authorize(request: request, isRunning: { _ in false })
        XCTAssertTrue(refusedPlan.leftovers.isEmpty, "an unsigned bundle's exact-bundle-id leftover must never auto-admit")
        guard case .leftoverManualConfirmationRequired = refusedPlan.unresolvedLeftovers.first?.error else {
            return XCTFail("expected leftoverManualConfirmationRequired, got \(refusedPlan.unresolvedLeftovers)")
        }

        // The bundle authorizes on its own regardless — signing is never required to trash the
        // app itself, only to auto-admit its leftovers.
        XCTAssertEqual(refusedPlan.bundle.candidate.url.path, bundle.path)

        // With an explicit override, the same strong evidence is still admitted — capped to
        // manual, never refused outright.
        let overriddenRequest = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.Unsigned",
            selectedLeftoverPaths: [leftover.path], manualOverrideConfirmedPaths: [leftover.path]
        )
        let admittedPlan = try Self.authorize(request: overriddenRequest, isRunning: { _ in false })
        let admitted = try XCTUnwrap(admittedPlan.leftovers.first)
        guard case .leftover(let evidence, let override) = admitted.role else {
            return XCTFail("expected a leftover role, got \(admitted.role)")
        }
        XCTAssertTrue(evidence.contains(.exactBundleID))
        XCTAssertNotNil(override, "capped-to-manual admission must still mint an override token")
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

    /// Codex Gate-U finding #3: `~/Library/LaunchAgents` must be excluded exactly like
    /// `/Library/LaunchDaemons` until a typed `launchctl bootout gui/<uid>/<label>` adapter can
    /// confirm the job actually stopped — a loaded agent's plist must never be auto-admitted and
    /// trashed out from under `launchd`.
    func testLaunchAgentsRootIsNeverAdmittedEvenWithExactBundleIDEvidence() throws {
        let home = try FixtureHome("gateU-launch-agents")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Agent", codeSign: true)
        let agentEntry = try home.makeLeftover(root: .launchAgents, name: "com.example.Agent")

        let request = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.Agent",
            selectedLeftoverPaths: [agentEntry.path]
        )
        let plan = try Self.authorize(request: request, isRunning: { _ in false })

        XCTAssertTrue(plan.leftovers.isEmpty, "a ~/Library/LaunchAgents entry must never be admitted into a Gate U plan")
        guard case .leftoverNotIndependentlyMatched = plan.unresolvedLeftovers.first?.error else {
            return XCTFail("expected leftoverNotIndependentlyMatched, got \(plan.unresolvedLeftovers)")
        }
    }

    // MARK: - Inventory completeness (Codex Gate-U finding #1)

    /// A second applications root that exists but cannot be enumerated (permission denied) must
    /// cap even the strongest evidence at manual review — a sibling consumer could be sitting
    /// inside exactly the directory this scan could not read.
    func testIncompleteInventoryScanCapsExactBundleIDLeftoverToManualReview() throws {
        let home = try FixtureHome("gateU-incomplete-inventory")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Incomplete", codeSign: true)
        let leftover = try home.makeLeftover(root: .applicationSupport, name: "com.example.Incomplete")

        let unreadableRoot = home.url("OtherApplications")
        try FileManager.default.createDirectory(at: unreadableRoot, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableRoot.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unreadableRoot.path) }

        let request = UninstallRequest(
            bundlePath: bundle, expectedBundleIdentifier: "com.example.Incomplete",
            selectedLeftoverPaths: [leftover.path], manualOverrideConfirmedPaths: [],
            journalURL: home.url("unused-journal.jsonl"), home: home.root,
            applicationsDirectories: [home.applicationsDirectory, unreadableRoot],
            systemLaunchDaemonsDirectory: home.url("LaunchDaemons")
        )
        let refusedPlan = try Self.authorize(request: request, isRunning: { _ in false })
        guard case .leftoverManualConfirmationRequired = refusedPlan.unresolvedLeftovers.first?.error else {
            if refusedPlan.leftovers.isEmpty {
                return XCTFail("expected leftoverManualConfirmationRequired, got \(refusedPlan.unresolvedLeftovers)")
            }
            throw XCTSkip("permission bits did not actually block enumeration in this environment (e.g. running as root)")
        }
        XCTAssertTrue(refusedPlan.leftovers.isEmpty, "an incomplete inventory scan must cap even exact-bundle-id evidence to manual review")

        // With an explicit override, the same evidence is still admitted — capped, never refused.
        let overriddenRequest = UninstallRequest(
            bundlePath: bundle, expectedBundleIdentifier: "com.example.Incomplete",
            selectedLeftoverPaths: [leftover.path], manualOverrideConfirmedPaths: [leftover.path],
            journalURL: home.url("unused-journal.jsonl"), home: home.root,
            applicationsDirectories: [home.applicationsDirectory, unreadableRoot],
            systemLaunchDaemonsDirectory: home.url("LaunchDaemons")
        )
        let admittedPlan = try Self.authorize(request: overriddenRequest, isRunning: { _ in false })
        let admitted = try XCTUnwrap(admittedPlan.leftovers.first)
        guard case .leftover(let evidence, let override) = admitted.role else {
            return XCTFail("expected a leftover role, got \(admitted.role)")
        }
        XCTAssertTrue(evidence.contains(.exactBundleID))
        XCTAssertNotNil(override)
    }

    /// Codex Gate-U finding A (second re-check loop): an existing `.app` sibling whose
    /// `Info.plist` cannot be read at all must never be silently dropped by the completeness
    /// scan — dropping it via `compactMap` left `isComplete == true` even though the scan could
    /// not prove that unreadable app is not itself a consumer of the leftover being evidenced.
    /// Exercised end to end through `AuthorizedUninstallPlan.authorize`, not merely against
    /// `AppInventory.scanReportingCompleteness` directly, so a regression here is caught exactly
    /// where it would actually matter: capping otherwise-auto-selectable exact-bundle-id evidence
    /// down to manual review.
    func testAppSiblingWithUnreadableInfoPlistCapsExactBundleIDLeftoverToManualReview() throws {
        let home = try FixtureHome("gateU-unreadable-sibling")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.UnreadableSibling", codeSign: true)
        let leftover = try home.makeLeftover(root: .applicationSupport, name: "com.example.UnreadableSibling")

        // A second, genuinely existing `.app`-extensioned entry next to the real one — a plain
        // regular file, not a real bundle directory. `Bundle(url:)` returns `nil` for this (empirically
        // verified: unlike a malformed `Info.plist`, which `Bundle` tolerates as an empty
        // dictionary, a non-directory `.app` path fails outright), so `AppInventory`'s internal
        // `readAppInfo` returns `nil` for it — exactly the "dropped via compactMap" case this
        // finding closed. No reliance on POSIX permission bits (which a root-run test environment
        // could ignore).
        let brokenApp = home.applicationsDirectory.appending(path: "Broken.app")
        try Data("not a bundle".utf8).write(to: brokenApp)

        // Sanity check on the underlying signal itself, so a failure here points straight at
        // `AppInventory` rather than only showing up two layers away in authorization.
        let scan = AppInventory.scanReportingCompleteness(directories: [home.applicationsDirectory])
        XCTAssertFalse(scan.isComplete, "an .app sibling that cannot be turned into an InstalledApp must mark the scan incomplete")
        XCTAssertFalse(scan.apps.contains { $0.bundlePath.path == brokenApp.path }, "the unreadable sibling itself is never listed as a resolved app")

        let request = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.UnreadableSibling",
            selectedLeftoverPaths: [leftover.path]
        )
        let refusedPlan = try Self.authorize(request: request, isRunning: { _ in false })
        guard case .leftoverManualConfirmationRequired = refusedPlan.unresolvedLeftovers.first?.error else {
            return XCTFail("expected leftoverManualConfirmationRequired, got \(refusedPlan.unresolvedLeftovers)")
        }
        XCTAssertTrue(refusedPlan.leftovers.isEmpty, "an unreadable app sibling must cap even exact-bundle-id evidence to manual review")

        // With an explicit override the same evidence is still admitted — capped, never refused.
        let overriddenRequest = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.UnreadableSibling",
            selectedLeftoverPaths: [leftover.path], manualOverrideConfirmedPaths: [leftover.path]
        )
        let admittedPlan = try Self.authorize(request: overriddenRequest, isRunning: { _ in false })
        let admitted = try XCTUnwrap(admittedPlan.leftovers.first)
        guard case .leftover(let evidence, let override) = admitted.role else {
            return XCTFail("expected a leftover role, got \(admitted.role)")
        }
        XCTAssertTrue(evidence.contains(.exactBundleID))
        XCTAssertNotNil(override)
    }

    // MARK: - Bundle-object validation (Codex Gate-U finding #5)

    /// A planted symlink standing in the Applications directory, pointing at a real bundle
    /// elsewhere on disk, must never be accepted as the bundle to authorize — `SweepPolicy.authorize(externalRoot:)`'s
    /// own containment proof never type-checks its leaf, so this refusal has to come from bundle
    /// structure validation itself. Deliberately NOT a system location (that class of symlink is
    /// already refused earlier, by `protectedSystemLocation` — see
    /// `testProtectedSystemLocationResolvedSymlinkIsRefused`): this is the other case that check
    /// does not cover.
    func testNonSystemPlantedSymlinkBundlePathIsRefused() throws {
        let home = try FixtureHome("gateU-planted-symlink-bundle")
        let realTarget = try home.makeAppBundle(
            name: "RealElsewhere", bundleIdentifier: "com.example.PlantedSymlink", relativeDirectory: "Elsewhere"
        )
        try FileManager.default.createDirectory(at: home.applicationsDirectory, withIntermediateDirectories: true)
        let plantedSymlink = home.applicationsDirectory.appending(path: "Planted.app")
        try FileManager.default.createSymbolicLink(at: plantedSymlink, withDestinationURL: realTarget)

        let request = Self.request(
            home: home, bundlePath: plantedSymlink, expectedBundleIdentifier: "com.example.PlantedSymlink"
        )
        XCTAssertThrowsError(try Self.authorize(request: request, isRunning: { _ in false })) { error in
            guard case .bundleStructureInvalid(let path, _) = error as? UninstallAuthorizationError else {
                return XCTFail("expected bundleStructureInvalid, got \(error)")
            }
            XCTAssertEqual(path, plantedSymlink.path)
        }
    }

    // MARK: - normalizedPathKey aliasing (Codex Gate-U finding #6)

    /// A symlink planted at a location the matcher never independently evidences (its own name
    /// matches nothing) must never be treated as a match for a *different*, real candidate's
    /// canonical path just because it happens to resolve there lexically. Before the fix,
    /// `resolvingSymlinksInPath()` collapsed both the caller's selection and every candidate's own
    /// id onto the same resolved string, so this exact symlink would have aliased onto the real
    /// leftover below and been admitted in its place.
    func testPlantedTrailingSymlinkCannotAliasOntoADifferentCandidatesCanonicalPath() throws {
        let home = try FixtureHome("gateU-symlink-alias")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Alias", codeSign: true)
        let realLeftover = try home.makeLeftover(root: .applicationSupport, name: "com.example.Alias")

        let plantedSymlink = home.url("Library/Caches/NotAnEvidencedName")
        try FileManager.default.createDirectory(at: plantedSymlink.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: plantedSymlink, withDestinationURL: realLeftover)

        let request = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.Alias",
            selectedLeftoverPaths: [plantedSymlink.path]
        )
        let plan = try Self.authorize(request: request, isRunning: { _ in false })

        XCTAssertTrue(plan.leftovers.isEmpty, "a caller-side symlink must never alias onto a different candidate's canonical path")
        guard case .leftoverNotIndependentlyMatched(let path) = plan.unresolvedLeftovers.first?.error else {
            return XCTFail("expected leftoverNotIndependentlyMatched, got \(plan.unresolvedLeftovers)")
        }
        XCTAssertEqual(path, plantedSymlink.path)

        // The real leftover, selected directly by its own canonical path, is of course still
        // admitted normally — the fix only closes the alias, never the legitimate direct match.
        let directRequest = Self.request(
            home: home, bundlePath: bundle, expectedBundleIdentifier: "com.example.Alias",
            selectedLeftoverPaths: [realLeftover.path]
        )
        let directPlan = try Self.authorize(request: directRequest, isRunning: { _ in false })
        XCTAssertEqual(directPlan.leftovers.count, 1)
    }

    // MARK: - Identity-swap refusal between authorize and execute

    func testIdentitySwapBetweenAuthorizeAndExecuteIsRefused() async throws {
        let home = try FixtureHome("gateU-identity-swap")
        try TrashAvailabilityProbe.skipIfUnavailable(near: home.url("probe"))
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Swap", codeSign: true)
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

        // Deliberately still the lower-level `execute(plan:journalURL:)` helper below, not
        // `UninstallService.runPipeline`: that entry point always re-authorizes fresh immediately
        // before it executes, so it can never observe "authorize captured X, then X changed on
        // disk" from an *outside* caller's perspective — re-authorizing after the swap would just
        // capture the replacement as legitimate. This suite instead reuses the SAME
        // already-captured `plan` value across the swap, which is the only way this specific race
        // is observable at all with the package's public surface.
        //
        // Codex Gate-U finding #4 is a *different* failure mode than this test, and is not what
        // this test's bundle-succeeds assertion below is evidence against: an unrelated leftover
        // failing its own identity check must never hold the bundle hostage, and that is still
        // correct after finding #4's fix. See
        // `UninstallServiceTests.testLateBundleRefusalRestoresAlreadyTrashedLeftoverAndLeavesBundleInstalled`
        // for finding #4's actual gap: a late problem with the BUNDLE ITSELF now rolls the whole
        // operation back through the real production pipeline, restoring any leftover already
        // trashed, rather than leaving the bundle installed with its leftovers gone.
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
        // one item whose identity actually changed; it is not a bundle-safety problem and must
        // never block the bundle.
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

    /// Replicates the wiring `UninstallService.run` used to do in a single combined
    /// `DeletionPlan` — leftovers-first-bundle-last ordering, one `DeletionCoordinator` in
    /// `.trashOnly` mode, one real `WALJournal` — without going through `UninstallService` itself,
    /// so this suite can exercise the boundary between "authorize captured this identity" and
    /// "the coordinator re-validates it" directly, reusing one already-captured
    /// `AuthorizedUninstallPlan` across an on-disk change made after it was captured.
    /// `UninstallService.runPipeline` cannot substitute for this: it always re-authorizes fresh
    /// immediately before executing, so it never observes a plan going stale from outside.
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
