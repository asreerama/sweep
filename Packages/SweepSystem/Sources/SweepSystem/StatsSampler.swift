import Foundation

/// Samples every stat this package exposes on a configurable interval and publishes each
/// reading as a `SystemSnapshot`, for the menubar (PLAN.md §3/§7).
///
/// One actor owns all per-sample mutable state (the CPU and network samplers' previous-tick
/// baselines, the latest memory-pressure level) so every `sample`/`snapshots` caller sees a
/// consistent, single-threaded view without needing its own synchronization.
///
/// Sampling is designed to be cheap: every reader below is either a single stateless syscall
/// (memory, disk, battery) or a plain-struct delta against a cached previous sample (CPU,
/// network) — no sub-actors, no per-tick `Task` fan-out, no retained kernel buffers between
/// samples. See `StatsSamplerCostTests` for a measured per-sample cost on real hardware.
public actor StatsSampler {
    public struct Configuration: Sendable {
        /// How often `snapshots()` yields a new reading.
        public var interval: Duration
        /// How many entries `SystemSnapshot.topProcesses` carries.
        public var topProcessCount: Int
        /// Interface name prefix aggregated into `SystemSnapshot.network` (PLAN.md: "aggregate
        /// across en* interfaces").
        public var networkInterfacePrefix: String
        /// How often disk usage is actually re-read from the volumes' `URLResourceKey`s.
        ///
        /// Measured on the machine this package was built on: each mounted volume's capacity
        /// resource values cost roughly 1.5-2 ms to fetch (four volumes, ~7 ms total) —
        /// dominating the entire sample cost and blowing the <0.5% CPU @ 2s-interval budget on
        /// its own if re-read on every tick. Disk capacity does not change on 2-second
        /// timescales the way CPU/memory/network do, so it is refreshed on this slower cadence
        /// instead; every `SystemSnapshot` in between reuses the last reading. See
        /// `StatsSamplerTests.testMeasuredSampleCost`.
        public var diskRefreshInterval: Duration

        public init(
            interval: Duration = .seconds(2),
            topProcessCount: Int = 5,
            networkInterfacePrefix: String = "en",
            diskRefreshInterval: Duration = .seconds(10)
        ) {
            self.interval = interval
            self.topProcessCount = topProcessCount
            self.networkInterfacePrefix = networkInterfacePrefix
            self.diskRefreshInterval = diskRefreshInterval
        }
    }

    private let configuration: Configuration
    private var cpuSampler = CPUStatsSampler()
    private var networkSampler: NetworkStatsSampler
    private var latestPressure: MemoryPressureLevel = .normal
    private var pressureWatchTask: Task<Void, Never>?
    private var cachedDisks: [DiskStats] = []
    private var lastDiskRefresh: ContinuousClock.Instant?

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
        self.networkSampler = NetworkStatsSampler(interfacePrefix: configuration.networkInterfacePrefix)
    }

    deinit {
        pressureWatchTask?.cancel()
    }

    /// Takes one reading right now, independent of `snapshots()`'s loop. Also what
    /// `snapshots()` calls internally on every tick.
    @discardableResult
    public func sampleOnce() -> SystemSnapshot {
        startPressureMonitoringIfNeeded()

        return SystemSnapshot(
            timestamp: Date(),
            memory: MemoryStatsReader.read() ?? .unavailable,
            memoryPressure: latestPressure,
            cpu: cpuSampler.sample(),
            disks: refreshedDiskStatsIfNeeded(),
            network: networkSampler.sample(),
            topProcesses: ProcessStatsReader.topProcesses(limit: configuration.topProcessCount),
            battery: BatteryStatsReader.read()
        )
    }

    /// An `AsyncStream` of `SystemSnapshot`s, one per `configuration.interval`. Each call starts
    /// its own independent sampling loop (stopped by cancelling the consuming task, which tears
    /// down the stream via `onTermination`); the underlying readers are cheap enough that this
    /// package does not need to fan a single loop out to multiple subscribers.
    public func snapshots() -> AsyncStream<SystemSnapshot> {
        let interval = configuration.interval
        return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let snapshot = await self.sampleOnce()
                    continuation.yield(snapshot)
                    do {
                        try await Task.sleep(for: interval)
                    } catch {
                        return
                    }
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Memory pressure is event-driven (`DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`), not polled, so
    /// it needs exactly one long-lived watcher regardless of how many times `sampleOnce()` is
    /// called. Started lazily on first use and cancelled in `deinit`.
    private func startPressureMonitoringIfNeeded() {
        guard pressureWatchTask == nil else { return }
        pressureWatchTask = Task { [weak self] in
            for await level in MemoryPressureMonitor.stream() {
                guard let self else { return }
                await self.updatePressure(level)
            }
        }
    }

    private func updatePressure(_ level: MemoryPressureLevel) {
        latestPressure = level
    }

    /// Returns the cached disk reading unless `diskRefreshInterval` has elapsed (or this is the
    /// first sample), in which case it re-reads and re-caches. See `Configuration.diskRefreshInterval`.
    private func refreshedDiskStatsIfNeeded() -> [DiskStats] {
        let now = ContinuousClock.now
        if let lastDiskRefresh, now - lastDiskRefresh < configuration.diskRefreshInterval, !cachedDisks.isEmpty {
            return cachedDisks
        }
        let disks = DiskStatsReader.readAll()
        cachedDisks = disks
        lastDiskRefresh = now
        return disks
    }
}
