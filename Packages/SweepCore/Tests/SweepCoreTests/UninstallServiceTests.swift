import XCTest
@testable import SweepCore
import SweepUninstall

/// `UninstallService` is Gate U's public entry point, mirroring `CleanServiceTests`' own split:
/// the gate itself (open since 2026-09-01, after Fable + Codex sign-off), and the real pipeline
/// exercised through `runPipeline` — the internal seam the suite was proven against while the
/// gate was still closed, kept as the direct pipeline entry.
final class UninstallServiceTests: XCTestCase {

    // MARK: - The gate itself

    func testGateIsOpenAndOnlyTheKillSwitchNarrowsIt() {
        XCTAssertTrue(UninstallService.gateUOpen, "Gate U opened 2026-09-01 after Fable + Codex sign-off")
        XCTAssertTrue(UninstallService.isRuntimeDisabled(environment: ["SWEEP_UNINSTALL_SERVICE_DISABLED": "1"]))
        XCTAssertFalse(UninstallService.isRuntimeDisabled(environment: [:]))
    }

    // MARK: - End to end: bundle-last ordering + WAL coverage

    func testEndToEndUninstallTrashesEverythingBundleLastWithWALCoverage() async throws {
        let home = try FixtureHome("gateU-e2e")
        try TrashAvailabilityProbe.skipIfUnavailable(near: home.url("probe"))

        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.E2E", codeSign: true)
        let leftoverA = try home.makeLeftover(root: .applicationSupport, name: "com.example.E2E")
        let leftoverB = try home.makeLeftover(root: .caches, name: "com.example.E2E")
        // Matched by suffix, not exact string equality: `SweepPolicy.authorize(externalRoot:)`
        // reports the firmlink-resolved spelling (`/private/var/...`), which need not be — and, in
        // this sandbox, empirically is not reliably reproduced by re-resolving the fixture's own
        // URL a second time — the same real object regardless.
        let bundleSuffix = "/Applications/FixtureApp.app"
        let leftoverASuffix = "/Library/Application Support/com.example.E2E"
        let leftoverBSuffix = "/Library/Caches/com.example.E2E"

        let journalURL = home.url("uninstall-journal.jsonl")
        let request = UninstallRequest(
            bundlePath: bundle, expectedBundleIdentifier: "com.example.E2E",
            reviewedBundleIdentity: reviewed(bundle),
            selectedLeftoverPaths: [leftoverA.path, leftoverB.path],
            reviewedLeftoverIdentityByPath: reviewedMap([leftoverA, leftoverB]),
            manualOverrideConfirmedPaths: [leftoverA.path, leftoverB.path],
            journalURL: journalURL, home: home.root,
            applicationsDirectories: [home.applicationsDirectory],
            systemLaunchDaemonsDirectory: home.url("LaunchDaemons")
        )

        let events = try await Self.collectEvents(UninstallService.runPipeline(
            request, isRunning: { _ in false }, receipts: EmptyPkgutilReceiptsProvider()
        ))
        let report = try XCTUnwrap(CleanServiceTests.finishedReport(in: events))

        XCTAssertEqual(report.succeededCount, 3, "\(report.outcomes)")
        XCTAssertTrue(report.committed)
        XCTAssertFalse(home.exists("Applications/FixtureApp.app"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftoverA.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftoverB.path))

        // Bundle-last ordering: both leftover `.itemCompleted` events precede the bundle's.
        let completionOrder: [String] = events.compactMap { event in
            if case .itemCompleted(let outcome) = event { return outcome.url?.path }
            return nil
        }
        let bundleIndex = try XCTUnwrap(completionOrder.firstIndex { $0.hasSuffix(bundleSuffix) })
        let leftoverAIndex = try XCTUnwrap(completionOrder.firstIndex { $0.hasSuffix(leftoverASuffix) })
        let leftoverBIndex = try XCTUnwrap(completionOrder.firstIndex { $0.hasSuffix(leftoverBSuffix) })
        XCTAssertLessThan(leftoverAIndex, bundleIndex, "leftovers must complete before the bundle")
        XCTAssertLessThan(leftoverBIndex, bundleIndex, "leftovers must complete before the bundle")

        // WAL coverage: the real journal carries the full lifecycle for every item, not just the
        // ephemeral report.
        let journal = try await WALJournal(url: journalURL)
        let records = try await journal.records()
        await journal.close()

        XCTAssertTrue(records.contains { $0.kind == .planned })
        XCTAssertTrue(records.contains { $0.kind == .committed })
        XCTAssertTrue(records.contains { $0.kind == .stagePlanned })
        XCTAssertTrue(records.contains { $0.kind == .staged })
        XCTAssertTrue(records.contains { $0.kind == .trashed })
        let succeededPaths = records.compactMap { record -> String? in
            guard record.kind == .itemResult, record.outcome == .succeeded else { return nil }
            return record.item?.path
        }
        XCTAssertEqual(succeededPaths.count, 3, "\(succeededPaths)")
        XCTAssertTrue(succeededPaths.contains { $0.hasSuffix(bundleSuffix) }, "\(succeededPaths)")
        XCTAssertTrue(succeededPaths.contains { $0.hasSuffix(leftoverASuffix) }, "\(succeededPaths)")
        XCTAssertTrue(succeededPaths.contains { $0.hasSuffix(leftoverBSuffix) }, "\(succeededPaths)")

        // Restore handles actually work.
        for outcome in report.outcomes {
            if let trashURL = outcome.trashURL {
                XCTAssertTrue(FileManager.default.fileExists(atPath: trashURL.path))
                try? FileManager.default.removeItem(at: trashURL)
            }
        }
    }

