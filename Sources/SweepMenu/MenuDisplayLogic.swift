import Foundation
import SweepSystem
import SweepUI
import SwiftUI

/// Pure logic behind `MenuPopoverView`: pressure tint/label mapping and the memory/disk readout
/// text and fractions. None of it touches `StatsSampler`, `NSStatusItem`, or drawing — every
/// function here is a plain value transform, which is what makes it unit-testable without a live
/// status item or a running sampler (`MenuDisplayLogicTests`).
///
/// Mirrors the small private mapping `Sources/SweepApp/Shell/MenuBarStats.swift` keeps for the
/// in-app menubar. Kept as an intentional duplication rather than a shared dependency: the two
/// executables must not depend on each other (`SweepMenu` depends only on `SweepSystem` +
/// `SweepUI`, never `SweepApp`), and neither package is the right home for a mapping this narrow
/// to a menubar popover's own presentation.
///
/// Byte formatting itself is never reimplemented here — every readout goes through
/// `SweepUI.SweepFormat.bytes` (decimal, disk) or `ByteCountFormatter(.memory)` (binary, RAM), the
/// same two call sites `MenuBarStats` uses. `MenuDisplayLogicTests`'s "reuse" tests assert the
/// output character-for-character against those same calls, so a future rewrite that reinvents
/// its own byte formatting here would fail loudly rather than silently drift.
enum MenuDisplayLogic {
    static func pressureTint(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: SweepTokens.accent
        case .warning: SweepTokens.tierCaution
        case .critical: SweepTokens.tierExpert
        }
    }

    static func pressureLabel(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: "NORMAL"
        case .warning: "WARNING"
        case .critical: "CRITICAL"
        }
    }

    static func memoryText(memory: MemoryStats) -> String {
        let used = memory.totalBytes - memory.freeBytes
        return "\(formattedMemory(used)) / \(formattedMemory(memory.totalBytes))"
    }

    static func memoryFraction(memory: MemoryStats) -> Double {
        guard memory.totalBytes > 0 else { return 0 }
        return Double(memory.totalBytes - memory.freeBytes) / Double(memory.totalBytes)
    }

    /// Memory is the one place decimal units would be wrong (`Formatting.swift`'s documented
    /// exception): RAM is sold and reported in binary multiples.
    static func formattedMemory(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    static func diskText(disk: DiskStats) -> String {
        let used = disk.totalBytes - disk.availableBytes
        return "\(SweepFormat.bytes(Int64(used))) / \(SweepFormat.bytes(Int64(disk.totalBytes)))"
    }

    static func diskFraction(disk: DiskStats) -> Double {
        guard disk.totalBytes > 0 else { return 0 }
        return Double(disk.totalBytes - disk.availableBytes) / Double(disk.totalBytes)
    }
}
