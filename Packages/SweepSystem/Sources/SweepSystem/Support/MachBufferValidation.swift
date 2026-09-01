import Darwin

/// Pure, dependency-free validation for Mach `host_*_info` out-array element counts — kept
/// separate from any Darwin call so bad-count scenarios are unit-testable without needing to
/// fake a kernel response.
///
/// See finding #15 in the adversarial review: `CPUStats.swift` indexed `processorCount` typed
/// records out of the `host_processor_info` out-array without verifying that the kernel-reported
/// `cpuInfoCount` actually covers `processorCount * PROCESSOR_CPU_LOAD_INFO_COUNT` elements, and
/// `MemoryStats.swift` read every field of a `host_statistics64` result without verifying the
/// returned count met what `vm_statistics64_data_t` needs — an inconsistent (or short) kernel
/// response would otherwise be trusted before ever being rebound to a typed record and indexed.
enum MachBufferValidation {
    /// `true` only when `reportedCount` exactly equals `elementCount * perElementCount`, computed
    /// with overflow checking. Used where the kernel's contract is a fixed-size record repeated
    /// `elementCount` times (e.g. `PROCESSOR_CPU_LOAD_INFO_COUNT` integers per processor) — an
    /// inconsistent response (or a wrapped multiplication) must never be treated as valid.
    static func exactCountMatches(reported reportedCount: mach_msg_type_number_t, elementCount: Int, perElementCount: Int) -> Bool {
        guard elementCount >= 0, perElementCount >= 0 else { return false }
        let (product, overflow) = elementCount.multipliedReportingOverflow(by: perElementCount)
        guard !overflow, let expected = mach_msg_type_number_t(exactly: product) else { return false }
        return reportedCount == expected
    }

    /// `true` when `reportedCount` is at least `neededCount`. Used where the kernel is allowed to
    /// report a struct at least as large as what this reader decodes (`host_statistics64`'s count
    /// is a versioned struct size, not a fixed record count), so exact equality would be too
    /// strict — but a SHORT response must still never be trusted.
    static func atLeast(reported reportedCount: mach_msg_type_number_t, needed neededCount: Int) -> Bool {
        guard neededCount >= 0, let needed = mach_msg_type_number_t(exactly: neededCount) else { return false }
        return reportedCount >= needed
    }
}
