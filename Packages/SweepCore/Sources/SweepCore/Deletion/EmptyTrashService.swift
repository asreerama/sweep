import Darwin
import Foundation

/// Empty Trash (PLAN §3 module 1): a separate, explicitly irreversible operation — never part
/// of any scan's clean, never auto-selected, always its own second confirmation.
///
/// The PLAN's contract, verbatim: "item identities snapshotted at review, anything added after
/// review skipped." `review()` captures the Trash's top-level entries with their device+inode
/// identities; `execute(review:)` deletes exactly the reviewed objects — an entry that changed
/// identity since review settles as a per-item refusal, an entry added after review is counted
/// and left untouched, and nothing is ever enumerated-and-deleted in one breath.
///
/// Unlike every other mutation in this app, deletion here is `FileManager.removeItem`, not a
/// move to the Trash — these files are *in* the Trash; "reversible" stopped being on offer the
/// moment the user asked to empty it. That is exactly why the double confirmation and the
/// snapshot discipline live here rather than in the shared clean pipeline.
public enum EmptyTrashService {

    /// One reviewed top-level Trash entry. `identity` is the consent binding: execute deletes
    /// the object with this device+inode at this name, or refuses.
    public struct ReviewedItem: Sendable, Equatable {
        public let url: URL
        public let identity: FileIdentity
        public let allocatedSize: Int64

        public var name: String { url.lastPathComponent }
    }

    public struct Review: Sendable, Equatable {
        public let items: [ReviewedItem]
        public let totalBytes: Int64
        public let capturedAt: Date

        public var itemCount: Int { items.count }
        public var isEmpty: Bool { items.isEmpty }
    }

    public enum ItemResult: Sendable, Equatable {
        case deleted
        /// The reviewed object is gone or a different object now bears its name — refused,
        /// never "deleted whatever is there now".
        case changedSinceReview
        case vanishedSinceReview
        case failed(String)
    }

    public struct Outcome: Sendable, Equatable {
        public let item: ReviewedItem
        public let result: ItemResult
    }

    public struct Report: Sendable, Equatable {
        public let outcomes: [Outcome]
        /// Entries present at execute time that were NOT in the review — the PLAN's "anything
        /// added after review skipped", counted so the UI can say so instead of silently
        /// leaving a non-empty Trash unexplained.
        public let lateAdditionsSkipped: Int
        /// Volume-capacity delta, same honesty rule as every other freed figure in this app.
        public let freedBytesEstimate: Int64

        public var deletedCount: Int { outcomes.count { $0.result == .deleted } }
        public var refusedCount: Int { outcomes.count { $0.result != .deleted } }
    }

    /// Snapshot the current user's `~/.Trash`. Production entry point — the directory is
    /// resolved here, never caller-supplied (PLAN §2: producers derive their roots).
    public static func review() -> Review {
        review(trashDirectory: defaultTrashDirectory())
    }

    /// The fast snapshot: entries and identities only, every `allocatedSize` zero. Identity
    /// capture is one `lstat` per entry; tree sizing is the expensive part (a full Trash can
    /// hold hundreds of app-sized trees), and the consent `execute(review:)` binds to is the
    /// identity set, never the sizes — so the UI opens on this immediately and streams sizes in
    /// afterward via ``allocatedSize(of:)``.
    public static func snapshot() -> Review {
        review(trashDirectory: defaultTrashDirectory(), includeSizes: false)
    }

    /// One reviewed entry's on-disk tree size, measured on demand — the streaming half of
    /// ``snapshot()``.
    public static func allocatedSize(of item: ReviewedItem) -> Int64 {
        AllocatedTreeSize.bytes(atPath: item.url.path)
    }

    /// Execute against a prior review. Only ever deletes objects whose live identity matches
    /// what the review captured.
    public static func execute(review: Review) -> Report {
        execute(review: review, trashDirectory: defaultTrashDirectory())
    }

