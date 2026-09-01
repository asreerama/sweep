import Foundation

/// Pure validation rules for ``MaintenanceOperation``, deliberately separate from decoding: a
/// `MaintenanceOperation` can decode successfully (it is well-shaped JSON) and still name a volume
/// that is not mounted or an urgency outside range. Every function here takes its "ground truth"
/// (the mounted-volume list) as a parameter rather than reading the filesystem itself, so it is
/// unit-testable without touching disk and, more importantly, so the *caller* — always the
/// helper, running as root — is the one required to source that ground truth from a real system
/// API immediately before validating, never from anything the XPC client asserted.
public enum MaintenanceValidation {
    public enum ValidationError: Error, Sendable, Equatable, CustomStringConvertible {
        case volumeNotMounted(String)
        case urgencyOutOfRange(Int)

        public var description: String {
            switch self {
            case .volumeNotMounted(let volume):
                "refused: \(volume) is not a currently mounted volume"
            case .urgencyOutOfRange(let urgency):
                "refused: urgency \(urgency) is outside \(MaintenanceValidation.urgencyRange)"
            }
        }
    }

    /// Matches `tmutil`'s own documented urgency range (`man tmutil`: "urgency level 1-4").
    public static let urgencyRange: ClosedRange<Int> = 1...4

    /// `nil` on success, matching the "decide once, report once" shape every caller here wants —
    /// `Result<Void, _>` was considered and dropped: `Void` is not `Equatable`, which would have
    /// made every test comparison awkward for no benefit.
    public static func validateVolume(_ volume: String, mountedVolumes: [String]) -> ValidationError? {
        mountedVolumes.contains(volume) ? nil : .volumeNotMounted(volume)
    }

    public static func validateUrgency(_ urgency: Int) -> ValidationError? {
        urgencyRange.contains(urgency) ? nil : .urgencyOutOfRange(urgency)
    }

    /// The one call site the helper actually uses: dispatches to the rule (if any) that applies to
    /// `operation`. `flushDNS` carries no caller-supplied data, so it has nothing to validate.
    public static func validate(_ operation: MaintenanceOperation, mountedVolumes: [String]) -> ValidationError? {
        switch operation {
        case .flushDNS:
            return nil
        case .reindexSpotlight(let volume):
            return validateVolume(volume, mountedVolumes: mountedVolumes)
        case .thinSnapshots(let urgency):
            return validateUrgency(urgency)
        }
    }
}
