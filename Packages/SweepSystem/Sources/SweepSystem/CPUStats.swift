import Darwin

/// CPU tick counters for one core (or the whole host, when only an aggregate is needed).
/// `natural_t` (`UInt32`) counters as reported by `PROCESSOR_CPU_LOAD_INFO`; they accumulate
/// since boot and can in principle wrap after long uptimes, which `CPUMath` accounts for.
struct CPUTicks: Sendable, Equatable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// Per-core CPU utilization, as a percentage of the interval between two samples.
public struct CPUCoreLoad: Sendable, Equatable, Codable {
    public let coreIndex: Int
    public let userPercent: Double
    public let systemPercent: Double
    public let idlePercent: Double

    public init(coreIndex: Int, userPercent: Double, systemPercent: Double, idlePercent: Double) {
        self.coreIndex = coreIndex
        self.userPercent = userPercent
        self.systemPercent = systemPercent
        self.idlePercent = idlePercent
    }
}

/// CPU utilization across every core, plus a host-wide aggregate.
public struct CPUStats: Sendable, Equatable, Codable {
    public let perCore: [CPUCoreLoad]
    public let aggregateUserPercent: Double
    public let aggregateSystemPercent: Double
    public let aggregateIdlePercent: Double

    public init(
        perCore: [CPUCoreLoad],
        aggregateUserPercent: Double,
        aggregateSystemPercent: Double,
        aggregateIdlePercent: Double
    ) {
        self.perCore = perCore
        self.aggregateUserPercent = aggregateUserPercent
        self.aggregateSystemPercent = aggregateSystemPercent
        self.aggregateIdlePercent = aggregateIdlePercent
    }

    /// Reported when there is not yet a prior sample to diff against (e.g. the very first tick
    /// of a `StatsSampler` loop). Not an error state.
    public static let unavailable = CPUStats(
        perCore: [], aggregateUserPercent: 0, aggregateSystemPercent: 0, aggregateIdlePercent: 0
    )
}

/// Pure, dependency-free CPU math: tick deltas (with wraparound) and delta-to-percentage
/// conversion. Kept separate from any Darwin call so it can be exercised with fixed inputs.
enum CPUMath {
    /// Unsigned wraparound-safe delta for a monotonically increasing 32-bit tick counter.
    /// `natural_t` ticks wrap at `UInt32.max`; on a very long-uptime host this is reachable
    /// (~13 months at 100 Hz), so plain subtraction is not safe.
    static func wrappingDelta(current: UInt32, previous: UInt32) -> UInt32 {
        current &- previous
    }

    /// Converts a pair of tick samples into user/system/idle percentages of the interval
    /// between them. Returns `nil` when the two samples are identical (zero elapsed ticks),
    /// which would otherwise divide by zero.
    static func percentages(previous: CPUTicks, current: CPUTicks) -> (user: Double, system: Double, idle: Double)? {
        let userDelta = wrappingDelta(current: current.user, previous: previous.user)
        let systemDelta = wrappingDelta(current: current.system, previous: previous.system)
        let idleDelta = wrappingDelta(current: current.idle, previous: previous.idle)
        let niceDelta = wrappingDelta(current: current.nice, previous: previous.nice)

        let total = UInt64(userDelta) + UInt64(systemDelta) + UInt64(idleDelta) + UInt64(niceDelta)
        guard total > 0 else { return nil }

        let totalD = Double(total)
        return (
            user: Double(userDelta) / totalD * 100,
            system: Double(systemDelta) / totalD * 100,
            idle: Double(idleDelta) / totalD * 100
        )
    }
}

/// Stateful CPU sampler: `host_processor_info(PROCESSOR_CPU_LOAD_INFO)` reports cumulative tick
/// counters, so utilization requires the delta between two samples. This type owns that
/// previous-sample state; call `sample()` on a fixed cadence.
///
/// A plain (non-actor) value type by design: `StatsSampler` owns one instance and calls it only
/// from its own actor-isolated context, so there is no concurrent access to guard against, and
/// no cross-actor hop cost on every tick.
public struct CPUStatsSampler: Sendable {
    private var previousTicks: [CPUTicks]?

    public init() {}

    /// Takes a fresh reading and returns the utilization since the previous call. The first
    /// call after `init` (or after a core count change, e.g. hot-plugged eGPU-adjacent core
    /// reporting — not expected on Apple Silicon but guarded anyway) has no prior sample to
    /// diff against and returns `CPUStats.unavailable`.
    public mutating func sample() -> CPUStats {
        guard let currentTicks = Self.readProcessorTicks() else { return .unavailable }
        defer { previousTicks = currentTicks }

        guard let previousTicks, previousTicks.count == currentTicks.count else {
            return .unavailable
        }

        var perCore: [CPUCoreLoad] = []
        perCore.reserveCapacity(currentTicks.count)
        var totalUser: UInt64 = 0, totalSystem: UInt64 = 0, totalIdle: UInt64 = 0, totalNice: UInt64 = 0

        for (index, current) in currentTicks.enumerated() {
            let previous = previousTicks[index]
            if let pct = CPUMath.percentages(previous: previous, current: current) {
                perCore.append(CPUCoreLoad(coreIndex: index, userPercent: pct.user, systemPercent: pct.system, idlePercent: pct.idle))
            } else {
                perCore.append(CPUCoreLoad(coreIndex: index, userPercent: 0, systemPercent: 0, idlePercent: 100))
            }
            totalUser += UInt64(CPUMath.wrappingDelta(current: current.user, previous: previous.user))
            totalSystem += UInt64(CPUMath.wrappingDelta(current: current.system, previous: previous.system))
            totalIdle += UInt64(CPUMath.wrappingDelta(current: current.idle, previous: previous.idle))
            totalNice += UInt64(CPUMath.wrappingDelta(current: current.nice, previous: previous.nice))
        }

        let totalTicks = totalUser + totalSystem + totalIdle + totalNice
        guard totalTicks > 0 else { return .unavailable }
        let totalD = Double(totalTicks)

        return CPUStats(
            perCore: perCore,
            aggregateUserPercent: Double(totalUser) / totalD * 100,
            aggregateSystemPercent: Double(totalSystem) / totalD * 100,
            aggregateIdlePercent: Double(totalIdle) / totalD * 100
        )
    }

    /// Small audited wrapper around `host_processor_info`: rebinds the mach out-array to
    /// `processor_cpu_load_info_data_t`, copies it into a Swift array immediately, and
    /// `vm_deallocate`s the kernel-owned out-of-line memory before returning — the array must
    /// not be allowed to leak the raw pointer past this function.
    private static func readProcessorTicks() -> [CPUTicks]? {
        var processorCount: natural_t = 0
        var cpuInfo: processor_info_array_t?
        var cpuInfoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &cpuInfo,
            &cpuInfoCount
        )
        guard result == KERN_SUCCESS, let cpuInfo else { return nil }
        defer {
            let size = vm_size_t(cpuInfoCount) * vm_size_t(MemoryLayout<integer_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(UInt(bitPattern: cpuInfo)), size)
        }

        let loadInfo = cpuInfo.withMemoryRebound(to: processor_cpu_load_info_data_t.self, capacity: Int(processorCount)) { $0 }
        var ticks: [CPUTicks] = []
        ticks.reserveCapacity(Int(processorCount))
        for i in 0..<Int(processorCount) {
            let load = loadInfo[i]
            let t = load.cpu_ticks
            ticks.append(CPUTicks(
                user: UInt32(t.0),
                system: UInt32(t.1),
                idle: UInt32(t.2),
                nice: UInt32(t.3)
            ))
        }
        return ticks
    }
}
