import Foundation

/// Shared authorization policy used identically by the app and the privileged helper.
/// Deny-by-default: an operation may only touch paths under an allowlisted symbolic root,
/// and never anything matching the protected set — checked on resolved file identity,
/// not lexical paths.
public enum SweepPolicy {

    /// Symbolic roots an operation may be scoped to. The helper derives real paths from
    /// these (plus a validated UID / bundle id); it never accepts caller-selected
    /// absolute paths.
    public enum OperationRoot: String, Codable, CaseIterable, Sendable {
        case userCaches
        case userLogs
        case sandboxedAppCaches
        case xcodeDerivedData
        case xcodeDeviceSupport
        case developerToolCaches
        case homebrewCache
        case browserCaches
        case crashReports
        case trash
        case systemCaches      // helper-only
        case systemLogs        // helper-only
    }

    /// Grounds no operation may ever touch, regardless of tier or root.
    public enum ProtectedArea: CaseIterable, Sendable {
        case documents
        case desktop
        case pictures
        case iCloudDrive
        case cloudStorage      // ~/Library/CloudStorage + File Provider domains
        case photosLibrary
        case mailStore         // ~/Library/Mail/V*
        case sweepItself
        case systemApps
    }

    /// Resolved, identity-pinned location of a protected area for the current user.
    public static func protectedURLs(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ProtectedArea: [URL]] {
        [
            .documents: [home.appending(path: "Documents")],
            .desktop: [home.appending(path: "Desktop")],
            .pictures: [home.appending(path: "Pictures")],
            .iCloudDrive: [home.appending(path: "Library/Mobile Documents")],
            .cloudStorage: [home.appending(path: "Library/CloudStorage")],
            .photosLibrary: [home.appending(path: "Pictures/Photos Library.photoslibrary")],
            .mailStore: [home.appending(path: "Library/Mail")],
            .sweepItself: [],
            .systemApps: [URL(fileURLWithPath: "/System/Applications")],
        ]
    }

    /// Placeholder decision API; P2 replaces the body with identity-resolved checks
    /// (device/inode, symlink-free descent). The signature is the frozen contract.
    public static func isDeniedLexically(_ url: URL) -> Bool {
        let standardized = url.standardizedFileURL.path
        for urls in protectedURLs().values {
            for p in urls where !p.path.isEmpty {
                if standardized == p.path || standardized.hasPrefix(p.path + "/") { return true }
            }
        }
        return false
    }
}