    static func defaultTrashDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: ".Trash")
    }

    /// Internal seam so tests exercise the full snapshot/verify/delete logic against a fixture
    /// directory. Not reachable from outside the package: the public entry points above are the
    /// only ones an external caller can name, and they always mean the real `~/.Trash`.
    static func review(trashDirectory: URL, includeSizes: Bool = true) -> Review {
        // The Trash itself must be a real directory (lstat — a symlinked `.Trash` is refused
        // wholesale rather than followed somewhere else).
        guard let trashIdentity = try? FileIdentity.read(at: trashDirectory), trashIdentity.kind == .directory else {
            return Review(items: [], totalBytes: 0, capturedAt: Date())
        }
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: trashDirectory, includingPropertiesForKeys: nil, options: []
        )) ?? []

        var items: [ReviewedItem] = []
        var total: Int64 = 0
        for entry in entries {
            // `.DS_Store` is Finder's own bookkeeping, not user content; deleting it from the
            // Trash achieves nothing and it regenerates immediately.
            if entry.lastPathComponent == ".DS_Store" { continue }
            guard let identity = try? FileIdentity.read(at: entry) else { continue }
            let size = includeSizes ? AllocatedTreeSize.bytes(atPath: entry.path) : 0
            items.append(ReviewedItem(url: entry, identity: identity, allocatedSize: size))
            total += size
        }
        if includeSizes {
            items.sort { $0.allocatedSize > $1.allocatedSize }
        }
        return Review(items: items, totalBytes: total, capturedAt: Date())
    }

    static func execute(review: Review, trashDirectory: URL) -> Report {
        let before = VolumeCapacity.sample(volumes: [trashDirectory])

        let reviewedNames = Set(review.items.map(\.name))
        var outcomes: [Outcome] = []
        outcomes.reserveCapacity(review.items.count)

        for item in review.items {
            // Check-then-delete on the same pathname is a TOCTOU window (Codex Gate-2 review,
            // finding-#2 class: a swap between the identity read and the removal deletes the
            // replacement). Order here closes the nameable window: rename the entry to an
            // unguessable slot FIRST (atomic; an attacker cannot target a name they cannot
            // predict), verify the slot's identity against the review, and only then remove.
            // A pre-rename swap is caught by the post-rename check and the imposter is
            // restored under its original name, untouched.
            let slot = trashDirectory.appending(path: ".sweep-emptying-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: item.url, to: slot)
            } catch let error as NSError where error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError {
                outcomes.append(Outcome(item: item, result: .vanishedSinceReview))
                continue
            } catch {
                outcomes.append(Outcome(item: item, result: .failed((error as NSError).localizedDescription)))
                continue
            }

            let slotIdentity = try? FileIdentity.read(at: slot)
            guard let slotIdentity, slotIdentity.isSameFile(as: item.identity) else {
                // Not the reviewed object: put whatever it is back where it was and refuse.
                try? FileManager.default.moveItem(at: slot, to: item.url)
                outcomes.append(Outcome(item: item, result: .changedSinceReview))
                continue
            }

            do {
                try FileManager.default.removeItem(at: slot)
                outcomes.append(Outcome(item: item, result: .deleted))
            } catch {
                // The object is verified-ours but could not be removed; restore its name so
                // the Trash never accumulates anonymous slot entries.
                try? FileManager.default.moveItem(at: slot, to: item.url)
                outcomes.append(Outcome(item: item, result: .failed((error as NSError).localizedDescription)))
            }
        }

        // Count what appeared after the review — untouched by contract, reported so the UI can
        // say "N newer items were left alone" instead of the Trash mysteriously staying
        // non-empty.
        let lateAdditions = ((try? FileManager.default.contentsOfDirectory(
            at: trashDirectory, includingPropertiesForKeys: nil, options: []
        )) ?? [])
        .filter { $0.lastPathComponent != ".DS_Store" && !reviewedNames.contains($0.lastPathComponent) }
        .count

        let after = VolumeCapacity.sample(volumes: [trashDirectory])
        return Report(
            outcomes: outcomes,
            lateAdditionsSkipped: lateAdditions,
            freedBytesEstimate: VolumeCapacity.freedBytesEstimate(before: before, after: after)
        )
    }
}
