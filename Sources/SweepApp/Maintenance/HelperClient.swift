import Foundation
import ServiceManagement
import SweepPolicy

// MARK: - Pure logic (unit-testable; see Tests/SweepAppTests/HelperClientStateMachineTests.swift)

/// Every state `HelperClient` can be in, following PLAN Appendix B's lifecycle exactly:
/// `SMAppService` registration -> `.requiresApproval` handling -> versioned XPC handshake ->
/// `.ready` or `.incompatible`. Registration is lazy (PLAN §3): nothing but
/// ``HelperClient/refreshFromCurrentStatus()`` — a read-only status peek — may run before the user
/// explicitly asks for a privileged operation; only ``HelperClient/requestAccess()`` ever calls
/// `register()`.
enum HelperClientState: Equatable {
    case notRegistered
    case registering
    case requiresApproval
    case handshaking
    case ready(HelperHandshake)
    /// PLAN Appendix B: "incompatible-version refusal". There is no path from here to `run(_:)`
    /// succeeding — the only way out is a rebuild that changes ``HelperProtocolVersion/current``
    /// on both sides.
    case incompatible(helperProtocolVersion: Int, appProtocolVersion: Int)
    case unavailable(HelperClientError)
}

enum HelperClientError: Equatable, CustomStringConvertible {
    case registrationFailed(String)
    case connectionFailed(String)
    case notFound

    var description: String {
        switch self {
        case .registrationFailed(let message): "Registration failed: \(message)"
        case .connectionFailed(let message): "Couldn\u{2019}t reach the helper: \(message)"
        case .notFound: "The helper isn\u{2019}t part of this build."
        }
    }
}

/// Everything `HelperClient` needs from `SMAppService`, behind a protocol so tests can script
/// status sequences and registration outcomes without ever touching the real daemon — this task's
/// explicit instruction is build + unit-verify only, no live registration on this machine.
protocol HelperServiceControlling: Sendable {
    func currentStatus() -> SMAppService.Status
    func register() throws
    func openApprovalSettings()
}

/// Everything `HelperClient` needs from a live XPC connection, behind a protocol for the same
/// reason. A fresh `HelperConnecting` is made by `HelperClient` every time it leaves
/// `.handshaking` successfully, and discarded on any failure — PLAN Appendix B's
/// "unregister/re-register recovery": a half-broken connection is never retried in place.
protocol HelperConnecting: Sendable {
    func handshake() async throws -> HelperHandshake
    func perform(_ operation: MaintenanceOperation) async throws -> MaintenanceOutcome
    func invalidate()
}

/// App-side half of PLAN Appendix B's helper lifecycle. Owns the one `HelperConnecting` instance
/// currently trusted to carry operations, and refuses `run(_:)` from every state except `.ready`.
@MainActor
@Observable
final class HelperClient {
    private(set) var state: HelperClientState = .notRegistered

    private let service: any HelperServiceControlling
    private let makeConnection: @Sendable () -> any HelperConnecting
    private var connection: (any HelperConnecting)?

    init(
        service: any HelperServiceControlling = SMAppServiceHelperControl(),
        makeConnection: @escaping @Sendable () -> any HelperConnecting = { XPCHelperConnection() }
    ) {
        self.service = service
        self.makeConnection = makeConnection
    }

    /// Read-only: reflects whatever `SMAppService` already knows (a prior session's approval, a
    /// since-revoked one) without ever calling `register()`. Safe to call at every Maintenance
    /// screen appearance, including the very first one — PLAN §3 restricts `register()` to first
    /// *use*, not a status read.
    func refreshFromCurrentStatus() async {
        await apply(status: service.currentStatus())
    }

    /// The one call PLAN §3 restricts to "first use of Maintenance". Checks the real current
    /// status *before* ever calling `register()`: `SMAppService.register()` throws
    /// `kSMErrorAlreadyRegistered` if called again while already registered, which would otherwise
    /// misreport an already-`.requiresApproval`/`.enabled` helper as a fresh registration failure.
    func requestAccess() async {
        switch service.currentStatus() {
        case .enabled:
            await connectAndHandshake()
            return
        case .requiresApproval:
            state = .requiresApproval
            return
        default:
            break
        }

        state = .registering
        do {
            try service.register()
        } catch {
            state = .unavailable(.registrationFailed(String(describing: error)))
            return
        }
        await apply(status: service.currentStatus())
    }

    func openApprovalSettings() {
        service.openApprovalSettings()
    }

    /// Refuses outright unless `state` is `.ready` — there is no path from any other state,
    /// `.incompatible` included, to actually sending an operation.
    func run(_ operation: MaintenanceOperation) async -> MaintenanceOutcome {
        guard case .ready = state, let connection else {
            return .failed(reason: "Helper isn\u{2019}t connected yet.")
        }
        do {
            return try await connection.perform(operation)
        } catch {
            connection.invalidate()
            self.connection = nil
            state = .unavailable(.connectionFailed(String(describing: error)))
            return .failed(reason: "\(error)")
        }
    }

    // MARK: - State machine

    private func apply(status: SMAppService.Status) async {
        switch status {
        case .notRegistered:
            state = .notRegistered
        case .requiresApproval:
            state = .requiresApproval
        case .notFound:
            state = .unavailable(.notFound)
        case .enabled:
            await connectAndHandshake()
        @unknown default:
            state = .unavailable(.notFound)
        }
    }

    private func connectAndHandshake() async {
        state = .handshaking
        let connection = makeConnection()
        do {
            let handshake = try await connection.handshake()
            if handshake.protocolVersion == HelperProtocolVersion.current {
                self.connection = connection
                state = .ready(handshake)
            } else {
                connection.invalidate()
                self.connection = nil
                state = .incompatible(
                    helperProtocolVersion: handshake.protocolVersion,
                    appProtocolVersion: HelperProtocolVersion.current
                )
            }
        } catch {
            connection.invalidate()
            self.connection = nil
            state = .unavailable(.connectionFailed(String(describing: error)))
        }
    }
}

// MARK: - Real SMAppService-backed control

/// `SMAppService` is a plain Objective-C object with no `Sendable` annotation of its own; every
/// method used here (`status`, `register()`, the `openSystemSettingsLoginItems()` class method) is
/// a quick, self-contained call Apple documents as safe to invoke from app code, so `@unchecked` is
/// asserting exactly that and nothing more — the same trade this codebase already makes for
/// `SMAppService.mainApp`/`SMAppService.agent`/`SMAppService.daemon` reads in
/// `StartupItemsScreen.swift`.
struct SMAppServiceHelperControl: HelperServiceControlling, @unchecked Sendable {
    private let service = SMAppService.daemon(plistName: HelperIdentity.launchDaemonPlistName)

    func currentStatus() -> SMAppService.Status { service.status }
    func register() throws { try service.register() }
    func openApprovalSettings() { SMAppService.openSystemSettingsLoginItems() }
}
