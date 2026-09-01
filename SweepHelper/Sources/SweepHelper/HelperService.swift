import Foundation
import SweepPolicy

/// The one piece of `NSXPCConnection` `HelperService` needs: a way to sever a session whose caller
/// is no longer authorized. A protocol — not a direct `NSXPCConnection` reference — so the
/// per-call re-validation this type does (Codex finding #3) is testable with a small recording
/// fake, never a real XPC channel. `NSXPCConnection.invalidate()` already matches this signature.
protocol HelperConnectionInvalidating: AnyObject {
    func invalidate()
}

extension NSXPCConnection: HelperConnectionInvalidating {}

/// The XPC-exported object. Every method is `Data` in, `Data` out (``SweepHelperXPCProtocol``);
/// this class does no decision-making of its own beyond decode-or-refuse and the two
/// per-call security gates documented on `perform(_:reply:)` — ``MaintenanceExecutor`` is the only
/// thing that ever turns a decoded ``MaintenanceOperation`` into a real command.
///
/// One instance per accepted connection (``HelperListenerDelegate``), so `callerUID` — captured
/// once, at accept time, from `NSXPCConnection.effectiveUserIdentifier` — never needs to change:
/// the connection's peer identity cannot change mid-life. What *can* change mid-life is which
/// account is logged into the console (fast user switching), which is exactly what
/// `currentConsoleUID` is re-consulted against on every `perform` call, not just once at accept.
final class HelperService: NSObject, SweepHelperXPCProtocol {
    /// Informational only — shown in the app's status line, never compared for compatibility
    /// (``HelperProtocolVersion/current`` is what gates that).
    private static let helperBuildVersion = "0.1.0"

    /// The UID `HelperListenerDelegate` already proved, at accept time, matched the console user.
    private let callerUID: uid_t

    /// Who is logged into the console *right now* — re-read on every `perform` call, never cached
    /// across calls. Defaults to the real system call; tests inject a scripted sequence so a
    /// fast-user-switch mid-session is reproducible without a real console session (Codex finding
    /// #3: "accepted sessions survive console-user changes").
    private let currentConsoleUID: () -> uid_t?

    /// Severs the connection this service was exported on. `weak` because the real
    /// `NSXPCConnection` retains its `exportedObject` — a strong reference back would be a
    /// retain cycle the connection could never break itself.
    private weak var connection: (any HelperConnectionInvalidating)?

    /// Turns a validated, decoded ``MaintenanceOperation`` into a real outcome. Injected so tests
    /// can observe "did the gates above let this through" without ever spawning
    /// `dscacheutil`/`killall`/`mdutil`/`tmutil` as a normal-user test process.
    private let executor: (MaintenanceOperation) -> MaintenanceOutcome

    init(
        callerUID: uid_t,
        connection: any HelperConnectionInvalidating,
        currentConsoleUID: @escaping () -> uid_t? = ConsoleUser.currentConsoleUID,
        executor: @escaping (MaintenanceOperation) -> MaintenanceOutcome = { operation in
            MaintenanceExecutor.execute(operation, dryRun: MaintenanceExecutor.isDryRunRequested())
        }
    ) {
        self.callerUID = callerUID
        self.connection = connection
        self.currentConsoleUID = currentConsoleUID
        self.executor = executor
    }

    func handshake(reply: @escaping (Data) -> Void) {
        let handshake = HelperHandshake(
            protocolVersion: HelperProtocolVersion.current,
            helperBuildVersion: Self.helperBuildVersion,
            policyVersion: MaintenancePolicyVersion.current
        )
        reply(encode(handshake))
    }

    /// Two independent, helper-enforced gates run before anything else, in this order, on *every*
    /// call — neither is a one-time check done only at connection-accept or handshake time:
    ///
    ///   1. **Console-user re-check** (Codex finding #3). `HelperListenerDelegate` already proved
    ///      `callerUID` matched the console user at accept time; that guarantee decays the moment
    ///      someone else logs into the console (fast user switching) without this connection ever
    ///      closing. Re-running `HelperTrust.isAuthorizedCaller` here, against a freshly-read
    ///      console UID, is what makes a stale session refuse itself instead of quietly staying
    ///      privileged for a now-background user. A mismatch also invalidates the connection so no
    ///      further call on it can succeed either.
    ///   2. **Server-side version gate** (Codex finding #2). Before this existed, only
    ///      `HelperClient` compared `HelperHandshake.protocolVersion` after `handshake()` — a
    ///      caller could skip the handshake and call `perform` directly, or ignore an
    ///      `.incompatible` result. `MaintenanceRequest` carries the caller's declared
    ///      protocol/policy versions on *this* call, and both must match exactly or the request is
    ///      refused here, before ``MaintenanceExecutor`` ever runs, with a rejection that names
    ///      both versions.
    func perform(_ requestData: Data, reply: @escaping (Data) -> Void) {
        guard HelperTrust.isAuthorizedCaller(callerUID: callerUID, consoleUID: currentConsoleUID()) else {
            connection?.invalidate()
            reply(encode(.failed(reason: "refused: caller is no longer the logged-in console user")))
            return
        }

        let outcome: MaintenanceOutcome
        do {
            let request = try JSONDecoder().decode(MaintenanceRequest.self, from: requestData)
            if request.protocolVersion != HelperProtocolVersion.current {
                outcome = .failed(reason:
                    "refused: client protocol version \(request.protocolVersion) is unsupported " +
                    "(helper requires \(HelperProtocolVersion.current))")
            } else if request.policyVersion != MaintenancePolicyVersion.current {
                outcome = .failed(reason:
                    "refused: client policy version \(request.policyVersion) is unsupported " +
                    "(helper requires \(MaintenancePolicyVersion.current))")
            } else {
                outcome = executor(request.operation)
            }
        } catch {
            // Anything that is not a well-formed ``MaintenanceRequest`` wrapping a
            // currently-defined `MaintenanceOperation` is refused here, closed by construction —
            // there is no fallback interpretation of a request that fails to decode, and no path
            // from a decode failure to a process launch.
            outcome = .failed(reason: "refused: request did not decode as a known maintenance operation")
        }
        reply(encode(outcome))
    }

    private func encode(_ handshake: HelperHandshake) -> Data {
        (try? JSONEncoder().encode(handshake)) ?? Data()
    }

    private func encode(_ outcome: MaintenanceOutcome) -> Data {
        (try? JSONEncoder().encode(outcome)) ?? Data()
    }
}
