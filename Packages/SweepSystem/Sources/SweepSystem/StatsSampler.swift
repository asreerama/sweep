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

    /// Every blocking Darwin/IOKit/FileManager call `sampleOnce()` needs — `host_processor_info`,
    /// `getifaddrs`, `host_statistics64`, the disk volumes' `URLResourceKey` reads, and
    /// `proc_listpids`/`proc_pid_rusage` over every process — is a synchronous syscall with no
    /// async variant. Running any of them directly inside an `actor` method blocks whichever
    /// cooperative-pool thread happens to be running this actor for as long as they take,
    /// starving every other actor/task sharing that pool. `sampleOnce()` instead bridges each one
    /// onto this dedicated serial queue via `withCheckedContinuation`, suspending the actor
    /// instead of occupying a pool thread; the actor itself only assembles the results into a
    /// `SystemSnapshot` and updates the stateful CPU/network samplers' baselines. One queue per
    /// `StatsSampler` instance (rather than `DispatchQueue.global()` per call) keeps this
    /// sampler's own blocking work serialized without spawning a new thread per tick, and without
    /// contending with other `StatsSampler` instances. See finding #16 in the adversarial review.
    private let blockingQueue = DispatchQueue(label: "com.sweep.system.statssampler.blocking", qos: .utility)

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
    public func sampleOnce() async -> SystemSnapshot {
        startPressureMonitoringIfNeeded()

        // Extracted before crossing onto `blockingQueue`: `configuration` itself is actor-isolated
        // state, but these two `Sendable` values are cheap to copy out here, on the actor, and
        // capture cleanly in the `@Sendable` closures below.
        let topProcessCount = configuration.topProcessCount
        let networkInterfacePrefix = configuration.networkInterfacePrefix

        let currentTicks = await runBlocking { CPUStatsSampler.readProcessorTicks() }
        let cpu = cpuSampler.update(withCurrentTicks: currentTicks)

        let currentNetworkCounters = await runBlocking { NetworkStatsSampler.readInterfaceCounters(matchingPrefix: networkInterfacePrefix) }
        let network = networkSampler.update(withCurrentCounters: currentNetworkCounters)

        let memory = await runBlocking { MemoryStatsReader.read() } ?? .unavailable
        let topProcesses = await runBlocking { ProcessStatsReader.topProcesses(limit: topProcessCount) }
        let battery = await runBlocking { BatteryStatsReader.read() }
        let disks = await refreshedDiskStatsIfNeeded()

        return SystemSnapshot(
            timestamp: Date(),
            memory: memory,
            memoryPressure: latestPressure,
            cpu: cpu,
            disks: disks,
            network: network,
            topProcesses: topProcesses,
            battery: battery
        )
    }

    /// Bridges one blocking Darwin/IOKit/FileManager call onto `blockingQueue`: the actor
    /// suspends here (freeing its cooperative-pool thread) instead of running the syscall inline.
    /// See `blockingQueue`'s doc comment above.
    private func runBlocking<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            blockingQueue.async {
                continuation.resume(returning: work())
            }
        }
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
    /// first sample), in which case it re-reads (off-actor, see `runBlocking`) and re-caches. See
    /// `Configuration.diskRefreshInterval`.
    private func refreshedDiskStatsIfNeeded() async -> [DiskStats] {
        let now = ContinuousClock.now
        if let lastDiskRefresh, now - lastDiskRefresh < configuration.diskRefreshInterval, !cachedDisks.isEmpty {
            return cachedDisks
        }
        let disks = await runBlocking { DiskStatsReader.readAll() }
        cachedDisks = disks
        lastDiskRefresh = now
        return disks
    }
}
