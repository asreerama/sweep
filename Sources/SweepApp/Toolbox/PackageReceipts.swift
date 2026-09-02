import Darwin
import Foundation
import SweepUI

// MARK: - Pure logic (unit-testable; see Tests/SweepAppTests/PackageReceiptsTests.swift)

/// Read-only `pkgutil` receipts browser (Toolbox "Packages" module, PLAN.md v1.1 backlog item,
/// promoted). STRICTLY READ-ONLY this wave: this file only ever shells out to `pkgutil --pkgs`,
/// `pkgutil --pkg-info-plist` and `pkgutil --files --only-files` — the same read-only contract
/// `Packages/SweepUninstall/Sources/SweepUninstall/PkgutilReceipts.swift` documents for its own
/// pkgutil use. `pkgutil --forget` and uninstall-by-receipt are gated destructive features that
/// ship later; `PackagesScreen`'s footnote says so plainly, and nothing in this file can perform
/// either.
///
/// Load shape (PERFORMANCE PROVENANCE — see `PrefetchedPkgutilReceipts`'s doc comment in
/// `PkgutilReceipts.swift`/`PrefetchedReceipts.swift`: 49 concurrent `pkgutil --files` spawns
/// measured ~48 s against ~4.4 s run serially, because parallel `pkgutil` invocations contend on
/// the shared receipts store and serialize with heavy backoff): this module never fans out.
/// `PackageIDsLoader` is the one `pkgutil --pkgs` spawn that populates the whole list; a given
/// receipt's `pkg-info-plist` and `--files` detail is fetched only when `PackagesModel` expands
/// that one row, one receipt at a time, and the result is cached for the rest of the session —
/// see `PackageReceiptDetailLoader` and `PackagesModel.loadDetailIfNeeded` in `PackagesScreen.swift`.
enum PackageReceiptsEngine {}

// MARK: - `pkgutil --pkgs` parsing

/// Parses `pkgutil --pkgs` stdout: one package identifier per line, nothing else on the line to
/// strip. `String.split` already omits empty subsequences, so blank lines (a trailing newline,
/// stray blank output) never become a spurious empty identifier.
enum PackagePkgsParser {
    static func parse(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
    }
}

// MARK: - `pkgutil --files --only-files` parsing

/// Parses `pkgutil --files <id> --only-files` stdout: one path per line, relative to the
/// receipt's install location (never a leading "/") — `--only-files` already excludes the
/// directory entries `pkgutil --files` would otherwise interleave, so every surviving line is a
/// real installed file.
enum PackageFilesParser {
    static func parse(_ output: String) -> [String] {
        output.split(separator: "\n").map(String.init)
    }
}

// MARK: - `pkgutil --pkg-info-plist` parsing

/// The four `pkg-info-plist` fields this module actually shows. Real `pkgutil` output carries a
/// few more (`pkgid`, `receipt-plist-version`) that duplicate what the caller already knows or
/// add nothing this screen surfaces, so they are read here.
struct PackagePkgInfo: Sendable, Hashable {
    /// As `pkgutil` states it — real-machine output favors no leading slash ("Applications",
    /// "Library/Caches/…"), but this is never assumed; `PackageFilePathJoiner` trims either way.
    let installLocation: String
    let installDate: Date?
    let version: String?
    /// The volume the package was installed to. Almost always "/" (the boot volume); a package
    /// installed to an external volume records that volume's mount path instead.
    let volume: String
}

/// Parses one `pkgutil --pkg-info-plist <id>` result. Pure over the already-captured `Data` — no
/// process spawn in this type, so it is fixture-testable with `PropertyListSerialization`-built
/// plist data exactly like `StartupItemParser` is.
///
/// Tolerant by construction: a plist that fails to parse at all yields `nil` (the receipt's
/// detail view then shows nothing rather than fabricated data), but a plist missing one or more
/// of the four fields below yields whatever it does have — `pkgutil`'s own format has been
/// stable for years, and a single absent key is not grounds to discard an otherwise-good receipt.
enum PackagePkgInfoParser {
    static func parse(plistData: Data) -> PackagePkgInfo? {
        guard
            let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any]
        else { return nil }

        let installLocation = plist["install-location"] as? String ?? ""
        let volume = plist["volume"] as? String ?? "/"
        let version = plist["pkg-version"] as? String
        let installDate = (plist["install-time"] as? Int).map { Date(timeIntervalSince1970: TimeInterval($0)) }

        return PackagePkgInfo(installLocation: installLocation, installDate: installDate, version: version, volume: volume)
    }
}

// MARK: - Absolute path join

