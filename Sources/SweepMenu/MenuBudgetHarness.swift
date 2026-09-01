import AppKit
import Darwin
import Foundation

/// SweepMenu idle-memory budget harness (PLAN §3 module 7 / P4-B measurement). This target exists
/// because the in-app menubar measured 92.6 MB idle against a 50 MB budget, with the floor traced
/// to SwiftUI window/Scene machinery the main app needs for its real window (see PLAN.md §3
/// module 7 and `Sources/SweepApp/Shell/MenuBarStats.swift`'s own `MenuBarBudgetHarness`). This is
/// that same measurement, taken against the process that carries none of that machinery.
///
/// Inert unless `SWEEP_MENU_BUDGET` is set. Samples every 2 s across a 60 s idle window (30
/// samples) rather than one reading at the end: this process has no scan/UI activity to quiesce
/// first the way the in-app harness closes every window before it starts timing, so a summary
/// across the whole window is the more honest number — a slow climb shows up as a climb, not a
/// single possibly-lucky reading.
///
///   SWEEP_MENU_BUDGET=1        sample every 2 s for 60 s, print one summary line
///   SWEEP_MENU_BUDGET_EXIT=1   quit once that line has printed
enum MenuBudgetHarness {
    static func runIfRequested() {
        guard ProcessInfo.processInfo.environment["SWEEP_MENU_BUDGET"] != nil else { return }
        Task { @MainActor in
            var samplesMB: [Double] = []
            for _ in 0..<30 {
                try? await Task.sleep(for: .seconds(2))
                samplesMB.append(Double(residentBytes()) / 1_048_576)
            }
            // Same manual allocator relief `MenuBarBudgetHarness` applies before its own reading —
            // asks the allocator to return free pages to the OS in case idle heap fragmentation is
            // inflating RSS beyond what is actually live. Harmless whether or not it moves the
            // final sample.
            malloc_zone_pressure_relief(nil, 0)
            let finalMB = Double(residentBytes()) / 1_048_576
            print(String(
                format: "SWEEP_MENU_BUDGET rss_mb_final=%.1f rss_mb_min=%.1f rss_mb_max=%.1f rss_mb_mean=%.1f samples=%d",
                finalMB,
                samplesMB.min() ?? finalMB,
                samplesMB.max() ?? finalMB,
                samplesMB.isEmpty ? finalMB : samplesMB.reduce(0, +) / Double(samplesMB.count),
                samplesMB.count
            ))
            if ProcessInfo.processInfo.environment["SWEEP_MENU_BUDGET_EXIT"] == "1" {
                NSApp.terminate(nil)
            }
        }
    }

    /// Same `mach_task_basic_info` read `MenuBarBudgetHarness.residentBytes()` and
    /// `SnapshotHarness.residentBytes()` (both in the `SweepApp` target) use — duplicated across
    /// all three rather than shared, for the same reason those two already duplicate it between
    /// themselves: each is file-local in a different target, and this is a ~10-line Darwin syscall
    /// wrapper, not a shared abstraction worth a cross-target dependency for.
    private static func residentBytes() -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? info.resident_size : 0
    }
}
