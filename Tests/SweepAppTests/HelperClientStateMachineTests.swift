import ServiceManagement
import XCTest
import SweepPolicy
@testable import SweepApp

// MARK: - Fakes

/// Scripts a sequence of `SMAppService.Status` values: each call to `currentStatus()` consumes the
/// next entry until only one remains, then holds there — mimicking a real daemon's status
/// stabilizing after registration completes.
private final class FakeHelperService: HelperServiceControlling, @unchecked Sendable {
    private var statuses: [SMAppService.Status]
    private let registerError: Error?
    private(set) var registerCallCount = 0
    private(set) var openedApprovalSettingsCount = 0

    init(statuses: [SMAppService.Status], registerError: Error? = nil) {
        self.statuses = statuses
        self.registerError = registerError
    }

    func currentStatus() -> SMAppService.Status {
        statuses.count > 1 ? statuses.removeFirst() : (statuses.first ?? .notRegistered)
    }

    func register() throws {
        registerCallCount += 1
        if let registerError { throw registerError }
    }

    func openApprovalSettings() {
        openedApprovalSettingsCount += 1
    }
}

private final class FakeHelperConnection: HelperConnecting, @unchecked Sendable {
    private let handshakeResult: Result<HelperHandshake, Error>
    private let performResult: Result<MaintenanceOutcome, Error>
    private(set) var invalidated = false
    private(set) var performedOperations: [MaintenanceOperation] = []

    init(
        handshakeResult: Result<HelperHandshake, Error> = .success(
            HelperHandshake(protocolVersion: HelperProtocolVersion.current, helperBuildVersion: "test", policyVersion: 1)
        ),
        performResult: Result<MaintenanceOutcome, Error> = .success(.succeeded(detail: "fake"))
    ) {
        self.handshakeResult = handshakeResult
        self.performResult = performResult
    }

    func handshake() async throws -> HelperHandshake { try handshakeResult.get() }

    func perform(_ operation: MaintenanceOperation) async throws -> MaintenanceOutcome {
        performedOperations.append(operation)
        return try performResult.get()
    }

    func invalidate() { invalidated = true }
}

private enum FakeError: Error { case boom }

// MARK: - Tests

@MainActor
final class HelperClientStateMachineTests: XCTestCase {
    func testStartsNotRegisteredWithoutTouchingTheService() {
        let service = FakeHelperService(statuses: [.notRegistered])
        let client = HelperClient(service: service, makeConnection: { FakeHelperConnection() })
        XCTAssertEqual(client.state, .notRegistered)
        XCTAssertEqual(service.registerCallCount, 0, "construction must never register — registration is lazy")
    }

    func testFreshInstallRegistersThenWaitsForApproval() async {
        let service = FakeHelperService(statuses: [.notRegistered, .requiresApproval])
        let client = HelperClient(service: service, makeConnection: { FakeHelperConnection() })
        await client.requestAccess()
        XCTAssertEqual(client.state, .requiresApproval)
        XCTAssertEqual(service.registerCallCount, 1)
    }

    func testAlreadyRequiresApprovalIsNotReRegistered() async {
        // Calling `register()` again while already `.requiresApproval` throws
        // `kSMErrorAlreadyRegistered` on a real SMAppService — this must be checked for and
        // avoided, not surfaced as a false registration failure.
        let service = FakeHelperService(statuses: [.requiresApproval])
        let client = HelperClient(service: service, makeConnection: { FakeHelperConnection() })
        await client.requestAccess()
        XCTAssertEqual(client.state, .requiresApproval)
        XCTAssertEqual(service.registerCallCount, 0)
    }

    func testApprovedHelperConnectsAndHandshakes() async {
        let service = FakeHelperService(statuses: [.enabled])
        let handshake = HelperHandshake(protocolVersion: HelperProtocolVersion.current, helperBuildVersion: "1.0", policyVersion: 1)
        let client = HelperClient(service: service, makeConnection: { FakeHelperConnection(handshakeResult: .success(handshake)) })
        await client.requestAccess()
        XCTAssertEqual(client.state, .ready(handshake))
    }

