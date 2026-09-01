import XCTest
import SweepPolicy
@testable import SweepHelper

/// Exercises `HelperService.perform(_:reply:)`'s two helper-enforced gates directly, with a fake
/// connection standing in for the real `NSXPCConnection` — no live daemon, no root, no real
/// console session, per this task's "build+test its validation logic as a normal-user unit test"
/// pattern (see `HelperTrustTests`/`HelperRuntimeGuardTests`).
final class HelperServiceTests: XCTestCase {
    /// Records whether/how many times `invalidate()` was called, standing in for
    /// `NSXPCConnection.invalidate()` (`HelperConnectionInvalidating`).
    private final class FakeConnection: HelperConnectionInvalidating {
        private(set) var invalidateCallCount = 0
        func invalidate() { invalidateCallCount += 1 }
    }

    private let consoleUID: uid_t = 501

    /// A executor stub that must never run for a request either gate should have already refused.
    private func executorThatMustNotRun(file: StaticString = #filePath, line: UInt = #line) -> (MaintenanceOperation) -> MaintenanceOutcome {
        { operation in
            XCTFail("executor must not run for a refused request; got \(operation)", file: file, line: line)
            return .failed(reason: "unreachable")
        }
    }

    private func decode(_ data: Data) throws -> MaintenanceOutcome {
        try JSONDecoder().decode(MaintenanceOutcome.self, from: data)
    }

    // MARK: - Issue #2: server-side handshake/policy version gate in perform()

