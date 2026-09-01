import XCTest
@testable import SweepCore
import SweepPolicy

/// `CleanService` is Gate 1's public entry point (BUILDLOG.md "Pinned API contract"). These
/// tests exercise the real pipeline — catalog loading, authorization, the three hard filters,
/// trash-only execution, the WAL, capacity-delta reporting — through `CleanService.runPipeline`,
/// which is package-internal precisely so the whole thing can be proven correct while
/// `gate1Open` stays `false`. `CleanService.execute` itself is covered separately: it must
/// refuse to run any of this while the gate is closed, which is exactly what it does below.
///
/// `.userLogs` stands in for a real cache root throughout, for the same reason
/// `AuthorizedCleanPlanTests` uses it: it is fully `home`-relative, unlike `.userCaches`.
final class CleanServiceTests: XCTestCase {

    override func setUp() {
        super.setUp()
        // Codex G1 finding #1: `CleanService` loads its own catalog from a write-once directory
        // rather than accepting one from the request. Reset first so each test's fixture catalog
        // (installed via `BundledCatalogFixture.install`) is the one actually loaded.
        CleanService.resetBundledCatalogDirectoryForTesting()
    }

    override func tearDown() {
        CleanService.resetBundledCatalogDirectoryForTesting()
        super.tearDown()
    }

    // MARK: - The gate itself

    func testExecuteThrowsGateClosedWhileGate1IsClosed() async throws {
        XCTAssertFalse(CleanService.isEnabled, "gate1Open must still be false in this build")
        let request = CleanRequest(batch: try Self.batch([]), selectedCandidateIDs: [])

        do {
            for try await _ in CleanService.execute(request) {
                XCTFail("no event should ever be produced while the gate is closed")
            }
            XCTFail("expected gateClosed to be thrown")
        } catch let error as CleanServiceError {
            XCTAssertEqual(error, .gateClosed)
        }
    }

    /// The runtime kill switch is independent of the compile-time gate, and it can only ever
    /// narrow, never widen: it is a pure function over an injected environment, so this is
    /// checkable without touching the real process environment.
    func testRuntimeKillSwitchIsAnIndependentPureFunction() {
        XCTAssertFalse(CleanService.isRuntimeDisabled(environment: [:]))
        XCTAssertFalse(CleanService.isRuntimeDisabled(environment: ["SWEEP_CLEAN_SERVICE_DISABLED": "0"]))
        XCTAssertTrue(CleanService.isRuntimeDisabled(environment: ["SWEEP_CLEAN_SERVICE_DISABLED": "1"]))
    }

    // MARK: - Codex G1 finding #1: the catalog is never the caller's

