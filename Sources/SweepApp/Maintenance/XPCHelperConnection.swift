import Foundation
import SweepPolicy

enum HelperConnectionError: Error, Sendable, CustomStringConvertible {
    case proxyUnavailable
    var description: String { "The helper connection has no usable proxy." }
}

/// Real XPC transport to `SweepHelper`, over the mach service `HelperIdentity.machServiceName` the
/// LaunchDaemon plist advertises. One connection per attempt: `HelperClient` throws this away and
/// makes a fresh one on any failure rather than retrying in place (PLAN Appendix B).
///
/// `NSXPCConnection` is not `Sendable`; `@unchecked` is standing in for the guarantee
/// `remoteObjectProxyWithErrorHandler`'s own doc comment gives — "either the error handler or the
/// reply handler will be called exactly once" — which is what makes wrapping each call in exactly
/// one `withCheckedThrowingContinuation` safe.
final class XPCHelperConnection: HelperConnecting, @unchecked Sendable {
    private let connection: NSXPCConnection

    init() {
        connection = NSXPCConnection(machServiceName: HelperIdentity.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: SweepHelperXPCProtocol.self)
        connection.resume()
    }

    func handshake() async throws -> HelperHandshake {
        let data = try await callProxy { proxy, reply in proxy.handshake(reply: reply) }
        return try JSONDecoder().decode(HelperHandshake.self, from: data)
    }

    func perform(_ operation: MaintenanceOperation) async throws -> MaintenanceOutcome {
        let requestData = try JSONEncoder().encode(operation)
        let data = try await callProxy { proxy, reply in proxy.perform(requestData, reply: reply) }
        return try JSONDecoder().decode(MaintenanceOutcome.self, from: data)
    }

    func invalidate() {
        connection.invalidate()
    }

    /// One continuation, resumed exactly once by either the connection's own error handler or the
    /// XPC reply block — never both (see the type doc comment).
    private func callProxy(
        _ body: @escaping (SweepHelperXPCProtocol, @escaping (Data) -> Void) -> Void
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                continuation.resume(throwing: error)
            } as? SweepHelperXPCProtocol
            guard let proxy else {
                continuation.resume(throwing: HelperConnectionError.proxyUnavailable)
                return
            }
            body(proxy) { data in
                continuation.resume(returning: data)
            }
        }
    }
}