    func testIncompatibleHelperRefusesAndReportsBothVersions() async {
        let service = FakeHelperService(statuses: [.enabled])
        let handshake = HelperHandshake(protocolVersion: 999, helperBuildVersion: "9.9", policyVersion: 1)
        let client = HelperClient(service: service, makeConnection: { FakeHelperConnection(handshakeResult: .success(handshake)) })
        await client.refreshFromCurrentStatus()
        XCTAssertEqual(
            client.state,
            .incompatible(helperProtocolVersion: 999, appProtocolVersion: HelperProtocolVersion.current)
        )
    }

    func testIncompatibleHelperCannotRunAnOperation() async {
        let service = FakeHelperService(statuses: [.enabled])
        let handshake = HelperHandshake(protocolVersion: 999, helperBuildVersion: "9.9", policyVersion: 1)
        let connection = FakeHelperConnection(handshakeResult: .success(handshake))
        let client = HelperClient(service: service, makeConnection: { connection })
        await client.refreshFromCurrentStatus()

        let outcome = await client.run(.flushDNS)
        guard case .failed = outcome else { return XCTFail("expected refusal, got \(outcome)") }
        XCTAssertTrue(connection.performedOperations.isEmpty, "an incompatible helper must never receive an operation")
    }

    func testRegistrationFailureIsReported() async {
        let service = FakeHelperService(statuses: [.notRegistered], registerError: FakeError.boom)
        let client = HelperClient(service: service, makeConnection: { FakeHelperConnection() })
        await client.requestAccess()
        guard case .unavailable(.registrationFailed) = client.state else {
            return XCTFail("expected registrationFailed, got \(client.state)")
        }
    }

    func testConnectionFailureIsReported() async {
        let service = FakeHelperService(statuses: [.enabled])
        let client = HelperClient(service: service, makeConnection: { FakeHelperConnection(handshakeResult: .failure(FakeError.boom)) })
        await client.refreshFromCurrentStatus()
        guard case .unavailable(.connectionFailed) = client.state else {
            return XCTFail("expected connectionFailed, got \(client.state)")
        }
    }

    func testNotFoundStatusIsReportedAsUnavailable() async {
        let service = FakeHelperService(statuses: [.notFound])
        let client = HelperClient(service: service, makeConnection: { FakeHelperConnection() })
        await client.refreshFromCurrentStatus()
        XCTAssertEqual(client.state, .unavailable(.notFound))
    }

    func testRunRefusesWhenNotReady() async {
        let service = FakeHelperService(statuses: [.notRegistered])
        let client = HelperClient(service: service, makeConnection: { FakeHelperConnection() })
        let outcome = await client.run(.flushDNS)
        guard case .failed = outcome else { return XCTFail("expected refusal, got \(outcome)") }
    }

    func testReadyClientRunsAnOperationThroughTheConnection() async {
        let service = FakeHelperService(statuses: [.enabled])
        let connection = FakeHelperConnection(performResult: .success(.succeeded(detail: "did it")))
        let client = HelperClient(service: service, makeConnection: { connection })
        await client.requestAccess()

        let outcome = await client.run(.thinSnapshots(urgency: 2))
        XCTAssertEqual(outcome, .succeeded(detail: "did it"))
        XCTAssertEqual(connection.performedOperations, [.thinSnapshots(urgency: 2)])
    }

    func testOpenApprovalSettingsDelegatesToTheService() {
        let service = FakeHelperService(statuses: [.requiresApproval])
        let client = HelperClient(service: service, makeConnection: { FakeHelperConnection() })
        client.openApprovalSettings()
        XCTAssertEqual(service.openedApprovalSettingsCount, 1)
    }
}
