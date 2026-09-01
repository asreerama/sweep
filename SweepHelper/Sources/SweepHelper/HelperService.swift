import Foundation
import SweepPolicy

/// The XPC-exported object. Every method is `Data` in, `Data` out (``SweepHelperXPCProtocol``);
/// this class does no decision-making of its own beyond decode-or-refuse — ``MaintenanceExecutor``
/// is the only thing that ever turns a decoded ``MaintenanceOperation`` into a real command.
final class HelperService: NSObject, SweepHelperXPCProtocol {
    /// Informational only — shown in the app's status line, never compared for compatibility
    /// (``HelperProtocolVersion/current`` is what gates that).
    private static let helperBuildVersion = "0.1.0"

    func handshake(reply: @escaping (Data) -> Void) {
        let handshake = HelperHandshake(
            protocolVersion: HelperProtocolVersion.current,
            helperBuildVersion: Self.helperBuildVersion,
            policyVersion: MaintenancePolicyVersion.current
        )
        reply((try? JSONEncoder().encode(handshake)) ?? Data())
    }

    func perform(_ requestData: Data, reply: @escaping (Data) -> Void) {
        let outcome: MaintenanceOutcome
        do {
            let operation = try JSONDecoder().decode(MaintenanceOperation.self, from: requestData)
            outcome = MaintenanceExecutor.execute(operation, dryRun: MaintenanceExecutor.isDryRunRequested())
        } catch {
            // Anything that is not a well-formed, currently-defined `MaintenanceOperation` is
            // refused here, closed by construction — there is no fallback interpretation of a
            // request that fails to decode, and no path from a decode failure to a process launch.
            outcome = .failed(reason: "refused: request did not decode as a known maintenance operation")
        }
        reply((try? JSONEncoder().encode(outcome)) ?? Data())
    }
}