    // MARK: - Manual-override journaling

    func testManualOverrideLeftoverIsAdmittedAndSurfacedInTheReport() async throws {
        let home = try FixtureHome("gateU-manual-report")
        try TrashAvailabilityProbe.skipIfUnavailable(near: home.url("probe"))

        let bundle = try home.makeAppBundle(name: "ManualApp", bundleIdentifier: "com.example.manual.differentnamespace")
        let leftover = try home.makeLeftover(root: .applicationSupport, name: "ManualApp")

        let request = UninstallRequest(
            bundlePath: bundle, expectedBundleIdentifier: "com.example.manual.differentnamespace",
            reviewedBundleIdentity: reviewed(bundle),
            selectedLeftoverPaths: [leftover.path],
            reviewedLeftoverIdentityByPath: reviewedMap([leftover]),
            manualOverrideConfirmedPaths: [leftover.path],
            journalURL: home.url("uninstall-journal.jsonl"), home: home.root,
            applicationsDirectories: [home.applicationsDirectory],
            systemLaunchDaemonsDirectory: home.url("LaunchDaemons")
        )

        let events = try await Self.collectEvents(UninstallService.runPipeline(
            request, isRunning: { _ in false }, receipts: EmptyPkgutilReceiptsProvider()
        ))
        let report = try XCTUnwrap(CleanServiceTests.finishedReport(in: events))

        let leftoverOutcome = try XCTUnwrap(report.outcomes.first { $0.url?.path.hasSuffix("/Library/Application Support/ManualApp") == true })
        XCTAssertEqual(leftoverOutcome.outcome, .succeeded, "\(report.outcomes)")
        XCTAssertEqual(leftoverOutcome.detectorSource, "gateU.leftover.manualOverride")
        XCTAssertEqual(leftoverOutcome.tier, .caution, "a manual override is surfaced as caution, unlike an autoSelectable admission")
        let detail = try XCTUnwrap(leftoverOutcome.detail)
        XCTAssertTrue(detail.contains("manual override"), detail)
        XCTAssertTrue(detail.contains("nameMatch"), detail)

        if let trashURL = leftoverOutcome.trashURL { try? FileManager.default.removeItem(at: trashURL) }
        if let bundleOutcome = report.outcomes.first(where: { $0.url?.path == bundle.path }), let trashURL = bundleOutcome.trashURL {
            try? FileManager.default.removeItem(at: trashURL)
        }
    }

