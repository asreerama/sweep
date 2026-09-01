import Foundation

/// Cooperative cancellation shared between the scan thread and the stream's lifetime. Both
/// sides are outside the actor, so the flag carries its own lock.
final class ScanCancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        cancelled = true
    }
}

/// A hand-off buffer between the blocking walk thread and the async consumer, with a hard
/// ceiling on how far the walk may run ahead.
///
/// The stream used to be `.unbounded`: a consumer that read slowly, or stopped reading, let the
/// walk buffer every candidate in a multi-million-entry tree (review finding #18). The fix has
/// to be backpressure rather than `.bufferingNewest`, because dropping a candidate silently
/// under-reports a scan.
///
/// So the producer blocks. `push` waits on a semaphore whose count is the watermark, and the
/// consumer signals it as each event leaves the buffer. The walk thread is a dedicated blocking
/// thread that exists to be blocked; the cooperative pool never is.
final class ScanEventBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private let space: DispatchSemaphore
    private var events: [ScanEvent] = []
    private var waiter: CheckedContinuation<ScanEvent?, any Error>?
    private var failure: (any Error)?
    private var finished = false
    private var closed = false
    let watermark: Int

    init(watermark: Int) {
        self.watermark = max(1, watermark)
        self.space = DispatchSemaphore(value: max(1, watermark))
    }

    /// Blocks the calling (walk) thread while the buffer is full. Returns `false` once the
    /// consumer is gone, which is the walk's signal to stop.
    @discardableResult
    func push(_ event: ScanEvent) -> Bool {
        lock.lock()
        if closed {
            lock.unlock()
            return false
        }
        lock.unlock()

        space.wait()

        lock.lock()
        if closed {
            lock.unlock()
            return false
        }
        if let waiter {
            // Handed straight to a waiting consumer: it never occupied the buffer.
            self.waiter = nil
            lock.unlock()
            space.signal()
            waiter.resume(returning: event)
            return true
        }
        events.append(event)
        lock.unlock()
        return true
    }

    func finish(throwing error: (any Error)? = nil) {
        lock.lock()
        guard !finished, !closed else { return lock.unlock() }
        finished = true
        failure = error
        let waiter = self.waiter
        self.waiter = nil
        let hasBuffered = !events.isEmpty
        lock.unlock()

        if let waiter, !hasBuffered {
            if let error { waiter.resume(throwing: error) } else { waiter.resume(returning: nil) }
        }
    }

    /// The consumer went away. Unblocks a producer parked in `push` and drops what is buffered.
    func close() {
        lock.lock()
        guard !closed else { return lock.unlock() }
        closed = true
        events.removeAll()
        let waiter = self.waiter
        self.waiter = nil
        lock.unlock()

        for _ in 0...watermark { space.signal() }
        waiter?.resume(returning: nil)
    }

    /// Next event, or `nil` at the end of the stream.
    func next() async throws -> ScanEvent? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ScanEvent?, any Error>) in
            lock.lock()
            if !events.isEmpty {
                let event = events.removeFirst()
                lock.unlock()
                space.signal()
                continuation.resume(returning: event)
                return
            }
            if closed {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            if finished {
                let error = failure
                lock.unlock()
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: nil) }
                return
            }
            waiter = continuation
            lock.unlock()
        }
    }
}

/// Ties the stream's lifetime to the walk's.
///
/// `AsyncThrowingStream(unfolding:)` has no termination handler, so the cancellation hook is the
/// object graph: the produce closure is the only strong reference to this box, the walk thread
/// holds the flag and the buffer but never the box. Break out of the `for await` and the box
/// deinits, which cancels the flag and closes the buffer, which unblocks and stops the walk.
final class ScanLifetime: @unchecked Sendable {
    private let flag: ScanCancellationFlag
    private let buffer: ScanEventBuffer
    private let onEnd: @Sendable () -> Void

    init(flag: ScanCancellationFlag, buffer: ScanEventBuffer, onEnd: @escaping @Sendable () -> Void) {
        self.flag = flag
        self.buffer = buffer
        self.onEnd = onEnd
    }

    func cancel() {
        flag.cancel()
        buffer.close()
    }

    deinit {
        flag.cancel()
        buffer.close()
        onEnd()
    }
}

/// A fixed set of blocking threads, and a queue for everything that does not fit.
///
/// Each scan used to start its own 4 MiB thread with no ceiling, so repeated calls could create
/// thousands of them (review finding #18). Two threads is the whole budget: directory walks are
/// I/O-bound and a third concurrent walk on the same device buys nothing but contention.
/// Additional requests wait their turn instead of spawning.
final class ScanWorkerPool: @unchecked Sendable {
    static let shared = ScanWorkerPool(workerCount: 2)

    private let condition = NSCondition()
    private var pending: [@Sendable () -> Void] = []
    private var running = 0
    let workerCount: Int

    init(workerCount: Int) {
        self.workerCount = max(1, workerCount)
        for index in 0..<self.workerCount {
            let thread = Thread { [weak self] in self?.workerLoop() }
            thread.name = "com.sweep.scan.worker.\(index)"
            thread.stackSize = 4 << 20
            thread.qualityOfService = .utility
            thread.start()
        }
    }

    /// Walks queued but not yet started. Diagnostics and tests.
    var queueDepth: Int {
        condition.lock()
        defer { condition.unlock() }
        return pending.count
    }

    var activeWalks: Int {
        condition.lock()
        defer { condition.unlock() }
        return running
    }

    func submit(_ work: @escaping @Sendable () -> Void) {
        condition.lock()
        pending.append(work)
        condition.signal()
        condition.unlock()
    }

    private func workerLoop() {
        while true {
            condition.lock()
            while pending.isEmpty {
                condition.wait()
            }
            let work = pending.removeFirst()
            running += 1
            condition.unlock()

            work()

            condition.lock()
            running -= 1
            condition.unlock()
        }
    }
}
