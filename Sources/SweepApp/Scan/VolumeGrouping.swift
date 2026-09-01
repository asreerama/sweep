import Foundation
import SweepUI

/// Groups clean-candidate items by the volume their path resolves to, for the Clean confirm
/// sheet's volume list.
///
/// `InventoryItem.id` is the item's full absolute path (`ScanService` builds ids from
/// `node.path`), so resolving a volume per item is one `URLResourceValues` read — cheap at the
/// scale a confirm sheet ever shows (a selection, never an unfiltered scan of hundreds of
/// thousands of candidates).
enum VolumeGrouping {
    static func volumes(for items: [InventoryItem]) -> [CleanVolume] {
        struct Bucket { var name: String; var count = 0; var bytes: Int64 = 0 }
        var buckets: [String: Bucket] = [:]
        var order: [String] = []

        for item in items {
            let name = volumeName(for: URL(fileURLWithPath: item.id))
            if buckets[name] == nil {
                buckets[name] = Bucket(name: name)
                order.append(name)
            }
            buckets[name]?.count += 1
            buckets[name]?.bytes += item.byteCount
        }

        return order
            .compactMap { key -> CleanVolume? in
                guard let bucket = buckets[key] else { return nil }
                return CleanVolume(id: key, name: bucket.name, itemCount: bucket.count, byteCount: bucket.bytes)
            }
            .sorted { $0.byteCount > $1.byteCount }
    }

    private static func volumeName(for url: URL) -> String {
        if let values = try? url.resourceValues(forKeys: [.volumeNameKey]), let name = values.volumeName {
            return name
        }
        if let rootName = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeNameKey]).volumeName {
            return rootName
        }
        return "This Mac"
    }
}
