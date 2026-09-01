import IOKit.ps

/// Which power source the Mac is currently drawing from.
public enum PowerSourceKind: String, Sendable, Equatable, Codable {
    case acPower
    case batteryPower
    case unknown
}

/// A snapshot of the primary power source, read via `IOPSCopyPowerSourcesInfo`.
public struct BatteryStats: Sendable, Equatable, Codable {
    /// 0...100.
    public let percentage: Int
    public let isCharging: Bool
    public let isPresent: Bool
    public let powerSource: PowerSourceKind
    /// Minutes until empty, when on battery and the estimate is known. `nil` while charging, at
    /// 100%, or while the OS has not yet produced a stable estimate (common in the first minute
    /// after unplugging).
    public let timeToEmptyMinutes: Int?
    /// Minutes until fully charged, when charging and the estimate is known.
    public let timeToFullChargeMinutes: Int?
    /// Cycle count and health, from the `AppleSmartBattery` IORegistry entry.
    ///
    /// TODO(PLAN.md Appendix B): deferred. Marked optional/flaky per PLAN.md's explicit call-out
    /// — cycle count/health reporting varies across Apple Silicon generations and battery
    /// firmware, and `IOPMCopyBatteryInfo` (the legacy alternative) is explicitly disallowed.
    /// Always `nil` until a follow-up implements and validates the IORegistry read on real
    /// battery hardware (this development machine is a Mac mini with no battery).
    public let cycleCount: Int?

    public init(
        percentage: Int,
        isCharging: Bool,
        isPresent: Bool,
        powerSource: PowerSourceKind,
        timeToEmptyMinutes: Int?,
        timeToFullChargeMinutes: Int?,
        cycleCount: Int? = nil
    ) {
        self.percentage = percentage
        self.isCharging = isCharging
        self.isPresent = isPresent
        self.powerSource = powerSource
        self.timeToEmptyMinutes = timeToEmptyMinutes
        self.timeToFullChargeMinutes = timeToFullChargeMinutes
        self.cycleCount = cycleCount
    }
}

/// Reads the primary power source's status via `IOPSCopyPowerSourcesInfo` +
/// `IOPSGetPowerSourceDescription`.
public enum BatteryStatsReader {
    /// `nil` when there is no power source to report — the expected, correct result on any
    /// desktop Mac (Mac mini, Mac Studio, Mac Pro, iMac) with no internal or connected battery.
    /// Not an error: callers (e.g. the menubar) should simply omit the battery module rather
    /// than treat this as a failed read.
    public static func read() -> BatteryStats? {
        guard let description = primaryPowerSourceDescription() else { return nil }

        let currentCapacity = description[kIOPSCurrentCapacityKey as String] as? Int
        let maxCapacity = description[kIOPSMaxCapacityKey as String] as? Int
        let percentage = Self.percentage(current: currentCapacity, max: maxCapacity)

        let isCharging = description[kIOPSIsChargingKey as String] as? Bool ?? false
        let isPresent = description[kIOPSIsPresentKey as String] as? Bool ?? true
        let stateRaw = description[kIOPSPowerSourceStateKey as String] as? String
        let powerSource: PowerSourceKind = switch stateRaw {
        case kIOPSACPowerValue: .acPower
        case kIOPSBatteryPowerValue: .batteryPower
        default: .unknown
        }

        // IOKit reports -1 (kIOPSTimeRemainingUnknown as an Int) while the estimate isn't
        // available yet; only surface a value once it's meaningful.
        let timeToEmpty = (description[kIOPSTimeToEmptyKey as String] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        let timeToFull = (description[kIOPSTimeToFullChargeKey as String] as? Int).flatMap { $0 >= 0 ? $0 : nil }

        return BatteryStats(
            percentage: percentage,
            isCharging: isCharging,
            isPresent: isPresent,
            powerSource: powerSource,
            timeToEmptyMinutes: isCharging ? nil : timeToEmpty,
            timeToFullChargeMinutes: isCharging ? timeToFull : nil,
            cycleCount: nil // TODO: see BatteryStats.cycleCount doc comment.
        )
    }

    static func percentage(current: Int?, max: Int?) -> Int {
        guard let current, let max, max > 0 else { return 0 }
        let pct = Int((Double(current) / Double(max) * 100).rounded())
        return Swift.min(100, Swift.max(0, pct))
    }

    /// Small audited wrapper around the three-call IOKit dance: copy the power sources blob,
    /// list the sources in it, and describe the first one. A Mac with no battery legitimately
    /// returns an empty list here (confirmed on the Mac mini this package was built on) — that
    /// is not a failure path.
    private static func primaryPowerSourceDescription() -> [String: Any]? {
        guard let blob = IOPSCopyPowerSourcesInfo() else { return nil }
        let snapshot = blob.takeRetainedValue()
        guard let sourcesRef = IOPSCopyPowerSourcesList(snapshot) else { return nil }
        let sources = sourcesRef.takeRetainedValue() as [CFTypeRef]
        guard let firstSource = sources.first else { return nil }
        guard let descriptionRef = IOPSGetPowerSourceDescription(snapshot, firstSource) else { return nil }
        return descriptionRef.takeUnretainedValue() as? [String: Any]
    }
}
