import AppKit
import Foundation
import Observation
import SweepCore
import SweepPolicy
import SweepUI

// MARK: - Pure logic (unit-testable; see Tests/SweepAppTests/FileSearchLogicTests.swift)

/// One search hit. Fields resolve in two waves — see ``FileSearchService``'s doc comment — so
/// every field but `id`/`name`/`parentPath` starts `nil` and fills in as the resolve pass lstats
/// the path.
struct FileSearchEntry: Sendable, Equatable, Identifiable {
    /// Absolute path. Both the SwiftUI row identity and the reveal/trash target — never shown
    /// directly in the UI, which only ever renders `name` and the home-abbreviated `parentPath`.
    let id: String
    let name: String
    /// Home-abbreviated parent directory (`"~/Downloads"`), never the raw absolute path.
    let parentPath: String
    /// `nil` until the resolve pass lstats this path.
    let kind: FileKind?
    /// Allocated size in bytes, `nil` until resolved (renders as the streaming "—" placeholder).
    /// For a directory this is its own shallow entry size — `totalFileAllocatedSizeKey` never
    /// descends into a directory's children, so this is never a recursive walk (PLAN promotion
    /// spec: "directories get a shallow size, NOT a deep walk").
    let bytes: Int64?
    let modified: Date?
    /// Captured at resolve time. Trashing re-reads the live file and refuses one that changed or
    /// vanished since — the same discipline `LargeFilesModel.performTrash` follows.
    let identity: FileIdentity?

    init(
        id: String, name: String, parentPath: String,
        kind: FileKind? = nil, bytes: Int64? = nil, modified: Date? = nil, identity: FileIdentity? = nil
    ) {
        self.id = id
        self.name = name
        self.parentPath = parentPath
        self.kind = kind
        self.bytes = bytes
        self.modified = modified
        self.identity = identity
    }
}

enum FileSearchSortOrder: String, CaseIterable, Identifiable, Sendable {
    case size
    case name

    var id: Self { self }

    var label: String {
        switch self {
        case .size: "Size"
        case .name: "Name"
        }
    }
}

enum FileSearchLogic {
    /// Below this, a wildcard search would echo back a huge slice of the whole index — PLAN
    /// promotion spec: "refuse queries shorter than 2 chars".
    static let minimumQueryLength = 2
    /// Ceiling on paths one `mdfind` call is allowed to hand back to the resolve pass.
    static let maxHits = 2000
    /// Rows actually rendered, regardless of how many hits `mdfind` returned — the same titlebar-
    /// safety discipline `InventoryBudget` applies elsewhere, sized down for a flat (ungrouped)
    /// list with no per-section paging.
    static let visibleRowCap = 500

    /// Strips the two characters that could let a query escape the quoted mdfind predicate
    /// (`kMDItemFSName == "*<query>*"c`): a double quote closes the predicate's string early, a
    /// backslash starts an escape inside it. Dropping them outright rather than escaping them
    /// means there is no value this predicate could ever mis-parse as anything but a literal name
    /// fragment.
    static func sanitizeQuery(_ raw: String) -> String {
        raw.filter { $0 != "\"" && $0 != "\\" }
    }

