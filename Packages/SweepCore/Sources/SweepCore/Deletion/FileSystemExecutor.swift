import Darwin
import Foundation

/// The mutation surface, deliberately non-public and deliberately tiny: two verbs, no path
/// building, no recursion of its own. Everything above it is read-only.
protocol FileMutating: Sendable {
    /// Returns the resulting Trash URL when the system reports one.
    func trash(_ url: URL) throws -> URL?
    func delete(_ url: URL) throws
}

struct FileSystemExecutor: FileMutating {

    func trash(_ url: URL) throws -> URL? {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        return resulting as URL?
    }

    func delete(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}

/// Maps a Cocoa/POSIX error onto the failure vocabulary the journal and UI distinguish.
func failureReason(for error: any Error) -> ItemFailureReason {
    if let identityError = error as? FileIdentityError {
        if identityError.isNotFound { return .vanished }
        if identityError.isPermissionDenied { return .permissionDenied }
        return .filesystemError
    }
    let nsError = error as NSError
    switch nsError.domain {
    case NSCocoaErrorDomain:
        switch nsError.code {
        case NSFileNoSuchFileError, NSFileReadNoSuchFileError:
            return .vanished
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return .permissionDenied
        default:
            return .filesystemError
        }
    case NSPOSIXErrorDomain:
        switch Int32(nsError.code) {
        case ENOENT: return .vanished
        case EACCES, EPERM: return .permissionDenied
        default: return .filesystemError
        }
    default:
        return .filesystemError
    }
}
