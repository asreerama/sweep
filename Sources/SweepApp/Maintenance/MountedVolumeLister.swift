import Foundation

/// One mounted volume, for the Rebuild Spotlight Index card's picker. The helper independently
/// re-derives and validates this same list at execution time (`MaintenanceValidation`) — this is
/// display-only convenience, never trusted as authorization.
struct MaintenanceVolumeOption: Identifiable, Equatable {
    let id: String
    let displayName: String
}

enum MountedVolumeLister {
    static func current(fileManager: FileManager = .default) -> [MaintenanceVolumeOption] {
        let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: [.volumeNameKey],
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls
            .map { url in
                let name = (try? url.resourceValues(forKeys: [.volumeNameKey]))?.volumeName ?? url.lastPathComponent
                return MaintenanceVolumeOption(id: url.path, displayName: name.isEmpty ? url.path : name)
            }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}