    /// `nil` when the sanitized, trimmed query is shorter than ``minimumQueryLength`` — the
    /// caller never spawns `mdfind` for a query that would not usefully narrow anything.
    static func mdfindPredicate(forQuery raw: String) -> String? {
        let trimmed = sanitizeQuery(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= minimumQueryLength else { return nil }
        return "kMDItemFSName == \"*\(trimmed)*\"c"
    }

    /// `mdfind` prints one absolute path per line; a run that matches nothing prints nothing.
    static func parsePaths(_ stdout: String) -> [String] {
        stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    }

    static func capped(_ paths: [String]) -> [String] {
        Array(paths.prefix(maxHits))
    }

    /// The cloud-backed locations this search skips: `~/Library/CloudStorage` and iCloud Drive
    /// (`~/Library/Mobile Documents`) — the two areas a Spotlight hit can point at a not-yet-
    /// downloaded placeholder, which would either lstat wrong or trigger a download this
    /// read-only search has no business starting.
    ///
    /// Deliberately narrower than `LargeFilesScanService`'s full `honorsPolicyDenylist` walk,
    /// which also excludes Documents/Desktop/Pictures/Mail/Photos: those are ordinary, fully
    /// local user content and exactly where a "find that huge file by name" search is most
    /// useful — hiding them from a targeted, user-initiated, per-item-confirmed search (unlike an
    /// auto-selected cleanup catalog) would gut the feature for no safety benefit. Built from
    /// `SweepPolicy.protectedURLs()` rather than hardcoded strings, so the paths stay identity-
    /// pinned to the real home the rest of the app resolves.
    static func protectedPrefixes(home: URL) -> [String] {
        let all = SweepPolicy.protectedURLs(home: home)
        let cloudAreas: [SweepPolicy.ProtectedArea] = [.cloudStorage, .iCloudDrive]
        return cloudAreas.compactMap { all[$0] }.flatMap { $0 }.map(\.path)
    }

    static func isProtectedPath(_ path: String, protectedPrefixes: [String]) -> Bool {
        protectedPrefixes.contains { path == $0 || path.hasPrefix($0 + "/") }
    }

    /// Splits `mdfind`'s raw hits into what the search keeps and how many it silently dropped —
    /// `skipped` backs the footer's "N cloud-backed items skipped" honesty note.
    static func partitioningProtected(
        _ paths: [String], protectedPrefixes: [String]
    ) -> (kept: [String], skipped: Int) {
        var kept: [String] = []
        kept.reserveCapacity(paths.count)
        var skipped = 0
        for path in paths {
            if isProtectedPath(path, protectedPrefixes: protectedPrefixes) {
                skipped += 1
            } else {
                kept.append(path)
            }
        }
        return (kept, skipped)
    }

    static func symbol(for kind: FileKind?) -> String {
        switch kind {
        case .file: "doc"
        case .directory: "folder"
        case .symbolicLink: "arrow.triangle.turn.up.right.circle"
        case .other, nil: "doc"
        }
    }

    /// Files/folders with a known size first, largest first; anything still unresolved sorts
    /// last. Ties (including two unresolved rows) break alphabetically so repeated sorts of the
    /// same data are stable.
    static func sort(_ entries: [FileSearchEntry], order: FileSearchSortOrder) -> [FileSearchEntry] {
        switch order {
        case .name:
            return entries.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .size:
            return entries.sorted { lhs, rhs in
                switch (lhs.bytes, rhs.bytes) {
                case let (l?, r?):
                    return l != r ? l > r : lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                case (nil, nil):
                    return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
                case (nil, _):
                    return false
                case (_, nil):
                    return true
                }
            }
        }
    }

    /// While sizes are still streaming in, row order must not jitter tick to tick — the same
    /// staged-sizing discipline `HomebrewModel` follows: keep whatever order the rows landed in,
    /// and only ever resort once every hit has had its chance to size.
    static func displayOrder(
        _ entries: [FileSearchEntry], sortOrder: FileSearchSortOrder, isSizing: Bool
    ) -> [FileSearchEntry] {
        isSizing ? entries : sort(entries, order: sortOrder)
    }

    /// Merges one resolve tick's freshly-stat'd entries into the existing list by id, preserving
    /// array order — an entry the tick did not resolve keeps whatever it already had (its
    /// placeholder, or an earlier tick's result).
    static func merging(_ resolved: [String: FileSearchEntry], into entries: [FileSearchEntry]) -> [FileSearchEntry] {
        entries.map { resolved[$0.id] ?? $0 }
    }

    /// Rows actually rendered vs. how many were cut off — `visibleRowCap` at a time, never more,
    /// regardless of how many hits the search produced.
    static func visibleRows(_ entries: [FileSearchEntry]) -> (shown: [FileSearchEntry], overflow: Int) {
        guard entries.count > visibleRowCap else { return (entries, 0) }
        return (Array(entries.prefix(visibleRowCap)), entries.count - visibleRowCap)
    }
}

// MARK: - Search (impure: spawns `mdfind`, touches the filesystem)

/// Name search over the user's home, backed by Spotlight rather than a directory walk — the
/// PearCleaner-style "find that huge file by name" hub (PLAN backlog, promoted).
///
/// Two waves per search, mirroring `HomebrewModel`'s staged load: ``search(query:home:)`` spawns
/// exactly one `mdfind` process and returns unsized placeholder entries the instant it exits
/// (mdfind's own index lookup is the only slow part, and it is fast); ``resolve(paths:home:
/// batchSize:onTick:)`` then lstats every hit off the main thread and streams batches of resolved
/// entries back, so a 2,000-hit search never blocks the UI behind the very last file.
enum FileSearchService {
    struct SearchResult: Sendable {
        let placeholders: [FileSearchEntry]
        let skippedProtectedCount: Int
    }