/// Builds one claimed file's absolute path from its receipt's `volume` + `install-location` and
/// the file's own path relative to that install location.
///
/// Every component is trimmed of leading/trailing slashes before joining, so it does not matter
/// whether `pkgutil` hands back "/Applications", "Applications" or "/" for `install-location` (or
/// "/" vs "" for `volume`) — real-machine output favors no leading slash, but nothing here assumes
/// one shape and this never produces a doubled slash or drops a segment for either.
enum PackageFilePathJoiner {
    static func absolutePath(volume: String, installLocation: String, relativePath: String) -> String {
        let segments = [volume, installLocation, relativePath]
            .map(trimmedOfSlashes)
            .filter { !$0.isEmpty }
        return "/" + segments.joined(separator: "/")
    }

    private static func trimmedOfSlashes(_ component: String) -> String {
        var slice = Substring(component)
        while slice.first == "/" { slice.removeFirst() }
        while slice.last == "/" { slice.removeLast() }
        return String(slice)
    }
}

// MARK: - File existence (off-main; injectable for tests)

/// One file a receipt claims, its existence resolved separately — a receipt often outlives the
/// files it installed (an app dragged to the Trash leaves its `pkgutil` receipt behind), so
/// "claims" and "actually there right now" are two different facts this type keeps apart rather
/// than silently picking one.
struct PackageFileEntry: Identifiable, Sendable, Hashable {
    /// Absolute path — unique per receipt's file list, and the reveal-in-Finder target.
    var id: String { absolutePath }
    let absolutePath: String
    let relativePath: String
    let exists: Bool
}

/// Builds ``PackageFileEntry`` rows from a parsed relative-path list, joining each against the
/// receipt's own volume/install-location and checking existence through an injected closure —
/// pure and fixture-testable; `PackageFileExistenceChecker.exists` below is the only real
/// implementation ever passed in production.
enum PackageFileEntryBuilder {
    static func buildEntries(
        relativePaths: [String],
        volume: String,
        installLocation: String,
        fileExists: (String) -> Bool
    ) -> [PackageFileEntry] {
        relativePaths.map { relativePath in
            let absolutePath = PackageFilePathJoiner.absolutePath(
                volume: volume,
                installLocation: installLocation,
                relativePath: relativePath
            )
            return PackageFileEntry(absolutePath: absolutePath, relativePath: relativePath, exists: fileExists(absolutePath))
        }
    }
}

/// Real existence check for one claimed file. `lstat`, never `stat`/`FileManager.fileExists` —
/// consistent with every other identity read in this codebase (see `AppInventory.swift`,
/// `RootWalker.swift`): a broken symlink a receipt installed is still a filesystem entry that
/// exists, and this module's job is "is the claim still true on disk," not "does the link resolve."
enum PackageFileExistenceChecker {
    static func exists(atPath path: String) -> Bool {
        var info = stat()
        return path.withCString { lstat($0, &info) } == 0
    }
}

// MARK: - Bounded file-list display

/// Row-count constants for a receipt's expanded file list. Receipts can claim tens of thousands
/// of files (a large app bundle, an SDK); this keeps a single expanded row from ever asking
/// SwiftUI to lay out anywhere near that many at once.
enum PackageFileListDisplay {
    /// Rows shown as soon as a receipt row is expanded, before "Show all" is tapped.
    static let previewCount = 50
    /// Hard ceiling on rows ever rendered for one receipt's file list, "Show all" included.
    static let renderCap = 200

    static func visibleFiles(_ files: [PackageFileEntry], expanded: Bool) -> [PackageFileEntry] {
        Array(files.prefix(expanded ? renderCap : previewCount))
    }

    /// How many claimed files are not among ``visibleFiles(_:expanded:)`` — the "and N more" line.
    static func remainderCount(_ files: [PackageFileEntry], expanded: Bool) -> Int {
        max(0, files.count - visibleFiles(files, expanded: expanded).count)
    }
}

// MARK: - Apple-receipt filter

/// `com.apple.*` receipts are OS bookkeeping — every stock Mac carries hundreds of them — and
/// showing them by default would drown the handful of third-party receipts a user actually came
/// here to look at. Excluded by default, with a plain count so their existence is not hidden,
/// only their clutter.
enum ApplePackageFilter {
    static func isAppleReceipt(_ id: String) -> Bool {
        id == "com.apple" || id.hasPrefix("com.apple.")
    }

    /// Splits `ids` into everything that survives the filter and a count of what did not.
    static func excludingApple(_ ids: [String]) -> (kept: [String], appleCount: Int) {
        var kept: [String] = []
        kept.reserveCapacity(ids.count)
        var appleCount = 0
        for id in ids {
            if isAppleReceipt(id) {
                appleCount += 1
            } else {
                kept.append(id)
            }
        }
        return (kept, appleCount)
    }
}

// MARK: - Vendor grouping

