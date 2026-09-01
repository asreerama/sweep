import Foundation

/// The entire wire surface between Sweep.app and `SweepHelper`. Two methods, both `Data` in /
/// `Data` out: the XPC method signatures themselves are generic, but what actually runs is not —
/// `perform`'s `requestData` must decode strictly as ``MaintenanceRequest``, whose `operation`
/// field is itself a ``MaintenanceOperation`` (PLAN §2: "closed enum ops ONLY... NO generic
/// command/path parameter anywhere in the protocol") and anything that fails to decode as one of
/// its three defined cases is refused, closed by construction rather than by convention. A
/// `Codable` JSON envelope over `Data` is used instead of `NSSecureCoding` on the enum itself so
/// the closed set lives in one auditable Swift type (`MaintenanceOperation`), not in a hand-rolled
/// `NSSecureCoding` implementation that could silently diverge from it. `MaintenanceRequest` also
/// carries the caller's declared protocol/policy versions on every call, not only at handshake
/// time (Codex finding #2) — see ``HelperService/perform(_:reply:)``.
///
/// Declared once here (not separately in the app and the helper) so both sides link against the
/// exact same method signatures — `NSXPCInterface(with:)` on either end must describe an identical
/// protocol or the connection simply cannot dispatch.
@objc public protocol SweepHelperXPCProtocol {
    /// Versioned handshake (PLAN Appendix B). `reply` carries a JSON-encoded ``HelperHandshake``.
    /// `HelperClient` never sends `perform` before a fresh handshake has confirmed protocol
    /// compatibility.
    func handshake(reply: @escaping (Data) -> Void)

    /// `requestData` must decode as ``MaintenanceRequest`` (the operation plus the caller's
    /// declared protocol/policy versions — Codex finding #2: the helper independently checks these
    /// on every call, not just at handshake); `reply` carries a JSON-encoded ``MaintenanceOutcome``.
    /// Never accepts or returns a path/command string of its own — see the type-level doc comment.
    func perform(_ requestData: Data, reply: @escaping (Data) -> Void)
}