    struct ResolveTick: Sendable {
        let resolved: [String: FileSearchEntry]
    }

    private static let outputByteLimit = 8 * 1024 * 1024
    private static let processTimeout: TimeInterval = 15

    /// Runs `mdfind -onlyin <home> <predicate>` once and returns unsized placeholder entries in
    /// whatever order Spotlight returned them. `nil` when `query` is too short to search at all —
    /// the caller never spawns a process for that.
    static func search(query: String, home: URL) -> SearchResult? {
        guard let predicate = FileSearchLogic.mdfindPredicate(forQuery: query) else { return nil }
        let stdout = runMdfind(predicate: predicate, home: home)
        let allPaths = FileSearchLogic.parsePaths(stdout)
        let protectedPrefixes = FileSearchLogic.protectedPrefixes(home: home)
        let (kept, skipped) = FileSearchLogic.partitioningProtected(allPaths, protectedPrefixes: protectedPrefixes)
        let displayHome = home.path
        let placeholders = FileSearchLogic.capped(kept).map { path -> FileSearchEntry in
            let url = URL(fileURLWithPath: path)
            return FileSearchEntry(
                id: path,
                name: url.lastPathComponent,
                parentPath: SweepFormat.abbreviatingHome(url.deletingLastPathComponent().path, home: displayHome)
            )
        }
        return SearchResult(placeholders: placeholders, skippedProtectedCount: skipped)
    }

    /// Fixed absolute executable path, never a `PATH` lookup or a shell (PLAN §2: typed adapters
    /// only). Bounded output and a wall-clock timeout guard a network-mounted home or an
    /// unusually large index from hanging the search indefinitely — the same concurrent-drain
    /// discipline as `BrewProcessRunner`, not a naive `readDataToEndOfFile()`, which can deadlock
    /// if stderr fills its pipe buffer while nothing is reading it.
    private static func runMdfind(predicate: String, home: URL) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", home.path, predicate]
        process.standardInput = FileHandle.nullDevice

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            return ""
        }

