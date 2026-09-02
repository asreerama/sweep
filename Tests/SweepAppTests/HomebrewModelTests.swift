import XCTest
@testable import SweepApp

/// `HomebrewModel` (Homebrew screen, module 9, PLAN §3) driven against `FixtureBrewGateway` —
/// never a real `brew` process — so the preview-first state machine is verified deterministically.
@MainActor
final class HomebrewModelTests: XCTestCase {

    // MARK: - Load state

    func testRefreshPopulatesSnapshotOnSuccess() async {
        let model = HomebrewModel(gateway: FixtureBrewGateway())
        await model.refresh()
        XCTAssertEqual(model.loadState, .loaded)
        XCTAssertEqual(model.snapshot.packages.count, BrewSnapshot.sample.packages.count)
    }

    func testRefreshReportsUnavailableWithoutCallingSnapshot() async {
        var gateway = FixtureBrewGateway()
        gateway.isAvailable = false
        let model = HomebrewModel(gateway: gateway)
        await model.refresh()
        XCTAssertEqual(model.loadState, .unavailable)
        XCTAssertTrue(model.snapshot.packages.isEmpty)
    }

    func testRefreshSurfacesAGatewayFailureRatherThanCrashing() async {
        var gateway = FixtureBrewGateway()
        gateway.snapshotResult = .failure(BrewGatewayError.malformedOutput("truncated JSON"))
        let model = HomebrewModel(gateway: gateway)
        await model.refresh()
        guard case .failed(let message) = model.loadState else {
            return XCTFail("expected .failed, got \(model.loadState)")
        }
        XCTAssertTrue(message.contains("truncated JSON"))
    }

    // MARK: - Preview-first: cleanup / autoremove

    func testRequestCleanupPopulatesPendingActionOnlyAfterThePreviewLands() async {
        var gateway = FixtureBrewGateway()
        gateway.previewOutput = "Would remove: /some/cache/file (12.0MB)"
        let model = HomebrewModel(gateway: gateway)

        model.requestCleanup()
        // `preparePreview` sets a "Checking…" placeholder synchronously before the first await,
        // so a pending action already exists but is not yet confirmable.
        XCTAssertNotNil(model.pendingAction)
        XCTAssertFalse(model.isPendingActionReady)

        // Let the detached preview fetch complete.
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(model.isPendingActionReady)
        XCTAssertEqual(model.pendingAction?.previewText, "Would remove: /some/cache/file (12.0MB)")
    }

    func testConfirmPendingActionIsANoOpBeforeThePreviewIsReady() async {
        let model = HomebrewModel(gateway: FixtureBrewGateway())
        model.requestCleanup()
        XCTAssertFalse(model.isPendingActionReady)

        // Structural preview-first (PLAN §3 Toolbox contract): confirming before the preview
        // landed must not run the mutating command at all.
        model.confirmPendingAction()
        XCTAssertNotNil(model.pendingAction, "an unready pending action must not be cleared by confirm")
        XCTAssertTrue(model.consoleLog.isEmpty, "no command should have run")
    }

    func testConfirmCleanupRunsTheMutationAndAppendsConsoleOutputThenRefreshes() async {
        var gateway = FixtureBrewGateway()
        gateway.mutationResult = .success("Removed 3 files, 42.0MB")
        let model = HomebrewModel(gateway: gateway)

        model.requestCleanup()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.isPendingActionReady)

        model.confirmPendingAction()
        XCTAssertNil(model.pendingAction, "confirming clears the pending action immediately")
        try? await Task.sleep(for: .milliseconds(50))

