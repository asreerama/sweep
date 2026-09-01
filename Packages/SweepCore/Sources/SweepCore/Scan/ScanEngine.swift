import Foundation

/// Cooperative cancellation shared between the scan thread and the stream's termination
/// handler. Both sides are outside the actor, so the flag carries its own lock.
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

/// Owns volume walks. One walk runs per call on a dedicated blocking thread, never on the
/// cooperative pool; the actor itself only keeps bookkeeping so a scan can be cancelled by id
/// or wholesale.
public actor ScanEngine {
    private let walker: any VolumeWalker
    private var active: [UUID: ScanCancellationFlag] = [:]

    public init(walker: any VolumeWalker = FileManagerVolumeWalker()) {
        self.walker = walker
    }

    public var activeScanCount: Int { active.count }

    /// Stream of scan events. Terminating the stream (breaking out of the `for await`, or
    /// cancelling the enclosing task) cancels the walk at the next entry.
    public func scan(_ request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error> {
        let scanID = UUID()
        let flag = ScanCancellationFlag()
        active[scanID] = flag

        let walker = self.walker
        let (stream, continuation) = AsyncThrowingStream<ScanEvent, any Error>.makeStream(
            bufferingPolicy: .unbounded
        )

        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination { flag.cancel() }
            Task { await self?.forget(scanID) }
        }

        let thread = Thread {
            Self.performWalk(
                scanID: scanID,
                request: request,
                walker: walker,
                flag: flag,
                continuation: continuation
            )
        }
        thread.name = "com.sweep.scan.\(scanID.uuidString)"
        thread.stackSize = 4 << 20
        thread.qualityOfService = .utility
        thread.start()

        return stream
    }

    /// Convenience for callers that want the whole result: collects the stream.
    public func run(_ request: ScanRequest) async throws -> ScanResult {
        var candidates: [ScanCandidate] = []
        var summary: ScanSummary?
        for try await event in scan(request) {
            switch event {
            case .candidate(let candidate): candidates.append(candidate)
            case .finished(let value): summary = value
            case .started, .progress: break
            }
        }
        guard let summary else { throw CancellationError() }
        return ScanResult(summary: summary, candidates: candidates)
    }

    /// Cancels one in-flight scan. Cancellation is checked between entries, so a walk stuck in
    /// a single slow `readdir` finishes that call first.
    public func cancel(scanID: UUID) {
        active[scanID]?.cancel()
    }

    public func cancelAll() {
        for flag in active.values { flag.cancel() }
    }

    func forget(_ scanID: UUID) {
        active[scanID] = nil
    }

    // MARK: - Walk body (runs on the dedicated thread)

    private static func performWalk(
        scanID: UUID,
        request: ScanRequest,
        walker: any VolumeWalker,
        flag: ScanCancellationFlag,
        continuation: AsyncThrowingStream<ScanEvent, any Error>.Continuation
    ) {
        let start = Date()
        guard !request.roots.isEmpty else {
            continuation.finish(throwing: ScanError.noRoots)
            return
        }

        var totals = ScanTotals()
        var issues: [WalkIssue] = []
        var seenInodes = Set<InodeKey>()
        var itemsSeen = 0
        var lastProgressAt = 0
        let now = Date()

        for root in request.roots {
            if flag.isCancelled { break }

            let boundary: VolumeIdentity
            do {
                boundary = try VolumeIdentity.read(at: root)
            } catch {
                continuation.finish(throwing: ScanError.rootUnavailable(root, String(describing: error)))
                return
            }

            continuation.yield(.started(scanID: scanID, root: root))

            let options = WalkOptions(
                boundary: boundary,
                maximumDepth: request.maximumDepth,
                honorsPolicyDenylist: request.honorsPolicyDenylist,
                includesDirectories: request.includesDirectories
            )

            do {
                let summary = try walker.walk(root: root, options: options) { entry in
                    if flag.isCancelled { return .stop }

                    itemsSeen += 1

                    if let minimumAge = request.minimumAge {
                        let age = now.timeIntervalSince(entry.identity.modification.date)
                        if age < minimumAge { return .continue }
                    }

                    switch entry.identity.kind {
                    case .file:
                        totals.fileCount += 1
                        let key = InodeKey(device: entry.identity.deviceID, inode: entry.identity.inode)
                        if seenInodes.insert(key).inserted {
                            totals.allocatedBytes += entry.allocatedSize
                        } else {
                            totals.duplicateInodeCount += 1
                        }
                    case .directory:
                        totals.directoryCount += 1
                    case .symbolicLink, .other:
                        totals.otherCount += 1
                    }

                    continuation.yield(.candidate(ScanCandidate(entry: entry, ruleID: request.ruleID)))

                    if itemsSeen - lastProgressAt >= request.progressInterval {
                        lastProgressAt = itemsSeen
                        continuation.yield(.progress(ScanProgress(
                            itemsSeen: itemsSeen,
                            allocatedBytes: totals.allocatedBytes,
                            currentPath: entry.url.path
                        )))
                    }
                    return .continue
                }
                issues.append(contentsOf: summary.issues)
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }

        continuation.yield(.progress(ScanProgress(
            itemsSeen: itemsSeen,
            allocatedBytes: totals.allocatedBytes,
            currentPath: nil
        )))
        continuation.yield(.finished(ScanSummary(
            scanID: scanID,
            totals: totals,
            issues: issues,
            duration: Date().timeIntervalSince(start),
            cancelled: flag.isCancelled
        )))
        continuation.finish()
    }
}

/// Hard-link and clone-family dedup key.
struct InodeKey: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}
