import Darwin

/// Bytes transferred since the previous sample, for one network interface.
public struct NetworkInterfaceStats: Sendable, Equatable, Codable {
    public let name: String
    public let bytesReceivedDelta: UInt64
    public let bytesSentDelta: UInt64

    public init(name: String, bytesReceivedDelta: UInt64, bytesSentDelta: UInt64) {
        self.name = name
        self.bytesReceivedDelta = bytesReceivedDelta
        self.bytesSentDelta = bytesSentDelta
    }
}

/// Network throughput since the previous sample, aggregated across every `en*` interface plus
/// the per-interface breakdown it was computed from.
public struct NetworkStats: Sendable, Equatable, Codable {
    public let interfaces: [NetworkInterfaceStats]
    public let totalBytesReceivedDelta: UInt64
    public let totalBytesSentDelta: UInt64

    public init(interfaces: [NetworkInterfaceStats], totalBytesReceivedDelta: UInt64, totalBytesSentDelta: UInt64) {
        self.interfaces = interfaces
        self.totalBytesReceivedDelta = totalBytesReceivedDelta
        self.totalBytesSentDelta = totalBytesSentDelta
    }

    public static let unavailable = NetworkStats(interfaces: [], totalBytesReceivedDelta: 0, totalBytesSentDelta: 0)
}

/// Pure counter-delta math, isolated from `getifaddrs` so it can be exercised with fixed,
/// mocked inputs (no real interface needed to test wraparound).
enum NetworkByteCounter {
    /// The 4 GB (2^32) boundary PLAN.md calls out explicitly: some link-layer counters still
    /// report through the legacy 32-bit `if_data` fields and wrap there even though the struct
    /// widened the field to 64 bits.
    static let wrapBoundary: UInt64 = UInt64(UInt32.max) + 1

    /// Delta between two monotonically increasing byte counters.
    ///
    /// - When `current >= previous`: plain subtraction.
    /// - When `current < previous` and `previous` was within a quarter of the 32-bit boundary:
    ///   treated as a wraparound, computed with unsigned wraparound arithmetic.
    /// - When `current < previous` far from the boundary: treated as a counter reset (interface
    ///   went down/up, driver reload) rather than a wrap, and the new value is reported as the
    ///   delta rather than a nonsensical near-4-GB spike.
    ///
    /// Always returns a non-negative delta.
    static func delta(current: UInt64, previous: UInt64) -> UInt64 {
        if current >= previous {
            return current - previous
        }
        let distanceToWrap = wrapBoundary - previous
        if distanceToWrap <= wrapBoundary / 4 {
            return distanceToWrap + current
        }
        return current
    }
}

/// Stateful network sampler: `getifaddrs` reports cumulative byte counters, so throughput
/// requires the delta between two samples. Owns the previous-sample state; call `sample()` on a
/// fixed cadence.
///
/// A plain (non-actor) value type for the same reason as `CPUStatsSampler`: `StatsSampler` is
/// its only caller and already serializes access.
public struct NetworkStatsSampler: Sendable {
    /// Only interfaces whose name starts with this prefix are aggregated (PLAN.md: "aggregate
    /// across en* interfaces") — Wi-Fi and Ethernet on every Mac model enumerate as `en0`,
    /// `en1`, etc. Loopback, tunnel, and Bluetooth PAN interfaces are excluded.
    private let interfacePrefix: String
    private var previousCounters: [String: (received: UInt64, sent: UInt64)] = [:]

    public init(interfacePrefix: String = "en") {
        self.interfacePrefix = interfacePrefix
    }

    public mutating func sample() -> NetworkStats {
        let currentCounters = Self.readInterfaceCounters(matchingPrefix: interfacePrefix)
        defer { previousCounters = currentCounters }

        var interfaces: [NetworkInterfaceStats] = []
        interfaces.reserveCapacity(currentCounters.count)
        var totalReceived: UInt64 = 0
        var totalSent: UInt64 = 0

        for (name, current) in currentCounters.sorted(by: { $0.key < $1.key }) {
            guard let previous = previousCounters[name] else {
                // New interface (e.g. Wi-Fi just associated) — no baseline yet this tick.
                interfaces.append(NetworkInterfaceStats(name: name, bytesReceivedDelta: 0, bytesSentDelta: 0))
                continue
            }
            let receivedDelta = NetworkByteCounter.delta(current: current.received, previous: previous.received)
            let sentDelta = NetworkByteCounter.delta(current: current.sent, previous: previous.sent)
            interfaces.append(NetworkInterfaceStats(name: name, bytesReceivedDelta: receivedDelta, bytesSentDelta: sentDelta))
            totalReceived += receivedDelta
            totalSent += sentDelta
        }

        return NetworkStats(interfaces: interfaces, totalBytesReceivedDelta: totalReceived, totalBytesSentDelta: totalSent)
    }

    /// Small audited wrapper around `getifaddrs`: walks the linked list once, keeps only
    /// `AF_LINK` entries (the link-layer record carries the byte counters; the same interface
    /// name also appears with `AF_INET`/`AF_INET6` entries we skip), and frees the list before
    /// returning — no `ifaddrs` pointer escapes this function.
    private static func readInterfaceCounters(matchingPrefix prefix: String) -> [String: (received: UInt64, sent: UInt64)] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return [:] }
        defer { freeifaddrs(head) }

        var counters: [String: (received: UInt64, sent: UInt64)] = [:]
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }

            let name = String(cString: entry.pointee.ifa_name)
            guard name.hasPrefix(prefix) else { continue }
            guard let sockaddr = entry.pointee.ifa_addr, sockaddr.pointee.sa_family == UInt8(AF_LINK) else { continue }
            guard let dataPointer = entry.pointee.ifa_data else { continue }

            let ifData = dataPointer.withMemoryRebound(to: if_data.self, capacity: 1) { $0.pointee }
            counters[name] = (received: UInt64(ifData.ifi_ibytes), sent: UInt64(ifData.ifi_obytes))
        }
        return counters
    }
}