/// One receipt identifier, plus its search key folded once at construction time rather than on
/// every keystroke — the same discipline `SearchFold`'s own doc comment describes and
/// `InventoryItem.searchKey` applies, here for `PackagesScreen`'s id search.
struct PackageReceiptSummary: Identifiable, Sendable, Hashable {
    let id: String
    let searchKey: String

    init(id: String) {
        self.id = id
        self.searchKey = SearchFold.fold(id)
    }
}

/// Human-facing vendor name for one package id, derived from its reverse-DNS prefix: the second
/// component ("com.microsoft.*" → "microsoft") capitalized. An id with fewer than two components
/// (essentially never real `pkgutil` output, but not something a parser should crash over) falls
/// back to a plain "Other" bucket rather than fabricating a vendor name from a single label.
enum PackageVendor {
    static let fallbackName = "Other"

    static func displayName(forPackageID id: String) -> String {
        let components = id.split(separator: ".", omittingEmptySubsequences: true)
        guard components.count >= 2, !components[1].isEmpty else { return fallbackName }
        return components[1].capitalized
    }
}

/// One vendor's receipts, sorted for a stable read.
struct PackageVendorGroup: Identifiable, Sendable, Hashable {
    let vendorName: String
    let receipts: [PackageReceiptSummary]
    var id: String { vendorName }

    /// Case/diacritic-insensitive filter over each receipt's pre-folded search key — the same
    /// "fold once, `contains` many times" shape `InventoryGroup.filtered(by:)` uses, so id search
    /// stays keystroke-instant even on a machine with several hundred receipts installed.
    /// `foldedQuery` is expected already folded (`SearchFold.fold`); an empty query matches
    /// everything. Returns `nil` when nothing in the group survives, so the caller can drop the
    /// section entirely rather than render an empty card.
    func filtered(byFoldedQuery foldedQuery: String) -> PackageVendorGroup? {
        guard !foldedQuery.isEmpty else { return self }
        let matches = receipts.filter { $0.searchKey.contains(foldedQuery) }
        guard !matches.isEmpty else { return nil }
        return PackageVendorGroup(vendorName: vendorName, receipts: matches)
    }
}

enum PackageVendorGrouping {
    /// One group per vendor, sorted alphabetically by display name; each group's own receipts
    /// sorted case-insensitively by id. Never sized/size-sorted the way a junk scan's groups
    /// are — this is a receipts browser, and an alphabetical order is what makes "find Adobe's
    /// receipts" a legible scroll rather than a search.
    static func buildGroups(from ids: [String]) -> [PackageVendorGroup] {
        var idsByVendor: [String: [String]] = [:]
        for id in ids {
            idsByVendor[PackageVendor.displayName(forPackageID: id), default: []].append(id)
        }
        return idsByVendor.keys
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .map { vendor in
                let sortedIDs = (idsByVendor[vendor] ?? []).sorted {
                    $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
                }
                return PackageVendorGroup(vendorName: vendor, receipts: sortedIDs.map(PackageReceiptSummary.init))
            }
    }
}

// MARK: - Process I/O (impure; nothing here is unit-tested — see PackageReceiptsTests.swift header)

/// One receipt's on-demand detail: parsed `pkg-info-plist` metadata plus its claimed files, each
/// existence-checked. `info` is `nil` when the plist spawn failed or did not parse — the detail
/// view then shows the file list (if any) with no metadata line, rather than nothing at all.
struct PackageReceiptDetail: Sendable, Hashable {
    let info: PackagePkgInfo?
    let files: [PackageFileEntry]
}

/// Fixed-executable-path `pkgutil` runner. Never interprets a shell string, never `sh -c`, and —
/// per this file's read-only contract — only ever invokes `--pkgs`, `--pkg-info-plist` and
/// `--files --only-files`.
///
/// Byte-for-byte the same hardened shape as `Packages/SweepUninstall/Sources/SweepUninstall/
/// PkgutilReceipts.swift`'s `ProcessRunner` (concurrent bounded pipe draining, wall-clock timeout,
/// per-stream byte cap) rather than importing it: that type is `internal` to `SweepUninstall` and
/// unreachable from this target — see `LocalProcessRunner.swift`'s doc comment for why this
/// codebase re-implements the pattern per call site instead of sharing it across a target boundary.
enum PackageProcessRunner {
    enum RunError: Error, Sendable, Equatable {
        case nonZeroExit(Int32, stderr: String)
        case timedOut
        case outputLimitExceeded
    }

    /// `pkgutil` queries are local, fast metadata reads — anything still running after this long
    /// is hung, not merely slow. Matches `PkgutilReceipts.ProcessRunner`'s own default.
    static let defaultTimeout: TimeInterval = 10
    static let defaultOutputByteLimit = 4 * 1024 * 1024
    /// `--files --only-files` on a large app bundle or SDK receipt can print tens of thousands of
    /// lines; the default 4 MB cap (comfortable for `--pkgs`/`--pkg-info-plist`, both tiny) would
    /// truncate a legitimate large receipt's file list, so callers of `--files` pass this instead.
    static let filesListOutputByteLimit = 16 * 1024 * 1024