        XCTAssertTrue(model.consoleLog.contains("Removed 3 files, 42.0MB"))
        XCTAssertTrue(model.consoleLog.contains("Clean Homebrew Cache"))
        XCTAssertEqual(model.loadState, .loaded, "confirming re-refreshes the snapshot")
        XCTAssertFalse(model.isRunningAction)
    }

    func testCancelPendingActionClearsStateWithoutRunningAnything() async {
        let model = HomebrewModel(gateway: FixtureBrewGateway())
        model.requestCleanup()
        model.cancelPendingAction()
        XCTAssertNil(model.pendingAction)
        XCTAssertFalse(model.isPendingActionReady)
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.consoleLog.isEmpty)
    }

    func testAFailedPreviewNeverProducesAConfirmableAction() async {
        var gateway = FixtureBrewGateway()
        gateway.snapshotResult = .success(.sample)
        gateway.previewOutput = "unused"
        // Reuse mutationResult's failure plumbing isn't right for a preview failure; simulate via
        // a gateway whose cleanupPreview itself throws.
        let model = HomebrewModel(gateway: FailingPreviewGateway(inner: gateway))
        model.requestCleanup()
        try? await Task.sleep(for: .milliseconds(50))
        XCTAssertNil(model.pendingAction, "a failed preview must not leave a confirmable action behind")
        XCTAssertTrue(model.consoleLog.contains("preview failed"))
    }

    // MARK: - Per-item upgrade (no dry-run exists; the sheet's content is pre-known data)

    func testRequestUpgradeIsImmediatelyReadyAndDescribesTheVersionJump() {
        let model = HomebrewModel(gateway: FixtureBrewGateway())
        let package = BrewPackage(
            id: "formula:node", name: "node", isCask: false,
            installedVersion: "26.4.0", latestVersion: "26.8.1", sizeBytes: 100
        )
        model.requestUpgrade(package)
        XCTAssertTrue(model.isPendingActionReady, "upgrade has no async preview fetch to wait on")
        XCTAssertTrue(model.pendingAction?.previewText.contains("26.4.0") == true)
        XCTAssertTrue(model.pendingAction?.previewText.contains("26.8.1") == true)
        XCTAssertTrue(model.pendingAction?.previewText.contains("brew upgrade node") == true)
    }

    func testRequestUpgradeOfACaskUsesTheCaskFlag() {
        let model = HomebrewModel(gateway: FixtureBrewGateway())
        let package = BrewPackage(
            id: "cask:flutter", name: "flutter", isCask: true,
            installedVersion: nil, latestVersion: "4.2.0", sizeBytes: 100
        )
        model.requestUpgrade(package)
        XCTAssertTrue(model.pendingAction?.previewText.contains("brew upgrade --cask flutter") == true)
    }

    // MARK: - Kind.matches (race guard for a superseded preview)

    func testPendingActionKindMatchesIdentifiesTheSameSingletonAction() {
        XCTAssertTrue(HomebrewPendingAction.Kind.cleanup.matches(.cleanup))
        XCTAssertTrue(HomebrewPendingAction.Kind.autoremove.matches(.autoremove))
        XCTAssertFalse(HomebrewPendingAction.Kind.cleanup.matches(.autoremove))
    }

    func testPendingActionKindMatchesDistinguishesDifferentUpgradeTargets() {
        let node = BrewPackage(id: "formula:node", name: "node", isCask: false, installedVersion: nil, latestVersion: nil, sizeBytes: 0)
        let go = BrewPackage(id: "formula:go", name: "go", isCask: false, installedVersion: nil, latestVersion: nil, sizeBytes: 0)
        XCTAssertTrue(HomebrewPendingAction.Kind.upgrade(node).matches(.upgrade(node)))
        XCTAssertFalse(HomebrewPendingAction.Kind.upgrade(node).matches(.upgrade(go)))
    }
}

/// Wraps a `FixtureBrewGateway` but always fails its cleanup preview — `FixtureBrewGateway` has
/// no per-call failure toggle for previews specifically (only for the snapshot and for
/// mutations), so this is a minimal decorator for the one missing case.
private struct FailingPreviewGateway: BrewGateway {
    let inner: FixtureBrewGateway
    var isAvailable: Bool { inner.isAvailable }
    func snapshot() async throws -> BrewSnapshot { try await inner.snapshot() }
    func cleanupPreview() async throws -> String { throw BrewGatewayError.malformedOutput("preview boom") }
    func cleanup() async throws -> String { try await inner.cleanup() }
    func autoremovePreview() async throws -> String { try await inner.autoremovePreview() }
    func autoremove() async throws -> String { try await inner.autoremove() }
    func upgrade(_ package: BrewPackage) async throws -> String { try await inner.upgrade(package) }
    func uninstall(_ package: BrewPackage) async throws -> String { try await inner.uninstall(package) }
}
