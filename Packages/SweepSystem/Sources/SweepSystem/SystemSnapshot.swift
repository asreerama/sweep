import Foundation

/// One point-in-time reading of every stat `SweepSystem` exposes — the payload `StatsSampler`
/// publishes to the menubar (PLAN.md §3/§7).
public struct SystemSnapshot: Sendable, Equatable {
    public let timestamp: Date
    public let memory: MemoryStats
    public let memoryPressure: MemoryPressureLevel
    public let cpu: CPUStats
    public let disks: [DiskStats]
    public let network: NetworkStats
    /// Top-N processes by physical memory footprint, per `StatsSampler.Configuration.topProcessCount`.
    public let topProcesses: [ProcessMemoryInfo]
    /// `nil` on any Mac with no battery (desktop models) — see `BatteryStatsReader.read()`.
    public let battery: BatteryStats?

    public init(
        timestamp: Date,
        memory: MemoryStats,
        memoryPressure: MemoryPressureLevel,
        cpu: CPUStats,
        disks: [DiskStats],
        network: NetworkStats,
        topProcesses: [ProcessMemoryInfo],
        battery: BatteryStats?
    ) {
        self.timestamp = timestamp
        self.memory = memory
        self.memoryPressure = memoryPressure
        self.cpu = cpu
        self.disks = disks
        self.network = network
        self.topProcesses = topProcesses
        self.battery = battery
    }
}