    /// A leftover selected with NO evidence at all (forged) is settled without ever reaching the
    /// coordinator, reported with `detectorSource == "gateU.leftover"` (never the `.auto`/
    /// `.manualOverride` tags, which only ever apply to an admitted item).
    func testForgedLeftoverSelectionIsSettledInTheReportNeverAdmitted() async throws {
        let home = try FixtureHome("gateU-service-forged")
        try TrashAvailabilityProbe.skipIfUnavailable(near: home.url("probe"))
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.ServiceForge")
        let forgedPath = home.url("Library/Caches/does-not-exist-\(UUID().uuidString)").path

        let request = UninstallRequest(
            bundlePath: bundle, expectedBundleIdentifier: "com.example.ServiceForge",
            reviewedBundleIdentity: reviewed(bundle),
            selectedLeftoverPaths: [forgedPath], manualOverrideConfirmedPaths: [],
            journalURL: home.url("uninstall-journal.jsonl"), home: home.root,
            applicationsDirectories: [home.applicationsDirectory],
            systemLaunchDaemonsDirectory: home.url("LaunchDaemons")
        )

        let events = try await Self.collectEvents(UninstallService.runPipeline(
            request, isRunning: { _ in false }, receipts: EmptyPkgutilReceiptsProvider()
        ))
        let report = try XCTUnwrap(CleanServiceTests.finishedReport(in: events))

        let forgedOutcome = try XCTUnwrap(report.outcomes.first { $0.id == forgedPath })
        XCTAssertEqual(forgedOutcome.outcome, .skipped)
        XCTAssertEqual(forgedOutcome.detectorSource, "gateU.leftover")

        if let bundleOutcome = report.outcomes.first(where: { $0.url?.path == bundle.path }), let trashURL = bundleOutcome.trashURL {
            try? FileManager.default.removeItem(at: trashURL)
        }
    }

    // MARK: - Quit-verification preflight

    func testQuitVerificationPreflightRefusesAStillRunningAppAfterGrace() async throws {
        let home = try FixtureHome("gateU-quit-preflight")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.StillRunning")
        let request = UninstallRequest(
            bundlePath: bundle, expectedBundleIdentifier: "com.example.StillRunning",
            reviewedBundleIdentity: reviewed(bundle)
        )

        // Deterministic, fast: the app never stops being "running," and the grace window is tiny
        // so this test costs milliseconds, not the real 5-second production default.
        let verification = QuitVerification(
            isRunning: { _ in true }, now: Date.init, sleep: { _ in }, pollIntervalNanoseconds: 1, graceDuration: 0.02
        )

        let events = try await Self.collectEvents(UninstallService.runPipeline(
            request, isRunning: { _ in true }, quitVerification: verification, receipts: EmptyPkgutilReceiptsProvider()
        ))
        let report = try XCTUnwrap(CleanServiceTests.finishedReport(in: events))

        XCTAssertEqual(report.outcomes.count, 1)
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertEqual(outcome.outcome, .skipped)
        XCTAssertEqual(outcome.detectorSource, "gateU.bundle")
        XCTAssertTrue(outcome.detail?.contains("grace window") == true, "\(outcome.detail ?? "nil")")
    }

    // MARK: - Bundle-last transactional safety (Codex Gate-U finding #4)

