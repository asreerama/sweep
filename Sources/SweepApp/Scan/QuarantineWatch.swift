import Foundation
import OSLog
import SweepCore
import SweepPolicy

/// Startup sweep for quarantine slots stranded by a crash mid-clean (Codex G1 finding #5
/// residual). Read-only: detection and logging here; surfacing/recovery UX arrives with the
/// first real report screen that has somewhere to put it.
enum QuarantineWatch {
    private static let log = Logger(subsystem: "com.aditya.sweep", category: "quarantine")

    /// Scans every resolvable operation root for stranded slots. Cheap (one shallow directory
    /// probe per root) and safe to run on every launch.
    static func checkAtStartup() -> [StrandedQuarantineSlot] {
        var stranded: [StrandedQuarantineSlot] = []
        for root in SweepPolicy.OperationRoot.allCases {
            for resolved in SweepPolicy.resolvedRoots(for: root) {
                stranded.append(contentsOf: QuarantineRecovery.strandedSlots(under: resolved.url))
            }
        }
        if stranded.isEmpty {
            log.debug("no stranded quarantine slots")
        } else {
            for slot in stranded {
                log.error("stranded quarantine slot: \(slot.slotURL.path, privacy: .public) (operation \(slot.operationID?.uuidString ?? "unknown", privacy: .public))")
            }
        }
        return stranded
    }
}
