import Darwin
import Foundation
import SweepPolicy
import SweepUninstall

// MARK: - Pure logic (unit-testable; see Tests/SweepAppTests/UninstallerLogicTests.swift)

/// Sort keys the Uninstaller's app list offers (PLAN §3 module 5: "icons, sizes, last-used,
/// search + sort").
enum AppSortField: String, CaseIterable, Identifiable, Sendable {
    case name
    case size
    case lastUsed

    var id: Self { self }

    var label: String {
        switch self {
        case .name: "Name"
        case .size: "Size"
        case .lastUsed: "Last used"
        }
    }
}

enum UninstallLogic {
    /// Case- and diacritic-insensitive filter over name and bundle id, same contract as
    /// `InventoryGroup.filtered(by:)` elsewhere in the app.
    static func filterApps(_ apps: [InstalledApp], query: String) -> [InstalledApp] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps }
        return apps.filter { app in
            app.name.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil
                || (app.bundleIdentifier?.range(of: trimmed, options: [.caseInsensitive, .diacriticInsensitive]) != nil)
        }
    }

    /// `sizeByPath`/`lastUsedByPath` are keyed by `InstalledApp.id` (the bundle path). Both are
    /// populated lazily in the background, so a sort can run before every value has arrived —
    /// apps with no value on record sort last regardless of direction, rather than jumping to
    /// wherever a missing `Int64`/`Date` would otherwise land.
    static func sortApps(
        _ apps: [InstalledApp],
        field: AppSortField,
        ascending: Bool,
        sizeByPath: [String: Int64],
        lastUsedByPath: [String: Date]
    ) -> [InstalledApp] {
        switch field {
        case .name:
            let sorted = apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            return ascending ? sorted : sorted.reversed()
        case .size:
            return sortByOptional(apps, ascending: ascending) { sizeByPath[$0.id] }
        case .lastUsed:
            return sortByOptional(apps, ascending: ascending) { lastUsedByPath[$0.id] }
        }
    }

    /// Sorts by an optional comparable value, always pushing `nil` (not-yet-computed) entries to
    /// the end regardless of `ascending`, then breaking ties by name for a stable, readable order.
    private static func sortByOptional<Value: Comparable>(
        _ apps: [InstalledApp],
        ascending: Bool,
        value: (InstalledApp) -> Value?
    ) -> [InstalledApp] {
        let (known, unknown) = apps.reduce(into: ([InstalledApp](), [InstalledApp]())) { result, app in
            if value(app) != nil { result.0.append(app) } else { result.1.append(app) }
        }
        let sortedKnown = known.sorted { lhs, rhs in
            guard let l = value(lhs), let r = value(rhs) else { return false }
            if l == r { return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending }
            return ascending ? l < r : l > r
        }
        let sortedUnknown = unknown.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return sortedKnown + sortedUnknown
    }

    /// PLAN §3 module 5: "System/protected apps (SweepPolicy denials, Apple signed) show a lock
    /// and refuse selection." Never Sweep itself either, regardless of how it happens to be
    /// signed in a given build.
    ///
    /// `app.isAppleSigned`/`app.isSystemLocation` (`SweepUninstall`) both go stale for a macOS 26
    /// cryptex-relocated system app: `/Applications/Safari.app` is a symlink into
    /// `/System/Cryptexes/...`, so the literal, unresolved `bundlePath` never starts with
    /// `/System/`, and `SecCertificateCopySubjectSummary` came back empty for it in testing on
    /// this exact machine (found running this module's own drop-route tests against real Safari)
    /// — `isAppleSigned` is documented as a heuristic, not a trust decision, and this is exactly
    /// the kind of case it can miss. `SweepUninstall` is off-limits for this deliverable, so the
    /// fix lives here: resolve symlinks before checking for a `/System/` root, and separately
    /// treat Apple's own reserved `com.apple.` bundle-id namespace as protected outright. Both are
    /// defense in depth on top of the upstream signals, never a replacement for them.
    static func isProtected(_ app: InstalledApp, sweepBundleIdentifier: String?) -> Bool {
        if app.isAppleSigned || app.isSystemLocation { return true }
        if let sweepBundleIdentifier, !sweepBundleIdentifier.isEmpty, app.bundleIdentifier == sweepBundleIdentifier {
            return true
        }
        if let bundleIdentifier = app.bundleIdentifier, bundleIdentifier.hasPrefix("com.apple.") {
            return true
        }
        if app.bundlePath.resolvingSymlinksInPath().path.hasPrefix("/System/") {
            return true
        }
        return SweepPolicy.isDeniedLexically(app.bundlePath)
    }
}

// MARK: - Size / last-used (impure: touches the filesystem)