    /// The regression this finding actually closed: a leftover reaches the real Trash during the
    /// leftover phase, then the bundle fails its fresh, immediately-pre-staging revalidation
    /// (simulated here as the app having been relaunched while the leftover phase was running).
    /// Before the fix, the two phases were one combined `DeletionPlan`: the bundle would simply be
    /// the next item processed, with no revalidation at all beyond the identity captured at
    /// authorization time — this exact scenario would have trashed the bundle right along with
    /// the leftover, or at best left the leftover permanently gone with the bundle still
    /// installed. After the fix, the whole operation refuses, the bundle stays installed, and the
    /// already-trashed leftover is restored to its original location.
    func testLateBundleRefusalRestoresAlreadyTrashedLeftoverAndLeavesBundleInstalled() async throws {
        let home = try FixtureHome("gateU-late-bundle-refusal")
        try TrashAvailabilityProbe.skipIfUnavailable(near: home.url("probe"))
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.LateRefusal", codeSign: true)
        let leftover = try home.makeLeftover(root: .applicationSupport, name: "com.example.LateRefusal")
        // Captured before the pipeline ever runs — Codex Gate-U finding B's own regression: the
        // restore used to verify only that *something* existed at the original path afterward,
        // never that it was the same inode that was actually trashed.
        let preTrashIdentity = try FileIdentity.read(at: leftover)

        // Calls 1–2 ("not running") satisfy the quit-verification preflight and `authorizeBundle`'s
        // own running check, both of which happen BEFORE the leftover phase ever runs. Every call
        // from #3 onward ("running") is only ever reached by
        // `revalidateBundleImmediatelyBeforeStaging`, which runs strictly AFTER the leftover phase
        // has already completed — simulating the app being relaunched during that window.
        let counter = CallCounter()
        let isRunning: @Sendable (String) -> Bool = { _ in counter.increment() > 2 }

        let journalURL = home.url("uninstall-journal.jsonl")
        let request = UninstallRequest(
            bundlePath: bundle, expectedBundleIdentifier: "com.example.LateRefusal",
            reviewedBundleIdentity: reviewed(bundle),
            selectedLeftoverPaths: [leftover.path],
            reviewedLeftoverIdentityByPath: reviewedMap([leftover]),
            manualOverrideConfirmedPaths: [leftover.path],
            journalURL: journalURL, home: home.root,
            applicationsDirectories: [home.applicationsDirectory],
            systemLaunchDaemonsDirectory: home.url("LaunchDaemons")
        )

        let events = try await Self.collectEvents(UninstallService.runPipeline(
            request, isRunning: isRunning, receipts: EmptyPkgutilReceiptsProvider()
        ))
        let report = try XCTUnwrap(CleanServiceTests.finishedReport(in: events))

        XCTAssertFalse(report.committed, "a late bundle refusal must never be reported as committed")
        XCTAssertEqual(report.succeededCount, 0, "\(report.outcomes)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path), "the bundle must remain installed when staging is refused")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.path), "the leftover must be restored to its original location")
        XCTAssertTrue(FileManager.default.fileExists(atPath: leftover.appending(path: "data.bin").path), "the restored leftover's own content must survive intact")

        let bundleOutcome = try XCTUnwrap(report.outcomes.first { $0.detectorSource == "gateU.bundle" })
        XCTAssertEqual(bundleOutcome.outcome, .skipped)
        XCTAssertNil(bundleOutcome.trashURL)
        XCTAssertTrue(bundleOutcome.detail?.contains("is running") == true, "expected an appIsRunning refusal, got \(bundleOutcome.detail ?? "nil")")

        let leftoverOutcome = try XCTUnwrap(report.outcomes.first { $0.detail?.contains("restored:") == true })
        XCTAssertEqual(leftoverOutcome.outcome, .skipped)
        XCTAssertNil(leftoverOutcome.trashURL, "a restored item's outcome must not still advertise a live Trash handle")

        // Codex Gate-U finding B: identity-verified, not merely presence-verified. The object now
        // sitting at the original path must be the exact same device/inode/type that was trashed —
        // a mere `fileExists` check would also have passed for a same-named decoy substituted in
        // its place.
        let restoredIdentity = try FileIdentity.read(at: leftover)
        XCTAssertTrue(
            restoredIdentity.isSameFile(as: preTrashIdentity),
            "restored dev \(restoredIdentity.deviceID)/ino \(restoredIdentity.inode) must match the trashed "
                + "dev \(preTrashIdentity.deviceID)/ino \(preTrashIdentity.inode)"
        )

        // The WAL's final recorded state for the restored leftover must match reality (restored),
        // never the transient "succeeded" state it passed through on the way there. The
        // corrective record must land under the SAME operation id the leftover's own original
        // `planned`/`succeeded` records used — filing it under a different id would leave it an
        // orphan correction that a per-operation recovery scan (`WALJournal.parse` groups
        // `itemResult` outcomes by operation id) would never actually see.
        let journal = try await WALJournal(url: journalURL)
        let records = try await journal.records()
        await journal.close()
        let leftoverItemRecords = records.filter { $0.kind == .itemResult && $0.item?.path == leftoverOutcome.url?.path }
        XCTAssertEqual(Set(leftoverItemRecords.map(\.operationID)).count, 1, "\(records)")
        XCTAssertEqual(leftoverItemRecords.last?.outcome, .skipped, "\(records)")
        XCTAssertEqual(leftoverItemRecords.first?.outcome, .succeeded, "the original success must still be a truthful part of the history, \(records)")
    }

    // MARK: - Durable manual-consent provenance (Codex Gate-U finding #2)

    /// The WAL's `planned` record — not just the ephemeral report — must carry enough to prove
    /// *why* a manual-review leftover was authorized: evidence, canonical identity, confirmation
    /// timestamp and an operation-bound nonce. Before the fix, `AuthorizedUninstallItem.deletionItem`
    /// discarded the `ManualOverrideToken` outright, so a crash-recovery scan over the WAL could
    /// see a weakly-matched item moved with no durable record of the human confirmation that
    /// allowed it.
    func testManualConsentProvenanceIsPersistedInTheDurableWALPlannedRecord() async throws {
        let home = try FixtureHome("gateU-manual-provenance")
        try TrashAvailabilityProbe.skipIfUnavailable(near: home.url("probe"))
        let bundle = try home.makeAppBundle(name: "ProvenanceApp", bundleIdentifier: "com.example.provenance.distinctnamespace", codeSign: true)
        let manualLeftover = try home.makeLeftover(root: .applicationSupport, name: "ProvenanceApp")
        let autoLeftover = try home.makeLeftover(root: .caches, name: "com.example.provenance.distinctnamespace")

        let journalURL = home.url("uninstall-journal.jsonl")
        let request = UninstallRequest(
            bundlePath: bundle, expectedBundleIdentifier: "com.example.provenance.distinctnamespace",
            reviewedBundleIdentity: reviewed(bundle),
            selectedLeftoverPaths: [manualLeftover.path, autoLeftover.path],
            reviewedLeftoverIdentityByPath: reviewedMap([manualLeftover, autoLeftover]),
            manualOverrideConfirmedPaths: [manualLeftover.path, autoLeftover.path],
            journalURL: journalURL, home: home.root,
            applicationsDirectories: [home.applicationsDirectory],
            systemLaunchDaemonsDirectory: home.url("LaunchDaemons")
        )

        let events = try await Self.collectEvents(UninstallService.runPipeline(
            request, isRunning: { _ in false }, receipts: EmptyPkgutilReceiptsProvider()
        ))
        let report = try XCTUnwrap(CleanServiceTests.finishedReport(in: events))
        for outcome in report.outcomes {
            if let trashURL = outcome.trashURL { try? FileManager.default.removeItem(at: trashURL) }
        }

        let journal = try await WALJournal(url: journalURL)
        let records = try await journal.records()
        await journal.close()

        // The durable `planned` record — the one written before a single byte of the filesystem
        // was touched — is what must carry this, not merely something reconstructed afterward.
        // Codex Gate-U finding #4 splits execution into a leftover-phase plan and a bundle-phase
        // plan, each with its own `planned` record — gathered across both, since either phase's
        // record could carry the item under test.
        let plannedItems = records.filter { $0.kind == .planned }.flatMap { $0.items ?? [] }
        XCTAssertFalse(plannedItems.isEmpty)

        let manualPlannedItem = try XCTUnwrap(plannedItems.first { $0.path.hasSuffix("/Library/Application Support/ProvenanceApp") })
        let provenance = try XCTUnwrap(manualPlannedItem.manualConsentProvenance, "a manual-review admission must persist provenance into the planned WAL record")
        XCTAssertTrue(provenance.manualConfirmed)
        XCTAssertEqual(provenance.evidenceTag, "nameMatch")
        XCTAssertEqual(provenance.canonicalPath, manualPlannedItem.path)
        XCTAssertEqual(provenance.identity, manualPlannedItem.identity)
        XCTAssertEqual(provenance.authorizationVersion, ManualConsentProvenance.currentVersion)

        // Codex Gate-U re-review finding #5 retired unattended auto-admission: even the
        // exact-bundle-id leftover now rides an explicit per-item confirmation, and its planned
        // WAL record carries that provenance like any other.
        let autoPlannedItem = try XCTUnwrap(plannedItems.first { $0.path.hasSuffix("/Library/Caches/com.example.provenance.distinctnamespace") })
        let autoProvenance = try XCTUnwrap(autoPlannedItem.manualConsentProvenance)
        XCTAssertTrue(autoProvenance.manualConfirmed)
        XCTAssertEqual(autoProvenance.evidenceTag, "exactBundleID")

        // The bundle item itself never carries manual-consent provenance either.
        let bundlePlannedItem = try XCTUnwrap(plannedItems.first { $0.path == bundle.path || $0.path.hasSuffix("/Applications/ProvenanceApp.app") })
        XCTAssertNil(bundlePlannedItem.manualConsentProvenance)
    }

    // MARK: - Helpers

    static func collectEvents(_ stream: AsyncThrowingStream<CleanEvent, Error>) async throws -> [CleanEvent] {
        var events: [CleanEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}

/// A thread-safe call counter for tests that need an `isRunning` closure whose answer changes
/// partway through a pipeline run (Codex Gate-U finding #4: simulating an app that gets relaunched
/// between the leftover phase and the bundle's own pre-staging revalidation).
final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }
}


// MARK: - Reviewed-identity capture (Codex Gate-U re-review blocker #1)

/// What the real review UI does at confirm time: lstat the objects it is showing. Fixture
/// paths always exist by the time a test builds its request, so `try!` is deliberate — a
/// missing fixture is a broken test, not a scenario.
private func reviewed(_ url: URL) -> FileIdentity {
    try! FileIdentity.read(at: url)
}

private func reviewedMap(_ urls: [URL]) -> [String: FileIdentity] {
    Dictionary(uniqueKeysWithValues: urls.map { ($0.path, reviewed($0)) })
}
