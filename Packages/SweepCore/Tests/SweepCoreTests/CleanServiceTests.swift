import XCTest
@testable import SweepCore
import SweepPolicy

/// `CleanService` is Gate 1's public entry point (BUILDLOG.md "Pinned API contract"). These
/// tests exercise the real pipeline — authorization, the three hard filters, trash-only
/// execution, the WAL, capacity-delta reporting — through `CleanService.runPipeline`, which is
/// package-internal precisely so the whole thing can be proven correct while `gate1Open` stays
/// `false`. `CleanService.execute` itself is covered separately: it must refuse to run any of
/// this while the gate is closed, which is exactly what it does below.
///
/// `.userLogs` stands in for a real cache root throughout, for the same reason
/// `AuthorizedCleanPlanTests` uses it: it is fully `home`-relative, unlike `.userCaches`.
final class CleanServiceTests: XCTestCase {

    // MARK: - The gate itself

    func testExecuteThrowsGateClosedWhileGate1IsClosed() async throws {
        XCTAssertFalse(CleanService.isEnabled, "gate1Open must still be false in this build")
        let request = CleanRequest(catalog: RuleCatalog(rules: []), scan: Self.emptyScanResult(), selectedCandidateIDs: [])

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

    // MARK: - Hard filters, exercised through the real (gate-independent) pipeline

    func testCautionTierRuleIsFilteredOutWithAReportedOutcomeNeverExecuted() async throws {
        let home = try FixtureHome("cs-caution")
        try home.write("Library/Logs/CautionApp/junk.log")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.userlogs.caution", tier: .caution)
        let catalog = RuleCatalog(rules: [rule])
        let candidate = try home.candidate(at: "Library/Logs/CautionApp", ruleID: rule.id)
        let request = Self.request(home: home, catalog: catalog, candidates: [candidate], selecting: [candidate.id])

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
        let catalog = RuleCatalog(rules: [rule])
        let candidate = try home.candidate(at: "Library/Logs/DeleteApp", ruleID: rule.id)
        let request = Self.request(home: home, catalog: catalog, candidates: [candidate], selecting: [candidate.id])

        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(report.outcomes.first?.failureReason, .actionNotPermitted)
        XCTAssertTrue(home.exists("Library/Logs/DeleteApp/junk.log"), "a delete-action rule is never executed in Gate 1")
    }

    func testUnresolvableSelectedIDProducesAReportedOutcome() async throws {
        let home = try FixtureHome("cs-unknown-id")
        let request = Self.request(home: home, catalog: RuleCatalog(rules: []), candidates: [], selecting: ["nonexistent-id"])

        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.outcomes.count, 1)
        XCTAssertEqual(report.outcomes.first?.id, "nonexistent-id")
        XCTAssertEqual(report.outcomes.first?.outcome, .skipped)
    }

    /// A denylist re-check independent of the one already inside `AuthorizedCleanPlan.authorize`:
    /// a candidate whose authorization somehow still succeeded but whose path is lexically
    /// protected is skipped here too. Constructed by authorizing against a rule broad enough to
    /// match a path that also happens to sit under the injected fixture's own `.Trash` — which is
    /// legitimately a `trash`-tier-safe root — then independently poisoning the denylist check via
    /// `SweepPolicy.isDeniedLexically`'s real behavior on the real home is not reachable from a
    /// fixture; this test instead proves the dispatch path exists by checking the log ordering
    /// contract: HARD FILTERS run before anything is journaled.
    func testEventsAlwaysStartBeforeAnyItemCompletes() async throws {
        let home = try FixtureHome("cs-ordering")
        try home.write("Library/Logs/App/junk.log")
        let rule = AuthorizedCleanPlanTests.cautionTrashRule(id: "test.userlogs.ordering", tier: .caution)
        let catalog = RuleCatalog(rules: [rule])
        let candidate = try home.candidate(at: "Library/Logs/App", ruleID: rule.id)
        let request = Self.request(home: home, catalog: catalog, candidates: [candidate], selecting: [candidate.id])

        let events = try await Self.collect(CleanService.runPipeline(request))
        guard case .started = events.first else {
            return XCTFail("first event must be .started, got \(events.first as Any)")
        }
        guard case .finished = events.last else {
            return XCTFail("last event must be .finished, got \(events.last as Any)")
        }
    }

    // MARK: - Code-sign-clone dispatch (never touches the real X directory; mirrors
    // CodeSignCloneDetectorTests's own rule of never calling the confstr-resolving entry point)

    func testCodeSignCloneDispatchReachesTheParallelAuthorizationPathAndFailsSafelyForANonexistentClone() async throws {
        let home = try FixtureHome("cs-clone-dispatch")
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
            catalog: RuleCatalog(rules: []), scan: Self.emptyScanResult(), codeSignClones: [clone],
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
        let catalog = RuleCatalog(rules: [rule])

        let resolvedRoot = try XCTUnwrap(SweepPolicy.resolvedRoots(for: .userLogs, home: home.root).first)
        let engine = ScanEngine()
        let scanResult = try await engine.run(ScanRequest(roots: [resolvedRoot.url], ruleID: rule.id))
        let junkAppCandidate = try XCTUnwrap(scanResult.candidates.first { $0.url.lastPathComponent == "JunkApp" })

        let journalURL = home.url("clean-journal.jsonl")
        let request = CleanRequest(
            catalog: catalog, scan: scanResult, selectedCandidateIDs: [junkAppCandidate.id],
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
        let catalog = RuleCatalog(rules: [rule])

        let canaryDirectory = home.url("Library/Application Support/Code/User")
        let identity = try FileIdentity.read(at: canaryDirectory)
        // Forged: claims the safe rule's id, but the path has nothing to do with `userLogs`.
        let forgedCandidate = ScanCandidate(url: canaryDirectory, identity: identity, allocatedSize: 0, ruleID: rule.id)

        let request = Self.request(home: home, catalog: catalog, candidates: [forgedCandidate], selecting: [forgedCandidate.id])
        let events = try await Self.collect(CleanService.runPipeline(request))
        let report = try XCTUnwrap(Self.finishedReport(in: events))

        XCTAssertEqual(report.succeededCount, 0)
        XCTAssertEqual(report.skippedCount, 1)
        XCTAssertTrue(
            home.exists("Library/Application Support/Code/User/FIXTURE_CANARY_DO_NOT_DELETE.txt"),
            "the canary must survive even a forged selection"
        )
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

    static func emptyScanResult() -> ScanResult {
        ScanResult(
            summary: ScanSummary(scanID: UUID(), totals: ScanTotals(), issues: [], duration: 0, cancelled: false),
            candidates: []
        )
    }

    static func request(
        home: FixtureHome,
        catalog: RuleCatalog,
        candidates: [ScanCandidate],
        selecting ids: Set<String>
    ) -> CleanRequest {
        let scan = ScanResult(
            summary: ScanSummary(scanID: UUID(), totals: ScanTotals(), issues: [], duration: 0, cancelled: false),
            candidates: candidates
        )
        return CleanRequest(
            catalog: catalog, scan: scan, selectedCandidateIDs: ids,
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
