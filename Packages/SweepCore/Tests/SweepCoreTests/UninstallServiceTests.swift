import XCTest
@testable import SweepCore
import SweepUninstall

/// `UninstallService` is Gate U's public entry point, mirroring `CleanServiceTests`' own split:
/// the gate itself (closed, and staying closed until Fable + Codex sign off), and the real
/// pipeline exercised through `runPipeline` — the internal seam that lets the whole thing be
/// proven correct while `gateUOpen` stays `false`.
final class UninstallServiceTests: XCTestCase {

    // MARK: - The gate itself

    func testGateStaysClosedAndExecuteThrows() async throws {
        XCTAssertFalse(UninstallService.gateUOpen, "Gate U must stay closed until Fable + Codex sign off")
        XCTAssertTrue(UninstallService.isRuntimeDisabled(environment: ["SWEEP_UNINSTALL_SERVICE_DISABLED": "1"]))
        XCTAssertFalse(UninstallService.isRuntimeDisabled(environment: [:]))
        XCTAssertFalse(UninstallService.isEnabled, "gateUOpen is false, so isEnabled must be false regardless of environment")

        let home = try FixtureHome("gateU-closed")
        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.Closed")
        let request = UninstallRequest(bundlePath: bundle, expectedBundleIdentifier: "com.example.Closed")

        do {
            _ = try await Self.collectEvents(UninstallService.execute(request))
            XCTFail("execute must throw while the gate is closed")
        } catch UninstallServiceError.gateClosed {
            // expected
        }
    }

    // MARK: - End to end: bundle-last ordering + WAL coverage

    func testEndToEndUninstallTrashesEverythingBundleLastWithWALCoverage() async throws {
        let home = try FixtureHome("gateU-e2e")
        try TrashAvailabilityProbe.skipIfUnavailable(near: home.url("probe"))

        let bundle = try home.makeAppBundle(bundleIdentifier: "com.example.E2E")
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
            selectedLeftoverPaths: [leftoverA.path, leftoverB.path],
            manualOverrideConfirmedPaths: [],
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
            selectedLeftoverPaths: [leftover.path], manualOverrideConfirmedPaths: [leftover.path],
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
        let request = UninstallRequest(bundlePath: bundle, expectedBundleIdentifier: "com.example.StillRunning")

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

    // MARK: - Helpers

    static func collectEvents(_ stream: AsyncThrowingStream<CleanEvent, Error>) async throws -> [CleanEvent] {
        var events: [CleanEvent] = []
        for try await event in stream { events.append(event) }
        return events
    }
}
