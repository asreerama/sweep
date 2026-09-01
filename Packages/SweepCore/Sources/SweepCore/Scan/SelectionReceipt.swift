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

    /// Seals a ``SelectionBatch`` from this scan's receipts (Codex G1 finding #5): every receipt
    /// carries this scan's own ``ScanSummary/scanID``, so mixing receipts from two different
    /// scans into one batch is structurally impossible here. `SelectionBatch.init` still checks
    /// it, but only as defense in depth, since every receipt this method could ever pass it
    /// already shares one `scanID` by construction.
    ///
    /// - Parameters:
    ///   - receiptIDs: Restricts the sealed batch to these ids (matched against
    ///     ``SelectionReceipt/id``). `nil` (the default) seals every receipt this scan produced.
    ///   - catalogDigest: The digest ``CleanService`` pinned for the catalog this scan ran
    ///     against (``CleanService/currentCatalogDigest()``), embedded so `CleanService` can
    ///     refuse to execute against a batch minted under a catalog that has since changed.
    ///   - mintedAt: When this batch was sealed. `CleanService` refuses one older than
    ///     ``SelectionBatch/maxAge``.
    public func sealedBatch(
        selecting receiptIDs: Set<String>? = nil,
        catalogDigest: String,
        mintedAt: Date = Date()
    ) throws -> SelectionBatch {
        let selected = receiptIDs.map { ids in receipts.filter { ids.contains($0.id) } } ?? receipts
        return try SelectionBatch(
            receipts: selected, scanSessionID: summary.scanID, catalogDigest: catalogDigest, mintedAt: mintedAt
        )
    }
}

/// A sealed, internally-consistent set of receipts a ``CleanRequest`` carries (Codex G1 finding
/// #5): one scan session, one catalog digest, one mint timestamp. Never receipts silently mixed
/// across scans, never replayed long after the scan that produced them, and never executed
/// against a catalog that has changed since minting.
///
/// The only way to get one is ``ScanResult/sealedBatch(selecting:catalogDigest:mintedAt:)``,
/// mirroring ``SelectionReceipt``'s own "no public initializer" discipline, so a caller cannot
/// hand-assemble a batch from receipts scavenged out of two different scans.
public struct SelectionBatch: Sendable {
    /// Refused fail-closed by ``CleanService`` once a batch is older than this (Codex G1
    /// finding #5: "mint timestamp with a max age (10 min)").
    public static let maxAge: TimeInterval = 10 * 60

    let receipts: [SelectionReceipt]
    let scanSessionID: UUID
    let catalogDigest: String
    let mintedAt: Date

    /// Why a batch could not be sealed. Distinct from ``CleanServiceError``'s execute-time
    /// refusals (staleness, catalog mismatch): this one is caught the instant a caller tries to
    /// combine receipts from more than one scan, before the batch even exists to be executed.
    public enum MintError: Error, Equatable, CustomStringConvertible {
        case mixedScanSessions
        public var description: String {
            "refused: receipts from more than one scan session cannot share a selection batch"
        }
    }

    init(receipts: [SelectionReceipt], scanSessionID: UUID, catalogDigest: String, mintedAt: Date) throws {
        guard receipts.allSatisfy({ $0.scanSessionID == scanSessionID }) else {
            throw MintError.mixedScanSessions
        }
        self.receipts = receipts
        self.scanSessionID = scanSessionID
        self.catalogDigest = catalogDigest
        self.mintedAt = mintedAt
    }
}
