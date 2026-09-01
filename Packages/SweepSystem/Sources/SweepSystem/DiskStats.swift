import Darwin
import Foundation

/// Per-volume disk usage, in bytes.
public struct DiskStats: Sendable, Equatable, Codable {
    public let volumeURL: URL
    public let volumeName: String
    /// Total capacity of the volume.
    public let totalBytes: UInt64
    /// Space available for ordinary use (`volumeAvailableCapacityKey`).
    public let availableBytes: UInt64
    /// Space available including space the system could reclaim from purgeable data if asked
    /// (`volumeAvailableCapacityForImportantUsageKey`).
    public let availableForImportantUsageBytes: UInt64
    /// `availableForImportantUsageBytes - availableBytes`, clamped at zero: an ESTIMATE of
    /// purgeable space, per PLAN.md Appendix B ("Purgeable space ... estimate via
    /// volumeAvailableCapacityForImportantUsageKey vs volumeAvailableCapacityKey"). Actual
    /// reclaim is the OS's job and this accounting is documented as unreliable — never present
    /// this as an exact, freeable number.
    public let purgeableEstimateBytes: UInt64
    public let isRemovable: Bool
    public let isInternal: Bool

    public init(
        volumeURL: URL,
        volumeName: String,
        totalBytes: UInt64,
        availableBytes: UInt64,
        availableForImportantUsageBytes: UInt64,
        purgeableEstimateBytes: UInt64,
        isRemovable: Bool,
        isInternal: Bool
    ) {
        self.volumeURL = volumeURL
        self.volumeName = volumeName
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
        self.availableForImportantUsageBytes = availableForImportantUsageBytes
        self.purgeableEstimateBytes = purgeableEstimateBytes
        self.isRemovable = isRemovable
        self.isInternal = isInternal
    }
}

/// Reads per-volume disk usage via `URLResourceKey` volume keys (primary source) with a
/// `statfs` cross-check available for callers that need the raw block-level numbers.
public enum DiskStatsReader {
    private static let resourceKeys: [URLResourceKey] = [
        .volumeNameKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
        .volumeIsRemovableKey,
        .volumeIsInternalKey,
    ]

    /// Every locally mounted, non-hidden volume (Finder-visible: local disks, external drives,
    /// mounted disk images — matches what `diskutil list` / Finder's sidebar would show).
    public static func readAll() -> [DiskStats] {
        let volumeURLs = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: resourceKeys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return volumeURLs.compactMap(read(volumeURL:))
    }

    /// Reads stats for one specific volume (or any path on it — resource values resolve to the
    /// containing volume).
    public static func read(volumeURL: URL) -> DiskStats? {
        guard let values = try? volumeURL.resourceValues(forKeys: Set(resourceKeys)) else {
            return nil
        }
        guard
            let total = values.volumeTotalCapacity,
            let available = values.volumeAvailableCapacity
        else {
            return nil
        }
        let availableForImportantUsage = values.volumeAvailableCapacityForImportantUsage ?? Int64(available)

        let totalBytes = UInt64(max(0, total))
        let availableBytes = UInt64(max(0, available))
        let availableForImportantUsageBytes = UInt64(max(0, availableForImportantUsage))

        return DiskStats(
            volumeURL: volumeURL,
            volumeName: values.volumeName ?? volumeURL.lastPathComponent,
            totalBytes: totalBytes,
            availableBytes: availableBytes,
            availableForImportantUsageBytes: availableForImportantUsageBytes,
            purgeableEstimateBytes: purgeableEstimate(
                availableBytes: availableBytes,
                availableForImportantUsageBytes: availableForImportantUsageBytes
            ),
            isRemovable: values.volumeIsRemovable ?? false,
            isInternal: values.volumeIsInternal ?? true
        )
    }

    /// Pure function: `estimate = max(0, importantUsage - available)`. Separated out so the
    /// estimate's arithmetic is unit-testable without mounting real volumes.
    static func purgeableEstimate(availableBytes: UInt64, availableForImportantUsageBytes: UInt64) -> UInt64 {
        availableForImportantUsageBytes > availableBytes ? availableForImportantUsageBytes - availableBytes : 0
    }

    /// Small audited wrapper around raw `statfs` for callers that want the block-level numbers
    /// directly rather than the higher-level `URLResourceKey` values (e.g. as a cross-check).
    /// Not used by `readAll()`/`read(volumeURL:)` above; kept because PLAN.md Appendix B calls
    /// out `statfs` explicitly alongside the resource keys.
    public static func readRawStatfs(path: String) -> statfs? {
        var buffer = statfs()
        guard path.withCString({ statfs($0, &buffer) }) == 0 else { return nil }
        return buffer
    }
}
