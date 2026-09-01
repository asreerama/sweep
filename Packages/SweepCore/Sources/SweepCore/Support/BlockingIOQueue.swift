import Foundation

/// A dedicated serial queue for blocking filesystem work.
///
/// `fsync`, `openat`, `unlinkat` and directory enumeration all park the calling thread for an
/// unbounded time on a slow, encrypted or networked volume. Doing that inside an actor parks a
/// *cooperative-pool* thread, and that pool is sized to the core count, so a handful of slow
/// deletions can starve every unrelated task in the process (review finding #16).
///
/// Everything that blocks runs here; the owning actor only awaits the result. Serial is
/// deliberate: it also gives the file-descriptor state below it a single-threaded owner.
final class BlockingIOQueue: Sendable {
    private let queue: DispatchQueue

    init(label: String) {
        queue = DispatchQueue(label: label, qos: .utility, autoreleaseFrequency: .workItem)
    }

    /// Runs `work` on the queue and suspends the caller until it returns.
    func run<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}
