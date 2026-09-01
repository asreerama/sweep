import Foundation
import SweepPolicy

/// Accepts or rejects each incoming XPC connection. By the time this delegate method runs, the
/// listener's own `setConnectionCodeSigningRequirement` has already rejected any peer not signed
/// by the trusted cert *and* not carrying Sweep's own app identifier (`HelperTrust`, Codex finding
/// #1) — Apple's own doc comment on that method: "the incoming connection is automatically
/// rejected before consulting the delegate." What is left to check here is a different axis of
/// trust entirely: *which logged-in user* is on the other end, not *what binary* is on the other
/// end. This check only runs once, at accept — `HelperService.perform(_:reply:)` re-runs the same
/// check on every subsequent call, because *who is logged into the console* can change mid-session
/// in a way *what binary connected* never does (Codex finding #3).
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    /// Same injection seam ``HelperService`` uses for its own per-call re-check — sharing one
    /// closure means accept-time and every subsequent `perform` call always consult the exact same
    /// console-user source, real or faked.
    private let currentConsoleUID: () -> uid_t?

    init(currentConsoleUID: @escaping () -> uid_t? = ConsoleUser.currentConsoleUID) {
        self.currentConsoleUID = currentConsoleUID
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        let callerUID = newConnection.effectiveUserIdentifier
        guard HelperTrust.isAuthorizedCaller(callerUID: callerUID, consoleUID: currentConsoleUID()) else {
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: SweepHelperXPCProtocol.self)
        // Codex finding #3: `HelperService` re-validates `callerUID` against a freshly-read
        // console UID at the *start* of every `perform` call, not only here at accept — see its
        // own doc comment. `newConnection` is passed through as the `HelperConnectionInvalidating`
        // that re-check severs on a mismatch.
        newConnection.exportedObject = HelperService(
            callerUID: callerUID,
            connection: newConnection,
            currentConsoleUID: currentConsoleUID
        )
        newConnection.resume()
        return true
    }
}
