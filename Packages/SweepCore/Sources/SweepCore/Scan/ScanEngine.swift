import Foundation

/// Owns volume walks.
///
/// Walks run on a fixed pool of blocking threads, never on the cooperative pool and never one
/// thread per call; events reach the consumer through a watermarked buffer that blocks the walk
/// when the consumer falls behind. The actor itself only keeps bookkeeping, so a scan can be
/// cancelled by id or wholesale.
public actor ScanEngine {
    /// Events a walk may run ahead of its consumer. Past this the walk thread parks.
    public static let defaultEventWatermark = 256

    private let walker: any VolumeWalker
    private let pool: ScanWorkerPool
    private let eventWatermark: Int
    private var active: [UUID: ScanCancellationFlag] = [:]

    public init(
        walker: any VolumeWalker = ScanEngine.defaultWalker(),
        eventWatermark: Int = ScanEngine.defaultEventWatermark
    ) {
        self.init(walker: walker, eventWatermark: max(1, eventWatermark), pool: .shared)
    }

    /// ``BulkVolumeWalker``, unless `SWEEP_WALKER=filemanager` says otherwise.
    ///
    /// The two backends are semantically interchangeable, so the escape hatch exists purely to
    /// isolate a suspected enumeration bug in the field without a rebuild: set the variable, and
    /// a scan runs on the `FileManager.enumerator` implementation it shipped on.
    public static func defaultWalker(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> any VolumeWalker {
        environment["SWEEP_WALKER"]?.lowercased() == "filemanager"
            ? FileManagerVolumeWalker()
            : BulkVolumeWalker()
    }

    init(walker: any VolumeWalker, eventWatermark: Int, pool: ScanWorkerPool) {
        self.walker = walker
        self.pool = pool
        self.eventWatermark = eventWatermark
    }

    public var activeScanCount: Int { active.count }

    /// Stream of scan events. Terminating the stream (breaking out of the `for await`, or
    /// cancelling the enclosing task) cancels the walk at the next entry.
    ///
    /// The stream is demand-driven: one element is produced per consumer pull, and the walk is
    /// allowed at most ``defaultEventWatermark`` events of slack before it blocks.
    public func scan(_ request: ScanRequest) -> AsyncThrowingStream<ScanEvent, any Error> {
        let scanID = UUID()
        let flag = ScanCancellationFlag()
        let buffer = ScanEventBuffer(watermark: eventWatermark)
        active[scanID] = flag

        let walker = self.walker
        let lifetime = ScanLifetime(flag: flag, buffer: buffer) { [weak self] in
            Task { await self?.forget(scanID) }
        }

        pool.submit {
            Self.performWalk(
                scanID: scanID,
                request: request,
                walker: walker,
                flag: flag,
                buffer: buffer
            )
        }

        return AsyncThrowingStream { () async throws -> ScanEvent? in
            if Task.isCancelled {
                lifetime.cancel()
                return nil
            }
            let event = try await buffer.next()
            if event == nil { lifetime.cancel() }
            return event
        }
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

    // MARK: - Walk body (runs on a pool thread)

    private static func performWalk(
        scanID: UUID,
        request: ScanRequest,
        walker: any VolumeWalker,
        flag: ScanCancellationFlag,
        buffer: ScanEventBuffer
    ) {
        let start = Date()
        guard !request.roots.isEmpty else {
            buffer.finish(throwing: ScanError.noRoots)
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
                buffer.finish(throwing: ScanError.rootUnavailable(root, String(describing: error)))
                return
            }

            guard buffer.push(.started(scanID: scanID, root: root)) else { return }

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

                    // Blocks here when the consumer is behind, and returns false once it is gone.
                    guard buffer.push(.candidate(ScanCandidate(entry: entry, ruleID: request.ruleID))) else {
                        return .stop
                    }

                    if itemsSeen - lastProgressAt >= request.progressInterval {
                        lastProgressAt = itemsSeen
                        guard buffer.push(.progress(ScanProgress(
                            itemsSeen: itemsSeen,
                            allocatedBytes: totals.allocatedBytes,
                            currentPath: entry.url.path
                        ))) else { return .stop }
                    }
                    return .continue
                }
                issues.append(contentsOf: summary.issues)
            } catch {
                buffer.finish(throwing: error)
                return
            }
        }

        guard buffer.push(.progress(ScanProgress(
            itemsSeen: itemsSeen,
            allocatedBytes: totals.allocatedBytes,
            currentPath: nil
        ))) else { return }
        guard buffer.push(.finished(ScanSummary(
            scanID: scanID,
            totals: totals,
            issues: issues,
            duration: Date().timeIntervalSince(start),
            cancelled: flag.isCancelled
        ))) else { return }
        buffer.finish()
    }
}

/// Hard-link and clone-family dedup key.
struct InodeKey: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}
