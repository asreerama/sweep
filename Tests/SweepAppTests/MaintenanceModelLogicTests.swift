import ServiceManagement
import XCTest
import SweepPolicy
@testable import SweepApp

@MainActor
final class MaintenanceModelLogicTests: XCTestCase {
    private func makeModel(statuses: [SMAppService.Status] = [.notRegistered]) -> MaintenanceModel {
        let helper = HelperClient(
            service: NeverRegisterHelperService(statuses: statuses),
            makeConnection: { NeverCalledHelperConnection() }
        )
        return MaintenanceModel(helper: helper)
    }

    // MARK: - Preview text stays byte-identical to what the helper would run

    func testPreviewTextMatchesTheSharedCommandPlanExactly() {
        let model = makeModel()
        XCTAssertEqual(model.previewText(for: .flushDNS), MaintenanceCommandPlan.previewText(for: .flushDNS))
    }

    func testReindexSpotlightOperationUsesTheSelectedVolume() {
        let model = makeModel()
        model.selectedVolumePath = "/Volumes/Data"
        XCTAssertEqual(model.operation(for: .reindexSpotlight), .reindexSpotlight(volume: "/Volumes/Data"))
        XCTAssertTrue(model.previewText(for: .reindexSpotlight).contains("/Volumes/Data"))
    }

    func testThinSnapshotsOperationUsesTheSelectedUrgency() {
        let model = makeModel()
        model.selectedUrgency = MaintenanceUrgencyLevel.maximum.rawValue
        XCTAssertEqual(model.operation(for: .thinSnapshots), .thinSnapshots(urgency: 4))
    }

    func testDefaultUrgencyIsModerate() {
        XCTAssertEqual(makeModel().selectedUrgency, MaintenanceUrgencyLevel.moderate.rawValue)
    }

    // MARK: - flushDNS degrades to the local adapter without the helper

    func testFlushDNSFallsBackToTheLocalAdapterWhenHelperIsNotReady() async {
        let model = makeModel(statuses: [.notRegistered])
        await model.run(.flushDNS)
        guard case .succeeded(let detail) = model.runState(for: .flushDNS) else {
            return XCTFail("expected success, got \(model.runState(for: .flushDNS))")
        }
        XCTAssertTrue(detail.contains("dscacheutil"))
        XCTAssertTrue(detail.contains("helper"), "must be honest that this is a partial flush")
    }

    func testReindexSpotlightNeverCallsALocalAdapter() {
        XCTAssertFalse(MaintenanceOperationKind.reindexSpotlight.hasUserLevelFallback)
        XCTAssertFalse(MaintenanceOperationKind.thinSnapshots.hasUserLevelFallback)
        XCTAssertTrue(MaintenanceOperationKind.flushDNS.hasUserLevelFallback)
    }

    // MARK: - Helper status presentation covers every state

    func testStatusLineIsDefinedForEveryHelperState() {
        let states: [HelperClientState] = [
            .notRegistered,
            .registering,
            .requiresApproval,
            .handshaking,
            .ready(HelperHandshake(protocolVersion: 1, helperBuildVersion: "1.0", policyVersion: 1)),
            .incompatible(helperProtocolVersion: 2, appProtocolVersion: 1),
            .unavailable(.notFound),
        ]
        for state in states {
            XCTAssertFalse(MaintenanceHelperPresentation.statusLine(for: state).isEmpty)
        }
    }

    func testBannerIsHiddenOnlyBeforeFirstUse() {
        XCTAssertFalse(MaintenanceHelperPresentation.showsBanner(for: .notRegistered))
        XCTAssertTrue(MaintenanceHelperPresentation.showsBanner(for: .requiresApproval))
        XCTAssertTrue(MaintenanceHelperPresentation.showsBanner(for: .incompatible(helperProtocolVersion: 2, appProtocolVersion: 1)))
    }

    // MARK: - onAppear never registers

    func testOnAppearNeverCallsRegister() async {
        let service = NeverRegisterHelperService(statuses: [.requiresApproval])
        let model = MaintenanceModel(helper: HelperClient(service: service, makeConnection: { NeverCalledHelperConnection() }))
        await model.onAppear()
        XCTAssertEqual(model.helper.state, .requiresApproval, "a status peek must still reflect reality")
        XCTAssertEqual(service.registerCallCount, 0, "PLAN §3: registration is lazy, never at launch/appearance")
    }
}

// MARK: - Test doubles

/// Fails the test outright if `register()` is ever called — used by every test in this file that
/// is not specifically exercising the lazy-registration trigger.
private final class NeverRegisterHelperService: HelperServiceControlling, @unchecked Sendable {
    private var statuses: [SMAppService.Status]
    private(set) var registerCallCount = 0

    init(statuses: [SMAppService.Status]) {
        self.statuses = statuses
    }

    func currentStatus() -> SMAppService.Status {
        statuses.count > 1 ? statuses.removeFirst() : (statuses.first ?? .notRegistered)
    }

    func register() throws {
        registerCallCount += 1
    }

    func openApprovalSettings() {}
}

private final class NeverCalledHelperConnection: HelperConnecting, @unchecked Sendable {
    func handshake() async throws -> HelperHandshake {
        XCTFail("a connection must never be made without the helper being ready")
        throw CancellationError()
    }

    func perform(_ operation: MaintenanceOperation) async throws -> MaintenanceOutcome {
        XCTFail("an operation must never run without the helper being ready")
        throw CancellationError()
    }

    func invalidate() {}
}