    func testPerformRefusesAnOutOfRangeClientProtocolVersionBeforeExecuting() throws {
        let connection = FakeConnection()
        let service = HelperService(
            callerUID: consoleUID,
            connection: connection,
            currentConsoleUID: { self.consoleUID },
            executor: executorThatMustNotRun()
        )
        let requestData = try JSONEncoder().encode(
            MaintenanceRequest(operation: .flushDNS, protocolVersion: 999, policyVersion: MaintenancePolicyVersion.current)
        )

        let expectation = expectation(description: "reply")
        var receivedOutcome: MaintenanceOutcome?
        service.perform(requestData) { data in
            receivedOutcome = try? self.decode(data)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        guard case .failed(let reason) = receivedOutcome else {
            return XCTFail("expected a server-side refusal, got \(String(describing: receivedOutcome))")
        }
        // "Versioned rejection": the refusal names both the client's and the helper's version.
        XCTAssertTrue(reason.contains("999"))
        XCTAssertTrue(reason.contains("\(HelperProtocolVersion.current)"))
    }

    func testPerformRefusesAnOutOfRangeClientPolicyVersionBeforeExecuting() throws {
        let connection = FakeConnection()
        let service = HelperService(
            callerUID: consoleUID,
            connection: connection,
            currentConsoleUID: { self.consoleUID },
            executor: executorThatMustNotRun()
        )
        let requestData = try JSONEncoder().encode(
            MaintenanceRequest(operation: .flushDNS, protocolVersion: HelperProtocolVersion.current, policyVersion: 999)
        )

        let expectation = expectation(description: "reply")
        var receivedOutcome: MaintenanceOutcome?
        service.perform(requestData) { data in
            receivedOutcome = try? self.decode(data)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        guard case .failed(let reason) = receivedOutcome else {
            return XCTFail("expected a server-side refusal, got \(String(describing: receivedOutcome))")
        }
        XCTAssertTrue(reason.contains("999"))
        XCTAssertTrue(reason.contains("\(MaintenancePolicyVersion.current)"))
    }

    /// Proves the gate lives in `perform` itself, not merely in `HelperClient`'s own pre-flight
    /// check: a caller that skips the handshake entirely and sends a compatible version is still
    /// let through to the executor — the point is that an *incompatible* version can never reach
    /// it, regardless of what any client-side check would have done.
    func testPerformExecutesWhenBothVersionsMatch() throws {
        let connection = FakeConnection()
        var executedOperations: [MaintenanceOperation] = []
        let service = HelperService(
            callerUID: consoleUID,
            connection: connection,
            currentConsoleUID: { self.consoleUID },
            executor: { operation in
                executedOperations.append(operation)
                return .succeeded(detail: "fake")
            }
        )
        let requestData = try JSONEncoder().encode(MaintenanceRequest(operation: .flushDNS))

        let expectation = expectation(description: "reply")
        var receivedOutcome: MaintenanceOutcome?
        service.perform(requestData) { data in
            receivedOutcome = try? self.decode(data)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        XCTAssertEqual(receivedOutcome, .succeeded(detail: "fake"))
        XCTAssertEqual(executedOperations, [.flushDNS])
        XCTAssertEqual(connection.invalidateCallCount, 0)
    }

    // MARK: - Issue #3: console-user re-check at the start of every perform() call

    func testPerformRefusesAndInvalidatesWhenCallerIsNoLongerTheConsoleUser() throws {
        let connection = FakeConnection()
        // Accepted while UID 501 was the console user; by the time `perform` runs, someone else
        // (fast user switch) is logged into the console.
        let service = HelperService(
            callerUID: consoleUID,
            connection: connection,
            currentConsoleUID: { 777 },
            executor: executorThatMustNotRun()
        )
        let requestData = try JSONEncoder().encode(MaintenanceRequest(operation: .flushDNS))

        let expectation = expectation(description: "reply")
        var receivedOutcome: MaintenanceOutcome?
        service.perform(requestData) { data in
            receivedOutcome = try? self.decode(data)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        guard case .failed(let reason) = receivedOutcome else {
            return XCTFail("expected a refusal, got \(String(describing: receivedOutcome))")
        }
        XCTAssertTrue(reason.contains("console"))
        XCTAssertEqual(connection.invalidateCallCount, 1, "a stale session must be invalidated, not merely refused once")
    }

    func testPerformRefusesAndInvalidatesWhenNoOneIsLoggedIntoTheConsoleAnymore() throws {
        let connection = FakeConnection()
        let service = HelperService(
            callerUID: consoleUID,
            connection: connection,
            currentConsoleUID: { nil },
            executor: executorThatMustNotRun()
        )
        let requestData = try JSONEncoder().encode(MaintenanceRequest(operation: .flushDNS))

        let expectation = expectation(description: "reply")
        var receivedOutcome: MaintenanceOutcome?
        service.perform(requestData) { data in
            receivedOutcome = try? self.decode(data)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        guard case .failed = receivedOutcome else {
            return XCTFail("expected a refusal, got \(String(describing: receivedOutcome))")
        }
        XCTAssertEqual(connection.invalidateCallCount, 1)
    }

    /// The console-user re-check must run fresh on *every* call — a session authorized on one call
    /// is not grandfathered into the next once the console user changes in between.
    func testConsoleUserChangeBetweenTwoPerformCallsRefusesTheSecondButNotTheFirst() throws {
        let connection = FakeConnection()
        var currentUID: uid_t? = consoleUID
        var executedCount = 0
        let service = HelperService(
            callerUID: consoleUID,
            connection: connection,
            currentConsoleUID: { currentUID },
            executor: { _ in
                executedCount += 1
                return .succeeded(detail: "ran")
            }
        )
        let requestData = try JSONEncoder().encode(MaintenanceRequest(operation: .flushDNS))

        func performOnce() -> MaintenanceOutcome {
            let expectation = expectation(description: "reply")
            var outcome: MaintenanceOutcome?
            service.perform(requestData) { data in
                outcome = try? self.decode(data)
                expectation.fulfill()
            }
            wait(for: [expectation], timeout: 1)
            return outcome!
        }

        XCTAssertEqual(performOnce(), .succeeded(detail: "ran"))
        XCTAssertEqual(executedCount, 1)

        // Fast user switch happens between the two calls.
        currentUID = 909
        guard case .failed = performOnce() else { return XCTFail("second call must be refused") }
        XCTAssertEqual(executedCount, 1, "the second call must never reach the executor")
        XCTAssertEqual(connection.invalidateCallCount, 1)
    }

    // MARK: - Malformed requests still refuse closed, even once versions/console pass

    func testPerformRefusesDataThatDoesNotDecodeAsAMaintenanceRequest() throws {
        let connection = FakeConnection()
        let service = HelperService(
            callerUID: consoleUID,
            connection: connection,
            currentConsoleUID: { self.consoleUID },
            executor: executorThatMustNotRun()
        )

        let expectation = expectation(description: "reply")
        var receivedOutcome: MaintenanceOutcome?
        service.perform(Data("not json".utf8)) { data in
            receivedOutcome = try? self.decode(data)
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 1)

        guard case .failed = receivedOutcome else {
            return XCTFail("expected a refusal, got \(String(describing: receivedOutcome))")
        }
    }
}
