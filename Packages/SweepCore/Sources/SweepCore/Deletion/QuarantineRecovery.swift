import Foundation

/// One quarantine slot review finding #5 asked recovery to be able to surface: a per-item
/// directory under `.sweep-quarantine/<operationID>/` that still holds content, meaning a trash
/// attempt renamed something in and neither a successful trash-and-cleanup nor a successful
/// rollback ever emptied it back out.
public struct StrandedQuarantineSlot: Sendable, Equatable {
    /// `nil` only if the containing directory's name did not parse as a UUID at all — which
    /// never happens for a slot this codebase created, but a recovery pass over an unfamiliar
    /// tree should not crash on it either.
    public let operationID: UUID?
    /// The exclusive per-item directory itself (`.sweep-quarantine/<operationID>/<device>-<inode>/`).
    public let slotURL: URL
    /// The stranded object still inside the slot.
    public let itemURL: URL
}

/// Codex G1 finding #5's "recovery scan surfaces stranded quarantine slots": a read-only sweep
/// over one authorization-derived root's quarantine container. Never mutates anything — pairing
/// a stranded slot back up with the operation's WAL record (to decide whether to re-attempt the
/// trash, roll it back, or leave it for a person) is deliberately left to a caller, the same way
/// `WALJournal.interrupted` surfaces uncommitted operations without ever replaying them itself.
public enum QuarantineRecovery {

    /// Scans `root/.sweep-quarantine/*/*` for slots that still hold content. `root` must be one
    /// of the same authorization-derived roots Gate 1's trash-only mode anchors (or a disposable
    /// fixture root in tests) — this performs no authorization of its own, it only reads.
    public static func strandedSlots(under root: URL) -> [StrandedQuarantineSlot] {
        let quarantineDirectory = root.appending(path: FileDescriptorExecutor.quarantineDirectoryName)
        guard let operationEntries = try? FileManager.default.contentsOfDirectory(
            at: quarantineDirectory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var results: [StrandedQuarantineSlot] = []
        for operationEntry in operationEntries {
            guard Self.isDirectory(operationEntry) else { continue }
            let operationID = UUID(uuidString: operationEntry.lastPathComponent)

            guard let slotEntries = try? FileManager.default.contentsOfDirectory(
                at: operationEntry, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }

            for slotEntry in slotEntries {
                guard Self.isDirectory(slotEntry) else { continue }
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: slotEntry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ), let strandedItem = contents.first else {
                    continue   // empty slot: a rollback or a trash succeeded and cleanup just lagged
                }
                results.append(StrandedQuarantineSlot(operationID: operationID, slotURL: slotEntry, itemURL: strandedItem))
            }
        }
        return results
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
    }
}
