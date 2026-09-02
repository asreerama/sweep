import Darwin
import Foundation
import SweepPolicy

/// `getattrlistbulk(2)` backend: the fast path the ``VolumeWalker`` protocol was written for.
///
/// ``FileManagerVolumeWalker`` pays three kernel round trips and a pile of Foundation object
/// churn for every single item — `nextObject()`, a separate `lstat`, and a
/// `resourceValues(forKeys:)` — which is affordable at fixture scale and ruinous at the
/// hundreds of thousands of files a real Smart Scan sees. This backend asks the kernel for a
/// whole batch of directory entries *and* their attributes in one syscall, so the per-entry
/// cost collapses to pointer arithmetic over a 256 KB buffer.
///
/// Everything the scan engine can observe is unchanged: pre-order traversal, `depth`
/// numbering, symlinks never followed, the volume boundary never crossed, the policy denylist
/// honoured before anything expensive happens, and the same ``WalkIssue`` and ``WalkError``
/// vocabulary. The one thing this type may never get wrong is ``FileIdentity``: those bytes are
/// compared against a fresh `lstat`/`fstatat` at delete time, and any drift fails closed and
/// silently blocks cleaning. Where a bulk attribute cannot be proven byte-identical to `stat`,
/// this walker spends an `lstat` rather than guess; `RawEntry.completeIdentity(volume:)` is
/// where that line is drawn, and `BulkVolumeWalkerTests` is what holds it.
public struct BulkVolumeWalker: VolumeWalker {

    /// One `getattrlistbulk` call fills as much of this as it can. Bigger buffers mean fewer
    /// syscalls per directory; 256 KB holds well over a thousand typical entries, which is
    /// more than almost any real directory contains, so most directories cost a single call.
    static let bufferCapacity = 256 * 1024

    public init() {}

    public func walk(
        root: URL,
        options: WalkOptions,
        visit: (WalkEntry) -> WalkDirective
    ) throws -> WalkSummary {
        // Identical root gate to the FileManager backend, and deliberately `lstat`-based: a
        // symlink pointed at a directory is not a walkable root, it is a symlink.
        let rootIdentity = try FileIdentity.read(at: root, volume: options.boundary)
        guard rootIdentity.kind == .directory else { throw WalkError.rootNotADirectory(root) }
        guard rootIdentity.deviceID == options.boundary.deviceID else {
            throw WalkError.rootOnDifferentVolume(root)
        }
        guard let rootPath = Self.physicalPath(of: root) else {
            throw WalkError.rootUnreadable(root, "path is not representable on this filesystem")
        }
        let rootURL = URL(fileURLWithPath: rootPath, isDirectory: true)

        let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferCapacity, alignment: 16)
        defer { buffer.deallocate() }

        var issues: [WalkIssue] = []
        var stopped = false
        var stack: [Frame] = []

        // An unreadable root is an issue, not a thrown error: `FileManager.enumerator` hands a
        // permission failure to its error handler and yields zero items, and a walk that fails
        // wholesale on one refused directory loses an entire scan. `rootUnreadable` stays
        // reserved for a root that cannot be enumerated at all.
        let rootRead = Self.readDirectory(path: rootPath, into: buffer)
        if let failure = rootRead.failure {
            issues.append(WalkIssue(url: rootURL, reason: .unreadable(failure)))
        }
        if !rootRead.entries.isEmpty {
            stack.append(Frame(path: rootPath, identity: rootIdentity, depth: 0, entries: rootRead.entries))
        }

        // One prepared denylist for the whole walk. The walk never crosses the root's volume, so
        // one comparison rule is exact — and the per-call `isDeniedLexically` convenience (volume
        // syscall + ancestor rebuild every time) benchmarked at ~92% of this walker's wall time.
        let denyList = options.honorsPolicyDenylist ? LexicalDenyList(volumeOf: rootURL) : nil