    func testCleanServiceLoadsItsOwnCatalogNeverTheRequests() async throws {
        let home = try FixtureHome("cs-own-catalog")
        try home.write("Library/Logs/JunkApp/junk.log")
        let realRule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.userlogs.real", tier: .safe)
        try BundledCatalogFixture.install(RuleCatalog(rules: [realRule]), atRoot: home.root)

        // Even though `CleanRequest` has no `catalog` parameter at all any more, forge the point
        // home by authorizing against a rule id that exists ONLY in the bundled fixture catalog
        // above, never anywhere the request itself could have carried it.
        let receipt = try home.receipt(at: "Library/Logs/JunkApp", ruleID: realRule.id)
        let request = try Self.request(home: home, receipts: [receipt], selecting: [receipt.id])

        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.succeededCount, 1, "\(report.outcomes)")
        XCTAssertFalse(home.exists("Library/Logs/JunkApp"))
    }

    func testCleanServiceRefusesToRunWithNoBundledCatalogAvailable() async throws {
        let home = try FixtureHome("cs-no-catalog")
        // No `BundledCatalogFixture.install` call: no injected directory, and this test process's
        // `Bundle.main` (the xctest runner) carries no `rules/catalog.json` resource either.
        let request = try Self.request(home: home, receipts: [], selecting: [])

        do {
            _ = try await Self.collect(CleanService.runPipeline(request))
            XCTFail("expected the run to fail before anything else without a bundled catalog")
        } catch {
            // Any thrown error is correct here; the property under test is "it does not proceed
            // silently with an empty/default catalog."
        }
    }

    // MARK: - Hard filters, exercised through the real (gate-independent) pipeline

    func testCautionTierRuleIsFilteredOutWithAReportedOutcomeNeverExecuted() async throws {
        let home = try FixtureHome("cs-caution")
        try home.write("Library/Logs/CautionApp/junk.log")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.userlogs.caution", tier: .caution)
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)
        let receipt = try home.receipt(at: "Library/Logs/CautionApp", ruleID: rule.id)
        let request = try Self.request(home: home, receipts: [receipt], selecting: [receipt.id])

        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(report.outcomes.first?.failureReason, .tierViolation)
        XCTAssertTrue(home.exists("Library/Logs/CautionApp/junk.log"), "a caution-tier item is never touched")
    }

    func testDeleteActionRuleIsSkippedWithAReportedOutcomeNeverExecuted() async throws {
        let home = try FixtureHome("cs-delete-action")
        try home.write("Library/Logs/DeleteApp/junk.log")
        let rule = Rule(
            id: "test.userlogs.deleteaction", title: "Delete action", group: .systemJunk, root: .userLogs,
            pattern: "*", itemTypes: [.directory], tier: .safe, action: .delete, undo: .none,
            rationale: "exercises the action hard filter"
        )
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)
        let receipt = try home.receipt(at: "Library/Logs/DeleteApp", ruleID: rule.id)
        let request = try Self.request(home: home, receipts: [receipt], selecting: [receipt.id])

        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(report.outcomes.first?.failureReason, .actionNotPermitted)
        XCTAssertTrue(home.exists("Library/Logs/DeleteApp/junk.log"), "a delete-action rule is never executed in Gate 1")
    }

    func testUnresolvableSelectedIDProducesAReportedOutcome() async throws {
        let home = try FixtureHome("cs-unknown-id")
        try BundledCatalogFixture.install(RuleCatalog(rules: []), atRoot: home.root)
        let request = try Self.request(home: home, receipts: [], selecting: ["nonexistent-id"])

        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.outcomes.count, 1)
        XCTAssertEqual(report.outcomes.first?.id, "nonexistent-id")
        XCTAssertEqual(report.outcomes.first?.outcome, .skipped)
    }

    func testEventsAlwaysStartBeforeAnyItemCompletes() async throws {
        let home = try FixtureHome("cs-ordering")
        try home.write("Library/Logs/App/junk.log")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.userlogs.ordering", tier: .caution)
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)
        let receipt = try home.receipt(at: "Library/Logs/App", ruleID: rule.id)
        let request = try Self.request(home: home, receipts: [receipt], selecting: [receipt.id])

        let events = try await Self.collect(CleanService.runPipeline(request))
        guard case .started = events.first else {
            return XCTFail("first event must be .started, got \(events.first as Any)")
        }
        guard case .finished = events.last else {
            return XCTFail("last event must be .finished, got \(events.last as Any)")
        }
    }

    // MARK: - Codex G1 finding #4: WAL / report / event operation ids all agree

    func testOperationIDIsSharedAcrossStartedEventFinishedReportAndEveryWALRecord() async throws {
        let home = try FixtureHome("cs-opid")
        try home.write("Library/Logs/JunkApp/first.log")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.userlogs.opid", tier: .safe)
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)
        let receipt = try home.receipt(at: "Library/Logs/JunkApp", ruleID: rule.id)
        let journalURL = home.url("clean-journal.jsonl")
        let request = CleanRequest(
            batch: try Self.batch([receipt]), selectedCandidateIDs: [receipt.id], journalURL: journalURL, home: home.root
        )

        let events = try await Self.collect(CleanService.runPipeline(request))

        guard case .started(let startedID, _) = try XCTUnwrap(events.first) else {
            return XCTFail("expected .started as the first event")
        }
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        let journal = try await WALJournal(url: journalURL)
        let records = try await journal.records()
        await journal.close()

        XCTAssertFalse(records.isEmpty)
        let recordIDs = Set(records.map(\.operationID))

        XCTAssertEqual(startedID, report.operationID, "started event and finished report must share one id")
        XCTAssertEqual(recordIDs, [report.operationID], "every WAL record must carry the same operation id, \(recordIDs)")
    }

    // MARK: - Code-sign-clone dispatch (never touches the real X directory; mirrors
    // CodeSignCloneDetectorTests's own rule of never calling the confstr-resolving entry point)

    func testCodeSignCloneDispatchReachesTheParallelAuthorizationPathAndFailsSafelyForANonexistentClone() async throws {
        let home = try FixtureHome("cs-clone-dispatch")
        try BundledCatalogFixture.install(RuleCatalog(rules: []), atRoot: home.root)
        let bundleID = "com.sweep.test.\(UUID().uuidString)"
        // Deliberately never created on disk: `FileIdentity.read` never runs against this path,
        // proving the pipeline reaches `AuthorizedCleanPlan.authorize(codeSignClone:)` and fails
        // safely there, without ever touching the real `X` directory
        // (`CodeSignCloneDetectorTests` follows the same "never call the confstr entry point"
        // rule for the same reason).
        let fakeURL = home.url("X/\(bundleID).code_sign_clone")
        let fakeIdentity = FileIdentity(
            deviceID: 1, inode: 1, volume: VolumeIdentity(deviceID: 1, uuid: nil),
            kind: .directory, linkCount: 2, modification: FileTimestamp(seconds: 0, nanoseconds: 0)
        )
        let scanCandidate = ScanCandidate(url: fakeURL, identity: fakeIdentity, allocatedSize: 0)
        let clone = CodeSignCloneCandidate(candidate: scanCandidate, bundleIdentifier: bundleID)

        let request = CleanRequest(
            batch: try Self.batch([]), codeSignClones: [clone],
            selectedCandidateIDs: [clone.id], journalURL: home.url("journal.jsonl"), home: home.root
        )

        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.outcomes.count, 1)
        let outcome = try XCTUnwrap(report.outcomes.first)
        XCTAssertEqual(outcome.id, clone.id)
        XCTAssertEqual(outcome.outcome, .skipped, "a clone that does not really exist on disk cannot be authorized")
    }

    // MARK: - End to end: real ScanEngine candidates, real Trash, real WAL, canary survives

    func testEndToEndTrashOfAFixtureTreeWithWALAndRealTrashAndCanarySurvival() async throws {
        let home = try FixtureHome("cs-e2e")
        try home.write("Library/Logs/JunkApp/first.log")
        try home.write("Library/Logs/JunkApp/second.log")
        let canary = try home.writeCanary()

        var probe: NSURL?
        let probeFile = try home.write("probe.bin")
        do {
            try FileManager.default.trashItem(at: probeFile, resultingItemURL: &probe)
            if let probe = probe as URL? { try? FileManager.default.removeItem(at: probe) }
        } catch {
            throw XCTSkip("FileManager.trashItem unavailable here: \(error.localizedDescription)")
        }

        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.userlogs.e2e", tier: .safe)
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)

        let resolvedRoot = try XCTUnwrap(SweepPolicy.resolvedRoots(for: .userLogs, home: home.root).first)
        let engine = ScanEngine()
        let scanResult = try await engine.run(ScanRequest(roots: [resolvedRoot.url], ruleID: rule.id))
        let junkAppCandidate = try XCTUnwrap(scanResult.candidates.first { $0.url.lastPathComponent == "JunkApp" })
        let receipt = try XCTUnwrap(scanResult.receipt(forCandidateID: junkAppCandidate.id))

        let journalURL = home.url("clean-journal.jsonl")
        let request = CleanRequest(
            batch: try Self.batch([receipt]), selectedCandidateIDs: [receipt.id],
            journalURL: journalURL, home: home.root
        )

        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.succeededCount, 1, "\(report.outcomes)")
        XCTAssertTrue(report.committed)
        XCTAssertFalse(home.exists("Library/Logs/JunkApp"), "the authorized item is gone")
        XCTAssertTrue(home.exists("Library/Application Support/Code/User/FIXTURE_CANARY_DO_NOT_DELETE.txt"),
                      "the canary was never selected and must survive")
        XCTAssertEqual(FileManager.default.contents(atPath: canary.path).map { String(data: $0, encoding: .utf8) } ?? nil,
                       try String(contentsOf: canary, encoding: .utf8),
                       "the canary's own content is untouched")

        let restoreURL = try XCTUnwrap(report.trashRestoreURLs.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoreURL.path), "it actually landed in the Trash")
        try? FileManager.default.removeItem(at: restoreURL)

        // WAL proof.
        let journal = try await WALJournal(url: journalURL)
        let records = try await journal.records()
        XCTAssertTrue(records.contains { $0.kind == .planned })
        XCTAssertTrue(records.contains { $0.kind == .committed })
        XCTAssertTrue(records.contains { $0.outcome == .succeeded })
        // Codex G1 finding #5: the quarantine lifecycle is journaled in its own right, not just
        // folded into the final summary record.
        XCTAssertTrue(records.contains { $0.kind == .stagePlanned })
        XCTAssertTrue(records.contains { $0.kind == .trashed })
        await journal.close()

        if case .started(_, let itemCount) = try XCTUnwrap(events.first) {
            XCTAssertEqual(itemCount, 1)
        } else {
            XCTFail("expected .started as the first event")
        }
    }

    /// Defense in depth beyond the fixed selection: even a forged id/rule combination that
    /// targets the canary is refused by authorization itself, never by luck of not being selected.
    func testForgedSelectionTargetingTheCanaryIsRefusedByAuthorizationNotJustBySelection() async throws {
        let home = try FixtureHome("cs-forged-canary")
        try home.writeCanary()
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.userlogs.forged", tier: .safe)
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)

        let canaryDirectory = home.url("Library/Application Support/Code/User")
        let identity = try FileIdentity.read(at: canaryDirectory)
        // Forged: claims the safe rule's id, but the path has nothing to do with `userLogs`.
        let forgedCandidate = ScanCandidate(url: canaryDirectory, identity: identity, allocatedSize: 0, ruleID: rule.id)
        let forgedReceipt = SelectionReceipt(candidate: forgedCandidate, scanSessionID: UUID())

        let request = try Self.request(home: home, receipts: [forgedReceipt], selecting: [forgedReceipt.id])
        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertTrue(
            home.exists("Library/Application Support/Code/User/FIXTURE_CANARY_DO_NOT_DELETE.txt"),
            "the canary must survive even a forged selection"
        )
    }

    /// Codex G1 finding #6: a receipt whose on-disk object changed since the reviewed scan (here,
    /// simulated by swapping the fixture root's *symlink target* after the receipt was minted but
    /// before `CleanService` runs) must never be authorized against the stale identity the
    /// receipt carries. This is the "post-session symlink swap between plan build and execute"
    /// case Codex called out as missing (finding #8).
    func testReceiptWhoseTargetWasSwappedAfterMintingIsRefused() async throws {
        let home = try FixtureHome("cs-post-mint-swap")
        try home.write("Library/Logs/RealApp/junk.log")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.userlogs.swap", tier: .safe)
        try BundledCatalogFixture.install(RuleCatalog(rules: [rule]), atRoot: home.root)

        let targetDirectory = home.url("Library/Logs/RealApp")
        let receipt = try home.receipt(at: "Library/Logs/RealApp", ruleID: rule.id)

        // Swap the reviewed directory out from under its own path: remove it and put a fresh
        // directory with the same name (and even the same file inside) in its place. Same path,
        // different inode — exactly the class of attack a stale receipt must not survive.
        try FileManager.default.removeItem(at: targetDirectory)
        try home.write("Library/Logs/RealApp/junk.log")

        let request = try Self.request(home: home, receipts: [receipt], selecting: [receipt.id])
        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.succeededCount, 0, "the swapped-in replacement must never be authorized against the stale receipt")
        XCTAssertTrue(home.exists("Library/Logs/RealApp/junk.log"), "the replacement survives untouched")
    }

    // MARK: - Pure-function capacity delta

    func testCapacityDeltaEstimateSumsOnlyPositiveDeltas() {
        let before = ["/vol/a": Int64(1_000), "/vol/b": Int64(500)]
        let after = ["/vol/a": Int64(1_800), "/vol/b": Int64(400)]   // b dropped, from unrelated activity
        XCTAssertEqual(VolumeCapacity.freedBytesEstimate(before: before, after: after), 800, "b's drop must not offset a's gain")
    }

    func testCapacityDeltaEstimateIgnoresVolumesMissingFromEitherSnapshot() {
        let before = ["/vol/a": Int64(1_000), "/vol/gone": Int64(200)]
        let after = ["/vol/a": Int64(1_100), "/vol/new": Int64(50)]
        XCTAssertEqual(VolumeCapacity.freedBytesEstimate(before: before, after: after), 100)
    }

    func testCapacityDeltaEstimateIsZeroWhenNothingChanged() {
        let snapshot = ["/vol/a": Int64(42)]
        XCTAssertEqual(VolumeCapacity.freedBytesEstimate(before: snapshot, after: snapshot), 0)
    }

    // MARK: - Helpers

    /// Seals `receipts` into a `SelectionBatch` the way a real scan would, minted just now against
    /// whatever catalog is currently pinned (installed via `BundledCatalogFixture.install` earlier
    /// in the calling test), so `runPipeline`'s own digest/freshness checks (Codex G1 finding #5)
    /// pass transparently for every test that is not specifically exercising them. Falls back to a
    /// placeholder digest when no catalog is configured at all (`testCleanServiceRefusesToRun...`):
    /// that test wants `runPipeline`'s own catalog-load failure, not this helper's.
    static func batch(_ receipts: [SelectionReceipt], mintedAt: Date = Date()) throws -> SelectionBatch {
        let digest = (try? CleanService.currentCatalogDigest()) ?? "test-catalog-unavailable"
        return try SelectionBatch(
            receipts: receipts,
            scanSessionID: receipts.first?.scanSessionID ?? UUID(),
            catalogDigest: digest,
            mintedAt: mintedAt
        )
    }

    static func request(
        home: FixtureHome,
        receipts: [SelectionReceipt],
        selecting ids: Set<String>
    ) throws -> CleanRequest {
        CleanRequest(
            batch: try Self.batch(receipts), selectedCandidateIDs: ids,
            journalURL: home.url("journal.jsonl"), home: home.root
        )
    }

    static func collect(_ stream: AsyncThrowingStream<CleanEvent, Error>) async throws -> [CleanEvent] {
        var events: [CleanEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }

    static func finishedReport(in events: [CleanEvent]) -> CleanReport? {
        for event in events {
            if case .finished(let report) = event { return report }
        }
        return nil
    }
}
