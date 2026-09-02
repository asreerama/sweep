import Foundation

/// Every pkgutil receipt — identifiers and per-package file lists — loaded once, up front, so
/// matching never spawns a process.
///
/// Why this exists (user-reported "Looking for leftovers… takes forever", measured 2026-09-02):
/// `LeftoverMatcher.candidates(for:)` consults `files(forPackageID:)` for each installed package
/// to prove whether a receipt installed the exact app bundle under inspection. Against the live
/// `PkgutilReceiptsProvider` that is one `/usr/sbin/pkgutil --files` process spawn per package —
/// measured at ~4.4 s for 49 packages, which was ~95% of a leftover click's total latency (the
/// pre-walked `LeftoverRootIndex` had already made the filesystem half essentially free).
///
/// Loading here runs the same spawns, but concurrently and once per uninstaller session, in the
/// background alongside the root-index walk — after which every click's receipt evidence is two
/// dictionary lookups. The trade is staleness across one open uninstaller session, which is the
/// exact trade `LeftoverRootIndex` already makes for the filesystem side.
public struct PrefetchedPkgutilReceipts: PkgutilReceiptsProviding {
    private let ids: [String]
    private let filesByID: [String: [String]]

    public func packageIdentifiers() -> [String] { ids }
    public func files(forPackageID id: String) -> [String] { filesByID[id] ?? [] }

    /// No receipts at all — the safe stand-in when the prefetch was cancelled before finishing.
    public static let empty = PrefetchedPkgutilReceipts(ids: [], filesByID: [:])

    /// Runs `provider`'s per-package queries SERIALLY, off the calling actor. Measured on this
    /// machine (49 packages): serial ≈ 4.4 s, concurrent ≈ 48 s — parallel `pkgutil` invocations
    /// contend on the shared receipts store and serialize with heavy backoff, so fan-out makes it
    /// an order of magnitude slower, not faster. Serial in the background at open is the win.
    public static func load(
        from provider: some PkgutilReceiptsProviding & Sendable = PkgutilReceiptsProvider()
    ) async -> PrefetchedPkgutilReceipts {
        await Task.detached(priority: .userInitiated) {
            let ids = provider.packageIdentifiers()
            var filesByID: [String: [String]] = [:]
            for id in ids { filesByID[id] = provider.files(forPackageID: id) }
            return PrefetchedPkgutilReceipts(ids: ids, filesByID: filesByID)
        }.value
    }
}
