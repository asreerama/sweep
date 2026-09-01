import CoreServices
import Foundation

/// SmartDelete watcher (PLAN §3 module 5: "SmartDelete watcher (PROMOTED backlog -> v1.0):
/// Sentinel-pattern FSEvents watch on ~/.Trash; app bundle trashed => quiet panel offers leftover
/// cleanup").
///
/// Pattern ported from Pearcleaner's `PearcleanerSentinel` (scratchpad clone,
/// `PearcleanerSentinel/FileWatcher.swift` + `main.swift`; Apache-2.0 + Commons Clause — pattern
/// only, not code): one `FSEventStream` on `~/.Trash`, `kFSEventStreamCreateFlagFileEvents` so
/// individual file events land, `isInTrash` via `URLRelationship` to confirm the item is really
/// still there and really under the Trash (not a transient rename-through). Pearcleaner ran this
/// as a second, always-running launch-agent binary talking back to the main app over distributed
/// notifications; this deliverable runs it in-process instead (no separate binary yet — PLAN
/// deliverable 3), as one object the main app starts and stops directly.
@MainActor
final class TrashSentinel {
    static let shared = TrashSentinel()

    private var streamRef: FSEventStreamRef?
    private var seenPaths = Set<String>()

    private init() {}

    var isRunning: Bool { streamRef != nil }

    func start() {
        guard streamRef == nil else { return }
        let trashPath = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash").path

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            Self.eventCallback,
            &context,
            [trashPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0,
            UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) else { return }

        streamRef = stream
        FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
        FSEventStreamStart(stream)
    }

    func stop() {
        guard let stream = streamRef else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        streamRef = nil
        seenPaths.removeAll()
    }

    /// `@convention(c)`-compatible: a stored, non-capturing closure, same shape as Pearcleaner's
    /// own `FileWatcher.eventCallback`. Hops back onto the main actor per path before touching
    /// any app state — FSEvents delivers on the dispatch queue `start()` assigned, never the
    /// main queue.
    private static let eventCallback: FSEventStreamCallback = { _, contextInfo, numEvents, eventPaths, _, _ in
        guard let contextInfo else { return }
        let sentinel = Unmanaged<TrashSentinel>.fromOpaque(contextInfo).takeUnretainedValue()
        guard let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] else { return }
        for index in 0..<numEvents {
            let path = paths[index]
            Task { @MainActor in sentinel.handle(path: path) }
        }
    }

    private func handle(path: String) {
        guard path.hasSuffix(".app") else { return }
        guard seenPaths.insert(path).inserted else { return }

        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else { return } // already gone (emptied, restored)
        guard Self.isInTrash(url) else { return }
        guard let bundle = Bundle(url: url), let bundleIdentifier = bundle.bundleIdentifier else { return }
        guard bundleIdentifier != Bundle.main.bundleIdentifier else { return } // never offer to clean up Sweep itself

        let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle.infoDictionary?["CFBundleName"] as? String)
            ?? url.deletingPathExtension().lastPathComponent

        TrashOfferPanel.show(appName: name, bundleIdentifier: bundleIdentifier)
    }

    /// Same check Pearcleaner's Sentinel uses (`FileManager.isInTrash`): confirms the item is
    /// really contained by the Trash directory right now, not merely named like one mid-rename.
    private static func isInTrash(_ url: URL) -> Bool {
        var relationship: FileManager.URLRelationship = .other
        do {
            try FileManager.default.getRelationship(&relationship, of: .trashDirectory, in: .userDomainMask, toItemAt: url)
            return relationship == .contains
        } catch {
            return false
        }
    }
}
