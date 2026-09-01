import XCTest
@testable import SweepCore

/// A walker that emits `entryCount` synthetic entries and records how many it managed to hand
/// over. With an unbounded stream it runs to the end regardless of the consumer; with a
/// watermark it parks.
final class CountingWalker: VolumeWalker, @unchecked Sendable {
    private let lock = NSLock()
    private var emittedCount = 0
    let entryCount: Int
    /// Held while the walk is in flight, so concurrency can be observed.
    let tracker: ConcurrencyTracker?
    let perWalkDelay: TimeInterval

    init(entryCount: Int, tracker: ConcurrencyTracker? = nil, perWalkDelay: TimeInterval = 0) {
        self.entryCount = entryCount
        self.tracker = tracker
        self.perWalkDelay = perWalkDelay
    }

    var emitted: Int {
        lock.withLock { emittedCount }
    }

    func walk(root: URL, options: WalkOptions, visit: (WalkEntry) -> WalkDirective) throws -> WalkSummary {
        tracker?.enter()
        defer { tracker?.leave() }
        if perWalkDelay > 0 { Thread.sleep(forTimeInterval: perWalkDelay) }

        for index in 0..<entryCount {
            let identity = FileIdentity(
                deviceID: options.boundary.deviceID,
                inode: UInt64(1_000 + index),
                volume: options.boundary,
                kind: .file,
                linkCount: 1,
                modification: FileTimestamp(seconds: 1_700_000_000, nanoseconds: 0),
                statusChange: FileTimestamp(seconds: 1_700_000_000, nanoseconds: 0),
                size: 4096,
                flags: 0
            )
            let entry = WalkEntry(
                url: root.appending(path: "entry-\(index).bin"),
                identity: identity,
                parentIdentity: nil,
                allocatedSize: 4096,
                contentAccessDate: nil,
                depth: 1
            )
            lock.withLock { emittedCount += 1 }
            if case .stop = visit(entry) {
                return WalkSummary(issues: [], stopped: true)
            }
        }
        return WalkSummary(issues: [], stopped: false)
    }
}

final class ConcurrencyTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0
    private var peak = 0

    var peakConcurrency: Int { lock.withLock { peak } }

    func enter() {
        lock.withLock {
            current += 1
            peak = max(peak, current)
        }
    }

    func leave() {
        lock.withLock { current -= 1 }
    }
}

/// Review finding #18: an unbounded event buffer and one unbounded 4 MiB thread per scan.
final class ScanBackpressureTests: XCTestCase {

    func testTheWalkStopsRunningAheadWhenTheConsumerStopsReading() async throws {
        let tree = try TempTree("scan-backpressure")
        let watermark = 16
        let walker = CountingWalker(entryCount: 20_000)
        let engine = ScanEngine(
            walker: walker,
            eventWatermark: watermark,
            pool: ScanWorkerPool(workerCount: 1)
        )

        let stream = await engine.scan(ScanRequest(roots: [tree.root], progressInterval: .max))
        var iterator = stream.makeAsyncIterator()
        _ = try await iterator.next()   // .started
        _ = try await iterator.next()   // first candidate

        // Read nothing for a while. An unbounded buffer would have swallowed all 20,000 by now.
        try await Task.sleep(for: .milliseconds(300))
        let emitted = walker.emitted
        XCTAssertLessThanOrEqual(
            emitted,
            watermark + 8,
            "the walk buffered \(emitted) entries ahead of a consumer that read two"
        )

        // Draining releases the producer and the scan completes normally.
        var drained = 0
        while try await iterator.next() != nil { drained += 1 }
        XCTAssertGreaterThan(drained, watermark)
        XCTAssertEqual(walker.emitted, 20_000)
    }

    func testNoMoreThanTwoVolumeWalksRunAtOnce() async throws {
        let tree = try TempTree("scan-pool")
        let tracker = ConcurrencyTracker()
        let walker = CountingWalker(entryCount: 4, tracker: tracker, perWalkDelay: 0.05)
        let engine = ScanEngine(
            walker: walker,
            eventWatermark: 64,
            pool: ScanWorkerPool(workerCount: 2)
        )
        let request = ScanRequest(roots: [tree.root])

        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { _ = try? await engine.run(request) }
            }
        }

        XCTAssertLessThanOrEqual(
            tracker.peakConcurrency,
            2,
            "eight scans must queue behind two workers, not start eight walks"
        )
        XCTAssertGreaterThan(tracker.peakConcurrency, 0)
    }

    func testQueuedScansAllComplete() async throws {
        let tree = try TempTree("scan-pool-queue")
        let walker = CountingWalker(entryCount: 3, perWalkDelay: 0.01)
        let engine = ScanEngine(
            walker: walker,
            eventWatermark: 32,
            pool: ScanWorkerPool(workerCount: 2)
        )
        let request = ScanRequest(roots: [tree.root])

        let results = await withTaskGroup(of: Int.self) { group -> [Int] in
            for _ in 0..<6 {
                group.addTask {
                    ((try? await engine.run(request))?.candidates.count) ?? -1
                }
            }
            var collected: [Int] = []
            for await value in group { collected.append(value) }
            return collected
        }

        XCTAssertEqual(results.count, 6)
        XCTAssertTrue(results.allSatisfy { $0 == 3 }, "queued scans still deliver every candidate: \(results)")
    }

    func testAbandoningAStreamReleasesTheWorker() async throws {
        let tree = try TempTree("scan-abandon")
        let pool = ScanWorkerPool(workerCount: 1)
        let walker = CountingWalker(entryCount: 50_000)
        let engine = ScanEngine(walker: walker, eventWatermark: 8, pool: pool)

        for try await event in await engine.scan(ScanRequest(roots: [tree.root])) {
            if case .candidate = event { break }
        }

        // The single worker has to become free again, or every later scan would hang behind a
        // walk nobody is reading.
        let second = CountingWalker(entryCount: 2)
        let secondEngine = ScanEngine(walker: second, eventWatermark: 8, pool: pool)
        let result = try await secondEngine.run(ScanRequest(roots: [tree.root]))
        XCTAssertEqual(result.candidates.count, 2)
    }

    func testBufferDeliversEveryEventInOrder() async throws {
        let buffer = ScanEventBuffer(watermark: 4)
        let tree = try TempTree("scan-buffer")
        let scanID = UUID()

        let producer = Thread {
            for _ in 0..<64 {
                _ = buffer.push(.started(scanID: scanID, root: tree.root))
            }
            buffer.finish()
        }
        producer.start()

        var count = 0
        while try await buffer.next() != nil { count += 1 }
        XCTAssertEqual(count, 64, "backpressure must never drop an event")
    }
}