        let stdoutReader = BoundedPipeReader(pipe: stdoutPipe, byteLimit: outputByteLimit)
        let stderrReader = BoundedPipeReader(pipe: stderrPipe, byteLimit: outputByteLimit)
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { stdoutReader.readToLimitOrEOF(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { stderrReader.readToLimitOrEOF(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); group.leave() }

        let deadline = Date().addingTimeInterval(processTimeout)
        var timedOut = false
        while true {
            if stdoutReader.overflowed { break }
            if group.wait(timeout: .now() + 0.05) == .success { break }
            if Date() >= deadline { timedOut = true; break }
        }
        if timedOut {
            stdoutReader.requestStop()
            stderrReader.requestStop()
            if process.isRunning { process.terminate() }
            _ = group.wait(timeout: .now() + 2)
        }
        return stdoutReader.string
    }

    /// Resolves kind, shallow allocated size, modification date and identity for every path — one
    /// `lstat` (via `FileIdentity`, symlink-safe) plus one `totalFileAllocatedSizeKey` resource
    /// read per hit. Both are cheap individually; run off the main thread in `batchSize` chunks so
    /// the model can stream results in progressively rather than waiting on the whole list.
    static func resolve(
        paths: [String], home: URL, batchSize: Int = 100,
        onTick: @Sendable @escaping (ResolveTick) -> Void
    ) {
        let displayHome = home.path
        var batch: [String: FileSearchEntry] = [:]
        for path in paths {
            batch[path] = resolveOne(path, displayHome: displayHome)
            if batch.count >= batchSize {
                onTick(ResolveTick(resolved: batch))
                batch = [:]
            }
        }
        if !batch.isEmpty { onTick(ResolveTick(resolved: batch)) }
    }

    private static func resolveOne(_ path: String, displayHome: String) -> FileSearchEntry {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        let parentPath = SweepFormat.abbreviatingHome(url.deletingLastPathComponent().path, home: displayHome)
        guard let identity = try? FileIdentity.read(at: url) else {
            // Vanished between the mdfind hit and this stat — the name is still informative, so
            // the row stays, permanently unsized rather than guessing at a value.
            return FileSearchEntry(id: path, name: name, parentPath: parentPath)
        }
        return FileSearchEntry(
            id: path, name: name, parentPath: parentPath,
            kind: identity.kind, bytes: shallowAllocatedSize(at: url),
            modified: identity.modification.date, identity: identity
        )
    }

    /// The path's own allocated size. `totalFileAllocatedSizeKey` never descends into a
    /// directory's children, so a folder's number here is its own entry — never a recursive walk.
    private static func shallowAllocatedSize(at url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? 0)
    }
}

