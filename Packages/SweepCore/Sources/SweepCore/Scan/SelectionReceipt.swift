import Foundation

/// Proof that one path was actually seen by a real ``ScanEngine`` walk: candidate identity, the
/// rule id it was stamped with (if any), and which scan session produced it.
///
/// Codex Gate-1 finding #6: `CleanRequest` used to take a whole `ScanResult` plus a
/// `Set<candidateID>`, which forced every caller (`CleanAdapter`, most concretely) that did not
/// already hold a matching `ScanResult` in hand to run its own fresh subtree walk just to
/// produce one — and a subtree walk over-selects, because the walker enumerates only children,
/// never the root a user actually reviewed. A `SelectionReceipt` is the narrower thing a caller
/// actually needs: proof about *one* specific path, mintable only from a real scan
/// (``ScanResult/receipts`` / ``ScanResult/receipt(forCandidateID:)``), so `CleanService` can
/// re-verify that one path's identity live instead of demanding a whole fresh tree to select
/// from.
///
/// Every stored property is internal — "internal-cored, publicly opaque" — so nothing outside
/// this package can read or construct a receipt's contents, only pass one around by value and
/// compare it (`Equatable`) or list it (`Identifiable`). The only public window onto a receipt's
/// existence is the `id` it carries, which matches the ``ScanCandidate/id`` it was minted from.
public struct SelectionReceipt: Sendable, Equatable, Identifiable {
    let candidateID: String
    let url: URL
    /// Identity captured at scan time. `CleanService` re-reads this path live and compares
    /// against this snapshot (finding #6: "re-verifies identity live... instead of re-scanning
    /// subtrees") before ever authorizing anything against it.
    let scannedIdentity: FileIdentity
    let scannedParentIdentity: FileIdentity?
    let allocatedSize: Int64
    let ruleID: String?
    /// Which ``ScanEngine`` run produced this receipt. Not currently cross-checked against
    /// anything (there is only ever one live scan session in play at a time in this build), but
    /// carried so a future multi-session caller can refuse to mix receipts from a stale session
    /// without redesigning the type.
    let scanSessionID: UUID

    public var id: String { candidateID }

    init(candidate: ScanCandidate, scanSessionID: UUID) {
        self.candidateID = candidate.id
        self.url = candidate.url
        self.scannedIdentity = candidate.identity
        self.scannedParentIdentity = candidate.parentIdentity
        self.allocatedSize = candidate.allocatedSize
        self.ruleID = candidate.ruleID
        self.scanSessionID = scanSessionID
    }
}

extension ScanResult {
    /// Every candidate this scan found, each wrapped as an opaque, unforgeable receipt. The only
    /// way to get a ``SelectionReceipt`` for a real path outside this package is to run a real
    /// scan (``ScanEngine/run(_:)``) and read one back out of its result here — mirroring how
    /// `ScanResult` itself has no public initializer.
    public var receipts: [SelectionReceipt] {
        candidates.map { SelectionReceipt(candidate: $0, scanSessionID: summary.scanID) }
    }

    /// The receipt for one candidate id from this scan, if it found one.
    public func receipt(forCandidateID id: String) -> SelectionReceipt? {
        guard let candidate = candidates.first(where: { $0.id == id }) else { return nil }
        return SelectionReceipt(candidate: candidate, scanSessionID: summary.scanID)
    }
}