        traversal: while let top = stack.indices.last {
            guard stack[top].cursor < stack[top].entries.count else {
                stack.removeLast()
                continue
            }
            let raw = stack[top].entries[stack[top].cursor]
            stack[top].cursor += 1
            let parentPath = stack[top].path
            let parentIdentity = stack[top].identity
            let depth = stack[top].depth + 1

            guard let name = raw.name else {
                // No name means no path, so there is nothing to report the entry *as*. Blame
                // the directory instead of dropping it silently.
                issues.append(WalkIssue(
                    url: URL(fileURLWithPath: parentPath, isDirectory: true),
                    reason: .unreadable("directory entry returned without a name")
                ))
                continue
            }
            let path = parentPath == "/" ? "/" + name : parentPath + "/" + name

            // The directory hint decides whether the URL carries a trailing slash, which is how
            // `FileManager.enumerator` shapes the URLs it emits. `objtype` is always returned in
            // practice; when it is not, the kind comes from the fallback `lstat` below and the
            // URL is rebuilt. `.path` is unaffected either way, so the denylist check is safe to
            // run against the provisional URL.
            var url = URL(fileURLWithPath: path, isDirectory: raw.kind == .directory)

            // `path` is built from the realpath-resolved root plus literal child names, so it is
            // already in standardized form — the string-variant query skips the URL
            // re-standardization as well.
            if let denyList, denyList.isDenied(standardizedPath: path) {
                issues.append(WalkIssue(url: url, reason: .policyDenied))
                continue
            }

            let identity: FileIdentity
            let allocatedSize: Int64
            let accessTime: FileTimestamp
            if let complete = raw.completeIdentity(volume: options.boundary) {
                identity = complete.identity
                allocatedSize = complete.allocatedSize
                accessTime = complete.accessTime
            } else {
                let status: stat
                do {
                    status = try FileIdentity.lstatPath(url)
                } catch {
                    issues.append(WalkIssue(url: url, reason: .identityUnavailable(String(describing: error))))
                    continue
                }
                identity = FileIdentity(status, volume: options.boundary)
                // `totalFileAllocatedSize` resolves to nothing for a symlink or a directory on
                // APFS, so the FileManager backend lands on `st_blocks * 512` for both — and so
                // does this one, by the same arithmetic on the same `stat`.
                allocatedSize = FileIdentity.allocatedSize(of: status)
                accessTime = FileTimestamp(status.st_atimespec)
                if raw.kind != identity.kind {
                    url = URL(fileURLWithPath: path, isDirectory: identity.kind == .directory)
                }
            }

            guard identity.deviceID == options.boundary.deviceID else {
                // Mandatory `FTS_XDEV` equivalent: a nested mount is a different volume with a
                // different policy, never part of this walk.
                issues.append(WalkIssue(url: url, reason: .volumeBoundary))
                continue
            }

            // Checked after the identity and boundary gates, exactly where the FileManager
            // backend checks it, so an over-depth entry still contributes its denial, boundary
            // and stat-failure issues before it is dropped.
            if let maximum = options.maximumDepth, depth > maximum { continue }

            var directive = WalkDirective.continue
            if options.includesDirectories || identity.kind != .directory {
                directive = visit(WalkEntry(
                    url: url,
                    identity: identity,
                    parentIdentity: parentIdentity,
                    allocatedSize: allocatedSize,
                    contentAccessDate: Self.date(from: accessTime),
                    depth: depth
                ))
            }

            switch directive {
            case .continue: break
            case .skipDescendants: continue
            case .stop:
                stopped = true
                break traversal
            }

            guard identity.kind == .directory else { continue }
            let read = Self.readDirectory(path: path, into: buffer)
            if let failure = read.failure {
                issues.append(WalkIssue(url: url, reason: .unreadable(failure)))
            }
            if !read.entries.isEmpty {
                // The descriptor is already closed: `readDirectory` drains the whole directory
                // before returning, so exactly one directory descriptor is ever open and a tree
                // of any depth cannot exhaust the process file-descriptor limit.
                stack.append(Frame(path: path, identity: identity, depth: depth, entries: read.entries))
            }
        }