/// Concurrent, incremental pipe drain with a byte cap. Same shape as `BrewProcessRunner`'s private
/// reader of the same name, re-declared here because that one is private to its file.
private final class BoundedPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let byteLimit: Int
    private let lock = NSLock()
    private var data = Data()
    private var stopRequested = false
    private(set) var overflowed = false

    init(pipe: Pipe, byteLimit: Int) {
        handle = pipe.fileHandleForReading
        self.byteLimit = byteLimit
    }

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    func readToLimitOrEOF() {
        while !shouldStop {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            lock.lock()
            data.append(chunk)
            let exceeded = data.count > byteLimit
            if exceeded { overflowed = true }
            lock.unlock()
            if exceeded { return }
        }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

// MARK: - Screen state

enum FileSearchPhase: Equatable {
    case idle
    case searching
    case results
}

/// Screen state for File Search (Toolbox, PLAN backlog promotion): debounced Spotlight search,
/// staged sizing, per-row reveal/trash.
@MainActor
@Observable
final class FileSearchModel {
    private(set) var phase: FileSearchPhase = .idle
    private(set) var entries: [FileSearchEntry] = []
    private(set) var lastQuery = ""
    private(set) var skippedProtectedCount = 0
    /// True while the resolve pass is still filling sizes in — the row order stays frozen for
    /// exactly this span (see `FileSearchLogic.displayOrder`).
    private(set) var isSizing = false

    var sortOrder: FileSearchSortOrder = .size

    private(set) var pendingTrash: FileSearchEntry?
    private(set) var isTrashing = false
    private(set) var trashError: String?

    private var searchTask: Task<Void, Never>?
    private var sizingTask: Task<Void, Never>?
    /// Bumped on every new search (including a reset back to idle). A resolve tick or a search
    /// result born before the latest bump is stale and is dropped rather than applied — the same
    /// discipline `HomebrewModel.mutationGeneration` uses to reject slow-tail results that would
    /// otherwise resurrect a superseded query's data.
    private var generation = 0

    var displayedEntries: [FileSearchEntry] {
        FileSearchLogic.displayOrder(entries, sortOrder: sortOrder, isSizing: isSizing)
    }

    var visible: (shown: [FileSearchEntry], overflow: Int) {
        FileSearchLogic.visibleRows(displayedEntries)
    }

    var totalBytes: Int64 { entries.compactMap(\.bytes).reduce(0, +) }

    var resultsCaption: String {
        let noun = entries.count == 1 ? "result" : "results"
        return "\(SweepFormat.count(entries.count)) \(noun) \u{00B7} \(SweepFormat.bytes(totalBytes)) total"
    }

    var skippedSummary: String? {
        guard skippedProtectedCount > 0 else { return nil }
        let noun = skippedProtectedCount == 1 ? "item" : "items"
        return "\(SweepFormat.count(skippedProtectedCount)) cloud-backed \(noun) skipped."
    }

    /// Called on every keystroke. Debounces the actual `mdfind` spawn by 250 ms — the one Toolbox
    /// module that would otherwise launch a process per character typed.
    func queryChanged(_ query: String) {
        searchTask?.cancel()
        guard FileSearchLogic.mdfindPredicate(forQuery: query) != nil else {
            sizingTask?.cancel()
            generation += 1
            phase = .idle
            entries = []
            isSizing = false
            lastQuery = query
            pendingTrash = nil
            return
        }
        searchTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            await self?.runSearch(query: query)
        }
    }

    private func runSearch(query: String) async {
        sizingTask?.cancel()
        generation += 1
        let thisGeneration = generation
        phase = .searching
        pendingTrash = nil

        let home = ScanEnvironment.resolve().home
        let result = await Task.detached(priority: .userInitiated) {
            FileSearchService.search(query: query, home: home)
        }.value
        guard !Task.isCancelled, generation == thisGeneration else { return }
        applyResult(result, query: query, home: home, generation: thisGeneration)
    }

    private func applyResult(_ result: FileSearchService.SearchResult?, query: String, home: URL, generation thisGeneration: Int) {
        guard let result else {
            phase = .idle
            entries = []
            return
        }
        entries = result.placeholders
        skippedProtectedCount = result.skippedProtectedCount
        lastQuery = query
        phase = .results
        guard !result.placeholders.isEmpty else { return }

        isSizing = true
        let paths = result.placeholders.map(\.id)
        sizingTask = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            FileSearchService.resolve(paths: paths, home: home) { tick in
                Task { @MainActor in
                    guard self.generation == thisGeneration else { return }
                    self.entries = FileSearchLogic.merging(tick.resolved, into: self.entries)
                }
            }
            await MainActor.run {
                guard self.generation == thisGeneration else { return }
                self.isSizing = false
            }
        }
    }

    func cancel() {
        searchTask?.cancel()
        sizingTask?.cancel()
    }

    // MARK: - Row actions

    /// Read-only, sandboxed-safe: hands the item off to Finder rather than touching it directly.
    func reveal(_ entry: FileSearchEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: entry.id)])
    }

    func requestTrash(_ entry: FileSearchEntry) {
        pendingTrash = entry
    }

    func cancelTrash() {
        pendingTrash = nil
    }

    func dismissTrashError() {
        trashError = nil
    }

    /// Identity-checked, reversible move to Trash — same contract as every other mutation in this
    /// app: the thing being trashed must still be the thing the search showed.
    func confirmTrash() {
        guard let entry = pendingTrash, !isTrashing else { return }
        pendingTrash = nil
        isTrashing = true
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.performTrash(entry: entry)
            }.value
            switch outcome {
            case .success:
                entries.removeAll { $0.id == entry.id }
                trashError = nil
            case .failure(let failure):
                trashError = failure.message
            }
            isTrashing = false
        }
    }

    private nonisolated static func performTrash(entry: FileSearchEntry) -> Result<Void, TrashFailure> {
        let url = URL(fileURLWithPath: entry.id)
        if let reviewed = entry.identity {
            guard let live = try? FileIdentity.read(at: url), live.isSameFile(as: reviewed) else {
                return .failure(TrashFailure(message: "It changed or disappeared since the search \u{2014} search again to act on it."))
            }
        }
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
            return .success(())
        } catch {
            return .failure(TrashFailure(message: (error as NSError).localizedDescription))
        }
    }
}

/// Wraps a human-readable trash failure so it can travel through `Result` as an `Error`.
private struct TrashFailure: Error, Sendable {
    let message: String
}
