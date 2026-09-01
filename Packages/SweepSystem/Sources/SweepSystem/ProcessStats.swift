import Darwin

/// Memory footprint of one running process, as reported by `proc_pid_rusage`.
public struct ProcessMemoryInfo: Sendable, Equatable, Codable, Identifiable {
    public var id: Int32 { pid }
    public let pid: Int32
    public let name: String
    /// `ri_phys_footprint`: Apple's "real" per-process memory metric (matches Activity Monitor's
    /// "Memory" column far more closely than resident set size).
    public let physicalFootprintBytes: UInt64

    public init(pid: Int32, name: String, physicalFootprintBytes: UInt64) {
        self.pid = pid
        self.name = name
        self.physicalFootprintBytes = physicalFootprintBytes
    }
}

/// Reads per-process memory footprint for every process visible to the current user, for the
/// "top memory consumers" list (PLAN.md §3).
public enum ProcessStatsReader {
    /// Returns up to `limit` processes, sorted by `physicalFootprintBytes` descending.
    ///
    /// Processes this user cannot query (`proc_pid_rusage` returns EPERM for another user's
    /// processes without elevated privileges) are silently skipped rather than surfaced as
    /// errors — that is expected, routine behavior, not a fault.
    public static func topProcesses(limit: Int = 10) -> [ProcessMemoryInfo] {
        topByFootprint(readAllProcesses(), limit: limit)
    }

    /// Pure sort/truncate step, separated out so it is unit-testable against fixture data
    /// without touching any Darwin API.
    static func topByFootprint(_ processes: [ProcessMemoryInfo], limit: Int) -> [ProcessMemoryInfo] {
        guard limit > 0 else { return [] }
        return Array(processes.sorted { $0.physicalFootprintBytes > $1.physicalFootprintBytes }.prefix(limit))
    }

    /// Small audited wrapper around `proc_listpids` + `proc_name` + `proc_pid_rusage`: lists
    /// every pid, resolves a display name, and reads the v4 rusage footprint for each, skipping
    /// (never crashing on) any pid that exits mid-enumeration or that this process cannot query.
    private static func readAllProcesses() -> [ProcessMemoryInfo] {
        let byteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard byteCount > 0 else { return [] }

        // Pad the buffer: the process list can grow between the sizing call above and the fetch
        // below, so ask for headroom rather than risk truncation.
        let capacity = Int(byteCount) / MemoryLayout<pid_t>.size + 64
        var pids = [pid_t](repeating: 0, count: capacity)
        let actualByteCount = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids, Int32(capacity * MemoryLayout<pid_t>.size))
        guard actualByteCount > 0 else { return [] }
        let pidCount = min(Int(actualByteCount) / MemoryLayout<pid_t>.size, pids.count)

        var results: [ProcessMemoryInfo] = []
        results.reserveCapacity(pidCount)

        for index in 0..<pidCount {
            let pid = pids[index]
            guard pid > 0 else { continue }
            guard let name = processName(for: pid) else { continue }
            guard let footprint = physicalFootprint(for: pid) else { continue }
            results.append(ProcessMemoryInfo(pid: pid, name: name, physicalFootprintBytes: footprint))
        }
        return results
    }

    private static func processName(for pid: pid_t) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(MAXPATHLEN))
        let length = buffer.withUnsafeMutableBufferPointer { rawBuffer -> Int32 in
            rawBuffer.baseAddress!.withMemoryRebound(to: CChar.self, capacity: rawBuffer.count) { cBuffer in
                proc_name(pid, cBuffer, UInt32(rawBuffer.count))
            }
        }
        guard length > 0 else { return nil }
        let nameBytes = buffer[..<Int(length)]
        return String(decoding: nameBytes, as: UTF8.self)
    }

    private static func physicalFootprint(for pid: pid_t) -> UInt64? {
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer -> Int32 in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return usage.ri_phys_footprint
    }
}