    private static let sanitizedEnvironment = ["PATH": "/usr/bin:/bin"]
    private static let sanitizedWorkingDirectory = URL(fileURLWithPath: "/private/var/empty")

    @discardableResult
    static func run(
        _ executablePath: String,
        _ arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        outputByteLimit: Int = defaultOutputByteLimit
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.environment = sanitizedEnvironment
        process.currentDirectoryURL = sanitizedWorkingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Concurrent, incremental drain of both streams — never a single "read to EOF" call,
        // which is what lets a child whose stderr pipe buffer fills while nothing reads it yet
        // (it keeps stdout open, blocked on its own stalled `write()`) wedge a naive reader
        // forever. See `PkgutilReceipts.ProcessRunner`'s doc comment for the full deadlock this
        // avoids.
        let stdoutReader = PackageBoundedPipeReader(pipe: stdoutPipe, byteLimit: outputByteLimit)
        let stderrReader = PackageBoundedPipeReader(pipe: stderrPipe, byteLimit: outputByteLimit)

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { stdoutReader.readToLimitOrEOF(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { stderrReader.readToLimitOrEOF(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        var didTimeOut = false
        var didOverflow = false
        while true {
            if stdoutReader.overflowed || stderrReader.overflowed {
                didOverflow = true
                break
            }
            if group.wait(timeout: .now() + 0.05) == .success {
                break
            }
            if Date() >= deadline {
                didTimeOut = true
                break
            }
        }

        if didOverflow || didTimeOut {
            stdoutReader.requestStop()
            stderrReader.requestStop()
            if process.isRunning {
                process.terminate()
            }
            _ = group.wait(timeout: .now() + 2)
        }

        if didTimeOut { throw RunError.timedOut }
        if didOverflow { throw RunError.outputLimitExceeded }

        guard process.terminationStatus == 0 else {
            throw RunError.nonZeroExit(process.terminationStatus, stderr: stderrReader.string)
        }
        return stdoutReader.string
    }
}

/// Reads one pipe's output incrementally, stopping the moment either EOF is reached, `byteLimit`
/// is exceeded, or an external stop is requested. Byte-for-byte the same shape as
/// `PkgutilReceipts.BoundedPipeReader` (`private` there, so re-declared here rather than shared).
private final class PackageBoundedPipeReader: @unchecked Sendable {
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

private enum PkgutilExecutable {
    static let path = "/usr/sbin/pkgutil"
}

/// The one `pkgutil --pkgs` spawn that populates ``PackagesModel``'s whole list. Any launch or
/// non-zero-exit failure yields an empty list — the screen then shows its empty state rather than
/// an error, matching this codebase's convention for a read-only inventory (`PluginKitRunner`,
/// `StartupItemsScanner`) that every failure here is routine, not exceptional.
enum PackageIDsLoader {
    static func load() -> [String] {
        guard let output = try? PackageProcessRunner.run(PkgutilExecutable.path, ["--pkgs"]) else { return [] }
        return PackagePkgsParser.parse(output)
    }
}

/// Loads one receipt's on-demand detail (PERFORMANCE PROVENANCE, see this file's top-level doc
/// comment): `pkg-info-plist` first, then `--files --only-files`, each claimed file's existence
/// resolved via `fileExists`. Two spawns and up to tens of thousands of `lstat` calls — always run
/// off the main actor by `PackagesModel`, and never run again for a receipt already cached this
/// session.
enum PackageReceiptDetailLoader {
    static func load(
        packageID: String,
        fileExists: (String) -> Bool = PackageFileExistenceChecker.exists
    ) -> PackageReceiptDetail {
        let info = (try? PackageProcessRunner.run(PkgutilExecutable.path, ["--pkg-info-plist", packageID]))
            .flatMap { $0.data(using: .utf8) }
            .flatMap(PackagePkgInfoParser.parse)

        let filesOutput = (try? PackageProcessRunner.run(
            PkgutilExecutable.path,
            ["--files", packageID, "--only-files"],
            outputByteLimit: PackageProcessRunner.filesListOutputByteLimit
        )) ?? ""
        let relativePaths = PackageFilesParser.parse(filesOutput)
        let files = PackageFileEntryBuilder.buildEntries(
            relativePaths: relativePaths,
            volume: info?.volume ?? "/",
            installLocation: info?.installLocation ?? "",
            fileExists: fileExists
        )
        return PackageReceiptDetail(info: info, files: files)
    }
}