/// On-disk allocated size for an arbitrary file or directory tree (PLAN Appendix B:
/// `totalFileAllocatedSizeKey` semantics — allocated, not logical, size).
///
/// This is its own small walk, not `SweepCore.ScanEngine` — the Uninstaller's read-only inventory
/// has no need for that engine's hardlink/clone-family dedup machinery (that precision matters
/// for a cleaning report's honest "freed" number; it doesn't change what an app-bundle-or-
/// leftover size readout is for here), and pulling it in would mean this display-only screen
/// depending on SweepCore for something `LargeOldFilesScreen` already shows is unnecessary at
/// this tier.
enum FileSizeCalculator {
    /// Every app-list row and every leftover group needs its own recursive size, and the naive
    /// `FileManager.enumerator` + per-entry `url.resourceValues(forKeys:)` walk (kept below as
    /// ``legacyAllocatedSize(at:fileManager:)``) pays a full `getattrlist` round trip per file:
    /// on a real app bundle or a `~/Library` leftover tree with thousands of entries, that per-
    /// entry overhead is exactly why sizes visibly trickle in. `getattrlistbulk(2)` answers a
    /// whole directory's worth of entries — name, type, BSD flags and allocated size — in one
    /// syscall per buffer-full, so the recursive descent below opens one directory at a time and
    /// asks the kernel for everything it needs about that directory's children in bulk.
    static func allocatedSize(at url: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return singleFileAllocatedSize(url) }
        return bulkDirectoryAllocatedSize(at: url.path)
    }

    private static func singleFileAllocatedSize(_ url: URL) -> Int64 {
        guard let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? 0)
    }

    // MARK: - Legacy implementation (kept for the getattrlistbulk parity test)

    /// The original `FileManager.enumerator`-based walk. Preserved verbatim (not called by
    /// ``allocatedSize(at:fileManager:)`` any more) purely as the oracle
    /// `FileSizeCalculatorTests` checks the bulk implementation against — a behavioral spec that
    /// happens to be runnable.
    static func legacyAllocatedSize(at url: URL, fileManager: FileManager = .default) -> Int64 {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else { return singleFileAllocatedSize(url) }

        var total: Int64 = 0
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles],
            errorHandler: nil
        ) else { return 0 }

        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: keys) else { continue }
            if values.isSymbolicLink == true { continue }
            if values.isDirectory == true { continue }
            total += Int64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    // MARK: - getattrlistbulk implementation

    /// Comfortably holds a batch of entries (even directories with thousands of short-named
    /// children) in one syscall; `getattrlistbulk` just returns fewer entries and this loops
    /// again if a directory doesn't fit. The man page only requires "large enough to hold at
    /// least one entry" — this is sized for throughput, not the minimum.
    private static let bulkBufferSize = 128 * 1024

    /// Iterative, stack-of-paths traversal (never recursive Swift calls, so an adversarially deep
    /// tree can't blow the call stack): each loop iteration opens exactly one directory, sums its
    /// regular-file children, queues its non-hidden subdirectories, then closes it before moving
    /// on — so at most one directory fd is open at a time, well inside the "O(depth)" budget.
    ///
    /// `open(..., O_NOFOLLOW)` on the root itself is deliberate, not incidental: a symlinked app
    /// bundle (macOS 26 cryptex-relocated system apps put a symlink at e.g.
    /// `/Applications/Safari.app`) makes `open` fail with `ENOTDIR`, which this treats as "unreadable,
    /// skip" → 0. Verified empirically that this matches ``legacyAllocatedSize(at:fileManager:)``:
    /// `FileManager.enumerator(at:)` on a symlink root fails to enumerate for the same reason
    /// (POSIX won't open a symlink path as a directory with `O_NOFOLLOW`, and Foundation's
    /// enumerator hits the identical wall internally), so both implementations silently return 0
    /// for a symlinked root rather than the target's size. That is a pre-existing quirk of the
    /// original implementation, not something introduced here — this only preserves it.
    private static func bulkDirectoryAllocatedSize(at rootPath: String) -> Int64 {
        var total: Int64 = 0
        var pendingDirectories: [String] = [rootPath]

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: bulkBufferSize, alignment: MemoryLayout<UInt64>.alignment)
        defer { buffer.deallocate() }

        while let path = pendingDirectories.popLast() {
            let fd = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
            // Unreadable/unopenable (permission denied, disappeared mid-walk, turned out to be a
            // symlink) — silently skipped, matching the legacy `errorHandler: nil` contract: one
            // bad subtree contributes 0 rather than aborting the whole size calculation.
            guard fd >= 0 else { continue }
            defer { close(fd) }
            total += bulkSum(directoryFD: fd, directoryPath: path, buffer: buffer, pendingDirectories: &pendingDirectories)
        }
        return total
    }

    /// One directory's worth of `getattrlistbulk` batches. Requests exactly the attributes
    /// needed and nothing else, in the fixed order the kernel packs them (see the man page's
    /// "attributes are returned in the order given" note — that order is by attribute-group bit
    /// value, NOT request order, and `ATTR_CMN_RETURNED_ATTRS` is always emitted first when
    /// requested, ahead of every other attribute regardless of its own bit's position):
    ///   `uint32 entryLength │ attribute_set_t returned │ attrreference_t name │
    ///    fsobj_type_t objType │ uint32 flags │ off_t allocSize (only if returned)`
    /// Verified byte-for-byte against a small C harness against this exact kernel before writing
    /// this parser, rather than trusting the man page's prose alone.
    private static func bulkSum(
        directoryFD: Int32,
        directoryPath: String,
        buffer: UnsafeMutableRawPointer,
        pendingDirectories: inout [String]
    ) -> Int64 {
        var total: Int64 = 0

        var attrList = attrlist()
        attrList.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        attrList.commonattr = ATTR_CMN_RETURNED_ATTRS
            | UInt32(ATTR_CMN_NAME)
            | UInt32(ATTR_CMN_OBJTYPE)
            | UInt32(ATTR_CMN_FLAGS)
        attrList.fileattr = UInt32(ATTR_FILE_ALLOCSIZE)

        while true {
            let entryCount = getattrlistbulk(directoryFD, &attrList, buffer, bulkBufferSize, UInt64(FSOPT_NOFOLLOW))
            // 0 = directory exhausted; negative = read error partway through — either way there
            // is nothing more to safely parse out of this directory.
            guard entryCount > 0 else { break }

            var cursor = buffer
            for _ in 0..<entryCount {
                let entryLength = cursor.load(as: UInt32.self)
                guard entryLength >= UInt32(MemoryLayout<UInt32>.size) else { break }
                defer { cursor += Int(entryLength) }

                var field = cursor + MemoryLayout<UInt32>.size
                let returnedAttrs = field.load(as: attribute_set_t.self)
                field += MemoryLayout<attribute_set_t>.size

                // `attrreference_t.attr_dataoffset` is relative to the address of the reference
                // struct itself, not to the start of the entry or the buffer.
                let nameRef = field.load(as: attrreference_t.self)
                let nameBytes = (field + Int(nameRef.attr_dataoffset)).assumingMemoryBound(to: UInt8.self)
                let nameLength = max(0, Int(nameRef.attr_length) - 1) // attr_length includes the trailing NUL
                let name = String(decoding: UnsafeBufferPointer(start: nameBytes, count: nameLength), as: UTF8.self)
                field += MemoryLayout<attrreference_t>.size

                let objectType = field.load(as: fsobj_type_t.self)
                field += MemoryLayout<fsobj_type_t>.size

                let flags = field.load(as: UInt32.self)
                field += MemoryLayout<UInt32>.size

                let allocSizeReturned = (returnedAttrs.fileattr & UInt32(ATTR_FILE_ALLOCSIZE)) != 0
                let allocSize = allocSizeReturned ? Int64(field.load(as: off_t.self)) : 0

                // `.skipsHiddenFiles` parity: a dot-prefixed name AND a `UF_HIDDEN`-flagged entry
                // are both "hidden" — and a hidden directory is never descended into, so its
                // contents (however large) never reach `total`.
                if name.hasPrefix(".") { continue }
                if flags & UInt32(UF_HIDDEN) != 0 { continue }

                switch objectType {
                case VREG.rawValue:
                    // The returned-attrs mask is honored, not assumed: a filesystem that didn't
                    // hand back ATTR_FILE_ALLOCSIZE for this entry (rare — some non-local
                    // volumes) falls back to a direct `lstat`-equivalent block count, the same
                    // `st_blocks * 512` SweepCore's own `FileIdentity` uses for the same purpose.
                    total += allocSizeReturned ? allocSize : fallbackAllocatedSize(directoryFD: directoryFD, name: name)
                case VDIR.rawValue:
                    pendingDirectories.append(directoryPath + "/" + name)
                default:
                    // Symbolic links (and any other object type) are never followed and never
                    // counted, matching the legacy `values.isSymbolicLink == true { continue }`.
                    continue
                }
            }
        }
        return total
    }

    private static func fallbackAllocatedSize(directoryFD: Int32, name: String) -> Int64 {
        var status = stat()
        let result = name.withCString { fstatat(directoryFD, $0, &status, AT_SYMLINK_NOFOLLOW) }
        guard result == 0 else { return 0 }
        return Int64(status.st_blocks) * 512
    }
}

/// App bundle size + last-used, computed lazily per bundle in the background (PLAN deliverable
/// 1: "size computed lazily per bundle allocated-size in background, last-used via
/// `.contentAccessDateKey` best-effort").
enum AppMetadataCalculator {
    static func allocatedSize(of app: InstalledApp) -> Int64 {
        FileSizeCalculator.allocatedSize(at: app.bundlePath)
    }

    /// Best-effort: `contentAccessDateKey` is not maintained by every filesystem/backup state,
    /// so a `nil` here means "unknown", never "never used" — the row shows nothing rather than a
    /// misleading date.
    static func lastUsedDate(of app: InstalledApp) -> Date? {
        try? app.bundlePath.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate
    }
}
