import Foundation
import SweepPolicy

/// Accepts or rejects each incoming XPC connection. By the time this delegate method runs, the
/// listener's own `setConnectionCodeSigningRequirement` has already rejected any peer not signed
/// by the trusted cert — Apple's own doc comment on that method: "the incoming connection is
/// automatically rejected before consulting the delegate." What is left to check here is a
/// different axis of trust entirely: *which logged-in user* is on the other end, not *what binary*
/// is on the other end.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        guard HelperTrust.isAuthorizedCaller(
            callerUID: newConnection.effectiveUserIdentifier,
            consoleUID: ConsoleUser.currentConsoleUID()
        ) else {
            return false
        }

        newConnection.exportedInterface = NSXPCInterface(with: SweepHelperXPCProtocol.self)
        newConnection.exportedObject = HelperService()
        newConnection.resume()
        return true
    }
}
