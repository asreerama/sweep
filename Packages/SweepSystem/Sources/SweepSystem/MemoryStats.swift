import Darwin
import Dispatch
import Foundation

/// A point-in-time breakdown of physical memory, in bytes.
///
/// Every field is derived from `host_statistics64(HOST_VM_INFO64)` page counts multiplied by
/// `SystemPageSize.bytes`, except `totalBytes` which comes from the host's reported physical
/// memory (page counts alone do not sum to the true total — see `MemoryStatsReader`).
public struct MemoryStats: Sendable, Equatable, Codable {
    /// Total physical memory installed, in bytes.
    public let totalBytes: UInt64
    /// Free (immediately reusable) memory.
    public let freeBytes: UInt64
    /// Active memory: recently used, not yet eligible for reclaim.
    public let activeBytes: UInt64
    /// Inactive memory: not recently used, reclaimable under pressure.
    public let inactiveBytes: UInt64
    /// Wired memory: cannot be paged out.
    public let wiredBytes: UInt64
    /// Memory held by the compressor (`compressor_page_count`).
    public let compressedBytes: UInt64
    /// Approximation of "App Memory": anonymous (`internal_page_count`) memory minus the
    /// portion of it that is purgeable (`purgeable_count`) and can be dropped for free under
    /// pressure. Per PLAN.md §3 this is explicitly an approximation, not Activity Monitor's
    /// exact (unpublished) formula.
    public let appMemoryBytes: UInt64
    /// Lifetime bytes swapped in via the compressor's swap segments.
    public let swapInsBytes: UInt64
    /// Lifetime bytes swapped out via the compressor's swap segments.
    public let swapOutsBytes: UInt64

    public init(
        totalBytes: UInt64,
        freeBytes: UInt64,
        activeBytes: UInt64,
        inactiveBytes: UInt64,
        wiredBytes: UInt64,
        compressedBytes: UInt64,
        appMemoryBytes: UInt64,
        swapInsBytes: UInt64,
        swapOutsBytes: UInt64
    ) {
        self.totalBytes = totalBytes
        self.freeBytes = freeBytes
        self.activeBytes = activeBytes
        self.inactiveBytes = inactiveBytes
        self.wiredBytes = wiredBytes
        self.compressedBytes = compressedBytes
        self.appMemoryBytes = appMemoryBytes
        self.swapInsBytes = swapInsBytes
        self.swapOutsBytes = swapOutsBytes
    }

    /// All-zero placeholder used only when the underlying kernel call fails, which should not
    /// happen on any supported macOS version.
    public static let unavailable = MemoryStats(
        totalBytes: 0, freeBytes: 0, activeBytes: 0, inactiveBytes: 0, wiredBytes: 0,
        compressedBytes: 0, appMemoryBytes: 0, swapInsBytes: 0, swapOutsBytes: 0
    )
}

/// Reads a `MemoryStats` snapshot from the kernel. Stateless: every call is an independent
/// `host_statistics64` round trip, so there is nothing to keep alive between samples.
public enum MemoryStatsReader {
    /// Returns `nil` only if the `host_statistics64` call itself fails (not expected on any
    /// supported macOS version).
    public static func read() -> MemoryStats? {
        guard let raw = readRawVMStatistics64() else { return nil }
        let pageSize = SystemPageSize.bytes

        let internalBytes = UInt64(raw.internal_page_count) * pageSize
        let purgeableBytes = UInt64(raw.purgeable_count) * pageSize
        // internal_page_count already includes purgeable pages; subtracting them approximates
        // the "real" app footprint that isn't free-for-the-taking under pressure.
        let appMemoryBytes = internalBytes > purgeableBytes ? internalBytes - purgeableBytes : 0

        return MemoryStats(
            totalBytes: ProcessInfo.processInfo.physicalMemory,
            freeBytes: UInt64(raw.free_count) * pageSize,
            activeBytes: UInt64(raw.active_count) * pageSize,
            inactiveBytes: UInt64(raw.inactive_count) * pageSize,
            wiredBytes: UInt64(raw.wire_count) * pageSize,
            compressedBytes: UInt64(raw.compressor_page_count) * pageSize,
            appMemoryBytes: appMemoryBytes,
            swapInsBytes: raw.swapins * pageSize,
            swapOutsBytes: raw.swapouts * pageSize
        )
    }

    /// Small audited wrapper around the one unsafe call in this file: binds the mach out-array
    /// to the typed `integer_t` layout `host_statistics64` expects, and validates the returned
    /// element count matches the struct we're decoding before touching any field.
    private static func readRawVMStatistics64() -> vm_statistics64_data_t? {
        var stats = vm_statistics64_data_t()
        let neededCount = MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(neededCount)
        let result = withUnsafeMutablePointer(to: &stats) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return nil }
        // `count` is updated in place by `host_statistics64` to the number of `integer_t`
        // elements actually written; verify it covers everything `vm_statistics64_data_t` needs
        // before trusting any field read from `stats` above — a short response would otherwise
        // leave trailing fields silently un-populated while this function still reported success.
        // See finding #15.
        guard MachBufferValidation.atLeast(reported: count, needed: neededCount) else { return nil }
        return stats
    }
}

/// System-reported memory pressure level, mirrored 1:1 from `DISPATCH_SOURCE_TYPE_MEMORYPRESSURE`.
public enum MemoryPressureLevel: String, Sendable, Equatable, Codable, CaseIterable {
    case normal
    case warning
    case critical
}

/// Publishes memory pressure level changes as reported by the kernel.
public enum MemoryPressureMonitor {
    /// An `AsyncStream` of memory pressure level changes. The stream never finishes on its own;
    /// cancel the consuming task (or let the stream's `Task` be torn down) to stop watching —
    /// `onTermination` cancels the underlying `DispatchSourceMemoryPressure`.
    ///
    /// Does not yield an initial value synchronously: the dispatch source's first event fires
    /// once its queue schedules it, which is normally near-instant but not guaranteed to happen
    /// before the first `for await` iteration. Callers that need a value immediately should
    /// default to `.normal` until the first event arrives.
    public static func stream() -> AsyncStream<MemoryPressureLevel> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let source = DispatchSource.makeMemoryPressureSource(
                eventMask: [.normal, .warning, .critical],
                queue: DispatchQueue(label: "com.sweep.system.memorypressure")
            )
            source.setEventHandler {
                continuation.yield(Self.level(from: source.data))
            }
            continuation.onTermination = { _ in
                source.cancel()
            }
            source.activate()
        }
    }

    /// Pure mapping from the dispatch source's event mask to our level enum. Kept separate from
    /// `stream()` so the decision logic (worst-first precedence) is unit-testable without a live
    /// `DispatchSource`.
    static func level(from data: DispatchSource.MemoryPressureEvent) -> MemoryPressureLevel {
        if data.contains(.critical) { return .critical }
        if data.contains(.warning) { return .warning }
        return .normal
    }
}