        return WalkSummary(issues: issues, stopped: stopped)
    }

    // MARK: - Traversal state

    /// One directory being walked. `entries` is the directory read to completion, so the frame
    /// owns no descriptor and the stack costs only memory.
    private struct Frame {
        let path: String
        let identity: FileIdentity
        /// Depth of this directory itself; the walk root is 0, so its children come out at 1
        /// and match `FileManager`'s `enumerator.level`.
        let depth: Int
        let entries: [RawEntry]
        var cursor: Int = 0
    }

    // MARK: - Directory reading

    private struct DirectoryRead {
        var entries: [RawEntry] = []
        /// Non-nil when the directory could not be opened, or could not be read to the end. Any
        /// entries already gathered are still returned: half a directory beats none of it.
        var failure: String?
    }

    private static func readDirectory(path: String, into buffer: UnsafeMutableRawPointer) -> DirectoryRead {
        var result = DirectoryRead()

        // `O_NOFOLLOW` is the descriptor-level half of "never follow a symlink": even if the
        // name we were handed is re-pointed at a symlink between the attribute read and this
        // open, the open fails rather than walking somewhere else.
        let descriptor = path.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            result.failure = String(cString: strerror(errno))
            return result
        }
        defer { close(descriptor) }

        var request = attributeRequest()
        while true {
            // No `FSOPT_NOFOLLOW`: `getattrlistbulk` reports on the directory entries themselves
            // and never resolves a symlink among them (a link comes back as `VLNK` carrying its
            // own `st_size`, which the parity fixture pins down), and the option is not part of
            // this call's documented set. The `O_NOFOLLOW` on the open above is the guarantee
            // that matters, because it is the one covering the descend.
            let count = getattrlistbulk(descriptor, &request, buffer, bufferCapacity, 0)
            if count < 0 {
                result.failure = String(cString: strerror(errno))
                return result
            }
            if count == 0 { return result }

            var consumed = 0
            for _ in 0..<count {
                // Every offset the parse below trusts is derived from this length, so it is
                // bounded against the buffer here rather than anywhere deeper: a zero length
                // would spin this loop forever and an oversized one would read off the end.
                let entry = UnsafeRawPointer(buffer).advanced(by: consumed)
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                guard length >= MemoryLayout<UInt32>.size, consumed + length <= bufferCapacity else {
                    result.failure = "malformed attribute buffer"
                    return result
                }
                result.entries.append(parse(entry: entry, length: length))
                consumed += length
            }
        }
    }

    private static func attributeRequest() -> attrlist {
        var request = attrlist()
        request.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        request.commonattr = Attr.returnedAttrs | Attr.error | Attr.name | Attr.deviceID
            | Attr.objectType | Attr.modificationTime | Attr.changeTime | Attr.accessTime
            | Attr.ownerID | Attr.flags | Attr.fileID
        // Deliberately no `ATTR_DIR_*`: the only directory attribute worth having would be a
        // link count, and `ATTR_DIR_LINKCOUNT` is not `st_nlink` (it reports 1 for an APFS
        // directory whose `st_nlink` is 2 or more). Directories take the `lstat` fallback, so
        // asking for attributes that would only be discarded wastes kernel work per entry.
        request.fileattr = Attr.fileLinkCount | Attr.fileAllocatedSize | Attr.fileDataLength
        return request
    }

    // MARK: - Attribute parsing

    /// Attribute bits, spelled out rather than imported, because the parse below depends on
    /// their *numeric order*: `getattrlistbulk` packs each group's fields in ascending bit order
    /// with no padding, and only the fields the per-entry returned mask actually claims.
    private enum Attr {
        static let name: UInt32             = 0x0000_0001
        static let deviceID: UInt32         = 0x0000_0002
        static let objectType: UInt32       = 0x0000_0008
        static let modificationTime: UInt32 = 0x0000_0400
        static let changeTime: UInt32       = 0x0000_0800
        static let accessTime: UInt32       = 0x0000_1000
        static let ownerID: UInt32          = 0x0000_8000
        static let flags: UInt32            = 0x0004_0000
        static let fileID: UInt32           = 0x0200_0000
        static let error: UInt32            = 0x2000_0000
        /// Packed first, immediately after the entry length, regardless of its bit position.
        static let returnedAttrs: UInt32    = 0x8000_0000

        static let fileLinkCount: UInt32     = 0x0000_0001
        static let fileAllocatedSize: UInt32 = 0x0000_0004
        /// `st_size` for a regular file and for a symlink. Deliberately *not*
        /// `ATTR_FILE_TOTALSIZE`, which adds the resource fork: a file carrying a 64-byte
        /// resource fork reports a total size of 164 where `stat` reports 100, and identity
        /// revalidation compares `size` for equality.
        static let fileDataLength: UInt32    = 0x0000_0200
    }

    /// `vtype` values from `sys/vnode.h`. Only the three that map to a real ``FileKind`` matter;
    /// everything else is `.other`, which takes the `lstat` fallback anyway.
    private enum ObjectType {
        static let regular: UInt32 = 1
        static let directory: UInt32 = 2
        static let symbolicLink: UInt32 = 5
    }

    /// One directory entry as the kernel handed it over. Optional fields are absent when the
    /// per-entry returned mask did not claim them, which is what drives the `lstat` fallback.
    private struct RawEntry {
        var name: String?
        var kind: FileKind = .other
        var error: UInt32 = 0
        var deviceID: Int32?
        var objectType: UInt32?
        var modificationTime: timespec?
        var changeTime: timespec?
        var accessTime: timespec?
        var ownerID: UInt32?
        var flags: UInt32?
        var fileID: UInt64?
        var linkCount: UInt32?
        var allocatedSize: Int64?
        var dataLength: Int64?

        /// A ``FileIdentity`` built purely from bulk attributes, or `nil` when this entry has to
        /// be `lstat`ed instead.
        ///
        /// Only regular files qualify. Directories need `st_nlink`, which no bulk attribute
        /// reports faithfully. Symlinks and everything else need `st_blocks * 512` for their
        /// allocated size, which is what the FileManager backend produces for them and which no
        /// bulk attribute is guaranteed to reproduce across filesystems. Regular files are the
        /// overwhelming majority of any real tree, so the fallback costs one extra syscall on a
        /// small minority of entries while the common case stays at zero.
        func completeIdentity(
            volume: VolumeIdentity
        ) -> (identity: FileIdentity, allocatedSize: Int64, accessTime: FileTimestamp)? {
            guard error == 0, objectType == ObjectType.regular else { return nil }
            guard let deviceID, let modificationTime, let changeTime, let accessTime,
                  let ownerID, let flags, let fileID, let linkCount,
                  let allocatedSize, let dataLength
            else { return nil }

            let identity = FileIdentity(
                deviceID: UInt64(bitPattern: Int64(deviceID)),
                inode: fileID,
                volume: volume,
                kind: .file,
                linkCount: Int(linkCount),
                modification: FileTimestamp(modificationTime),
                statusChange: FileTimestamp(changeTime),
                size: dataLength,
                flags: flags,
                ownerUserID: ownerID
            )
            return (identity, allocatedSize, FileTimestamp(accessTime))
        }
    }

    private static func parse(entry: UnsafeRawPointer, length: Int) -> RawEntry {
        var raw = RawEntry()
        var cursor = Cursor(base: entry, offset: MemoryLayout<UInt32>.size, limit: length)

        // `attribute_set_t`: five `attrgroup_t` in the order common, volume, directory, file,
        // fork. Requesting `ATTR_CMN_RETURNED_ATTRS` is mandatory for `getattrlistbulk`, and it
        // is what makes the rest of this parse safe: a field absent from the mask was never
        // written to the buffer, so skipping it keeps every later offset correct.
        guard let common = cursor.take(UInt32.self) else { return raw }
        _ = cursor.take(UInt32.self)
        _ = cursor.take(UInt32.self)
        guard let file = cursor.take(UInt32.self) else { return raw }
        _ = cursor.take(UInt32.self)

        if common & Attr.name != 0 { raw.name = cursor.takeName() }
        if common & Attr.deviceID != 0 { raw.deviceID = cursor.take(Int32.self) }
        if common & Attr.objectType != 0 { raw.objectType = cursor.take(UInt32.self) }
        if common & Attr.modificationTime != 0 { raw.modificationTime = cursor.take(timespec.self) }
        if common & Attr.changeTime != 0 { raw.changeTime = cursor.take(timespec.self) }
        if common & Attr.accessTime != 0 { raw.accessTime = cursor.take(timespec.self) }
        if common & Attr.ownerID != 0 { raw.ownerID = cursor.take(UInt32.self) }
        if common & Attr.flags != 0 { raw.flags = cursor.take(UInt32.self) }
        if common & Attr.fileID != 0 { raw.fileID = cursor.take(UInt64.self) }
        // Only ever returned when the filesystem failed on this one entry, in which case
        // nothing past the name is trustworthy — hence the `error == 0` gate on the bulk path.
        if common & Attr.error != 0 { raw.error = cursor.take(UInt32.self) ?? 0 }

        if file & Attr.fileLinkCount != 0 { raw.linkCount = cursor.take(UInt32.self) }
        if file & Attr.fileAllocatedSize != 0 { raw.allocatedSize = cursor.take(Int64.self) }
        if file & Attr.fileDataLength != 0 { raw.dataLength = cursor.take(Int64.self) }

        raw.kind = switch raw.objectType {
        case ObjectType.regular: .file
        case ObjectType.directory: .directory
        case ObjectType.symbolicLink: .symbolicLink
        default: .other
        }
        return raw
    }

    /// Bounds-checked, alignment-free reader over one entry's attribute block. The kernel packs
    /// attributes back to back with no padding, so an 8-byte field routinely lands on a 4-byte
    /// boundary and every read has to be an unaligned one.
    private struct Cursor {
        let base: UnsafeRawPointer
        var offset: Int
        let limit: Int

        mutating func take<T>(_ type: T.Type) -> T? {
            let size = MemoryLayout<T>.size
            guard offset >= 0, offset + size <= limit else { return nil }
            let value = base.loadUnaligned(fromByteOffset: offset, as: T.self)
            offset += size
            return value
        }

        /// `ATTR_CMN_NAME` is an `attrreference_t`: an offset (relative to the reference itself)
        /// and a length, pointing into the variable-length region that follows the fixed fields.
        mutating func takeName() -> String? {
            let reference = offset
            guard let dataOffset = take(Int32.self), let dataLength = take(UInt32.self) else { return nil }
            let start = reference + Int(dataOffset)
            let count = Int(dataLength)
            guard count > 0, start >= 0, start + count <= limit else { return nil }
            let bytes = UnsafeRawBufferPointer(start: base.advanced(by: start), count: count)
            let text = bytes.prefix { $0 != 0 }
            guard !text.isEmpty else { return nil }
            return String(decoding: text, as: UTF8.self)
        }
    }

    // MARK: - Conversions

    /// Seconds between the Unix epoch and `Date`'s 2001 reference date.
    private static let referenceDateOffset: Double = 978_307_200

    /// Rebuilds the `Date` Foundation's `contentAccessDateKey` produces from the same `atime`.
    ///
    /// The order of operations is load-bearing, not pedantry: `Date` stores a `Double` of
    /// seconds since 2001, and folding the epoch into the whole seconds *before* adding the
    /// fraction is what Foundation does. Doing it the other way round (building from
    /// `timeIntervalSince1970`) rounds differently and disagrees with Foundation on roughly half
    /// of all timestamps, by one unit in the last place.
    static func date(from timestamp: FileTimestamp) -> Date {
        Date(timeIntervalSinceReferenceDate:
            Double(timestamp.seconds) - referenceDateOffset + Double(timestamp.nanoseconds) / 1_000_000_000)
    }

    /// Physical path of the walk root, with every symlinked ancestor component resolved.
    ///
    /// `FileManager.enumerator` emits fully resolved paths (a root under `/var/folders` comes
    /// back as `/private/var/folders`), and the emitted URL is what downstream policy checks and
    /// deletions are pointed at, so the two backends must agree on it. Resolving the root once
    /// per walk is enough: the traversal never follows a symlink, so every path built beneath it
    /// is physical by construction.
    private static func physicalPath(of url: URL) -> String? {
        url.withUnsafeFileSystemRepresentation { pointer -> String? in
            guard let pointer else { return nil }
            var storage = [CChar](repeating: 0, count: Int(PATH_MAX))
            let resolved = storage.withUnsafeMutableBufferPointer { realpath(pointer, $0.baseAddress) }
            guard let resolved else { return String(cString: pointer) }
            return String(cString: resolved)
        }
    }
}
