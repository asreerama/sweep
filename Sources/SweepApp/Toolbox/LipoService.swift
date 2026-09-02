import Foundation

// MARK: - Mach-O fat-header parsing (pure; unit-tested against synthetic `Data` in
// Tests/SweepAppTests/LipoLogicTests.swift)

/// One architecture slice inside a fat (universal) Mach-O file, exactly as recorded in its
/// on-disk `fat_arch`/`fat_arch_64` table entry: which CPU it targets, and the byte range of
/// that slice within the file. `offset` is read but unused by anything in this module today —
/// thinning goes through `/usr/bin/lipo` rather than slicing the file by hand — kept anyway
/// because it costs nothing to carry and is the other half of what `fat_arch` actually records.
struct MachOFatSlice: Sendable, Equatable {
    let cpuType: UInt32
    let offset: UInt64
    let size: UInt64
}

/// What `MachOFatParser.parse(_:)` found at the front of a file.
///
/// `.thin` carries the one CPU type a single-architecture Mach-O declares in its own
/// `mach_header`/`mach_header_64` — cheap to read (it sits at byte 4, right after the magic,
/// exactly like a fat header's slice table starts right after its own magic+count) and the only
/// way this module can tell an already-native binary (nothing to do) apart from a Rosetta-only,
/// Intel-only one (nothing this Mac can do *for* it) without spawning `lipo -info`.
enum MachOKind: Sendable, Equatable {
    case fat(slices: [MachOFatSlice])
    case thin(cpuType: UInt32)
    /// Not a Mach-O this parser recognizes at all: a shell-script "executable" wrapper (some
    /// apps ship one as `Contents/MacOS/AppName`), a truncated read, or outright garbage. Treated
    /// identically to `.thin` by every caller in this file — skip, no opinion — so collapsing the
    /// two into one case would only save an enum arm, not a decision anywhere.
    case notMachO
}

/// Reads the fat-binary / Mach-O header directly from a `Data` prefix, in pure Swift, with no
/// `lipo -info` process spawn.
///
/// Spawning a helper process once per installed app to ask "is this fat?" is exactly the kind of
/// per-item fork this codebase has already had to remove for latency once: see
/// `Packages/SweepUninstall/Sources/SweepUninstall/PrefetchedReceipts.swift`'s doc comment
/// (~4.4 s of wall time for 49 *serial* `pkgutil` spawns, a cheaper tool than `lipo`, and
/// measured *concurrent* spawns of it at 10x worse — the receipts store itself serializes
/// contending callers). A few dozen apps' worth of `lipo -info` forks would cost the same class
/// of latency for a screen whose whole point is "open it and immediately see the answer."
/// Parsing ~32-100 header bytes per file, by contrast, is microseconds and touches only the
/// first few KB of each executable — never the full (sometimes multi-hundred-MB) file.
///
/// A fat header's `magic`/`nfat_arch` and its `fat_arch`/`fat_arch_64` entries are always written
/// in ONE consistent byte order for a given file — but which order depends on which of the four
/// `<mach-o/fat.h>` magics is actually on disk: `FAT_MAGIC`/`FAT_MAGIC_64` (0xcafebabe /
/// 0xcafebabf) mean big-endian fields (the case for every fat binary this parser has ever seen
/// produced by Apple's own toolchain); `FAT_CIGAM`/`FAT_CIGAM_64` (0xbebafeca / 0xbfbafeca) are
/// the literal byte-for-byte reverse of those two and mean the entries that follow are
/// little-endian instead. This parser reads the four magic bytes as a literal byte sequence (not
/// as a value pre-converted through the host's own endianness) and picks big- or little-endian
/// field decoding from which of the four sequences it finds, so a hostile or synthetic
/// byte-swapped fixture is parsed correctly rather than silently misread as garbage.
enum MachOFatParser {
    /// How much of a file this module ever reads to answer "is it fat, and if so how big is each
    /// slice?" — generous enough to cover a fat header with far more slices than any real
    /// universal binary carries (`maxArchCount` below), never the whole executable.
    static let headerReadLimit = 65_536

    /// Slice-count sanity ceiling. A real universal binary on this Mac carries 2-4 slices; this
    /// exists purely so a corrupted file or an adversarial fixture claiming, say, 4 billion
    /// `nfat_arch` entries fails the parse cleanly instead of this function trying to read (or
    /// allocate space for) entries that were never in the data to begin with.
    static let maxArchCount: UInt32 = 32

    static func parse(_ data: Data) -> MachOKind {
        let bytes = [UInt8](data.prefix(headerReadLimit))
        guard bytes.count >= 8 else { return .notMachO }
        let magic = Array(bytes.prefix(4))

        // Byte sequences transcribed directly from <mach-o/fat.h> and <mach-o/loader.h> — see
        // the type's doc comment for why these are matched as literal bytes, not as a UInt32
        // decoded through the host's own (little-endian, on every Mac this app runs on) order.
        switch magic {
        case [0xCA, 0xFE, 0xBA, 0xBE]: return parseFatArchTable(bytes, is64: false, bigEndian: true)   // FAT_MAGIC
        case [0xBE, 0xBA, 0xFE, 0xCA]: return parseFatArchTable(bytes, is64: false, bigEndian: false)  // FAT_CIGAM
        case [0xCA, 0xFE, 0xBA, 0xBF]: return parseFatArchTable(bytes, is64: true, bigEndian: true)    // FAT_MAGIC_64
        case [0xBF, 0xBA, 0xFE, 0xCA]: return parseFatArchTable(bytes, is64: true, bigEndian: false)   // FAT_CIGAM_64
        case [0xFE, 0xED, 0xFA, 0xCE]: return parseThinHeader(bytes, bigEndian: true)                  // MH_MAGIC
        case [0xCE, 0xFA, 0xED, 0xFE]: return parseThinHeader(bytes, bigEndian: false)                 // MH_CIGAM
        case [0xFE, 0xED, 0xFA, 0xCF]: return parseThinHeader(bytes, bigEndian: true)                  // MH_MAGIC_64
        case [0xCF, 0xFA, 0xED, 0xFE]: return parseThinHeader(bytes, bigEndian: false)                 // MH_CIGAM_64
        default:
            return .notMachO
        }
    }

    /// `cputype` sits immediately after the 4-byte magic in both `mach_header` and
    /// `mach_header_64` — identical offset in both, so there is no need to also determine 32- vs
    /// 64-bit here the way the fat path must.
    private static func parseThinHeader(_ bytes: [UInt8], bigEndian: Bool) -> MachOKind {
        guard let cpuType = readUInt32(bytes, at: 4, bigEndian: bigEndian) else { return .notMachO }
        return .thin(cpuType: cpuType)
    }

    /// `fat_header` is `{ magic: uint32, nfat_arch: uint32 }` (8 bytes); each following entry is
    /// `fat_arch` (20 bytes: cputype, cpusubtype, offset, size, align — all `uint32`) or
    /// `fat_arch_64` (32 bytes: the same fields, with `offset`/`size` widened to `uint64`).
    private static func parseFatArchTable(_ bytes: [UInt8], is64: Bool, bigEndian: Bool) -> MachOKind {
        guard let archCount = readUInt32(bytes, at: 4, bigEndian: bigEndian), archCount <= maxArchCount else {
            return .notMachO
        }
        let entrySize = is64 ? 32 : 20
        var slices: [MachOFatSlice] = []
        slices.reserveCapacity(Int(archCount))
        for index in 0..<Int(archCount) {
            let entryOffset = 8 + index * entrySize
            guard let cpuType = readUInt32(bytes, at: entryOffset, bigEndian: bigEndian) else { return .notMachO }
            let sliceOffset: UInt64?
            let sliceSize: UInt64?
            if is64 {
                sliceOffset = readUInt64(bytes, at: entryOffset + 8, bigEndian: bigEndian)
                sliceSize = readUInt64(bytes, at: entryOffset + 16, bigEndian: bigEndian)
            } else {
                sliceOffset = readUInt32(bytes, at: entryOffset + 8, bigEndian: bigEndian).map(UInt64.init)
                sliceSize = readUInt32(bytes, at: entryOffset + 12, bigEndian: bigEndian).map(UInt64.init)
            }
            guard let offset = sliceOffset, let size = sliceSize else { return .notMachO }
            slices.append(MachOFatSlice(cpuType: cpuType, offset: offset, size: size))
        }
        return .fat(slices: slices)
    }

    /// Reads 4 bytes at `offset` in file order and assembles them into a `UInt32` per
    /// `bigEndian`. Never touches the host's own native byte order — the shifts below are
    /// explicit either way — which is the whole point: this must give the same answer on any
    /// host, not just a little-endian one.
    private static func readUInt32(_ bytes: [UInt8], at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= bytes.count else { return nil }
        let b0 = UInt32(bytes[offset]), b1 = UInt32(bytes[offset + 1])
        let b2 = UInt32(bytes[offset + 2]), b3 = UInt32(bytes[offset + 3])
        return bigEndian ? (b0 << 24 | b1 << 16 | b2 << 8 | b3) : (b3 << 24 | b2 << 16 | b1 << 8 | b0)
    }

    private static func readUInt64(_ bytes: [UInt8], at offset: Int, bigEndian: Bool) -> UInt64? {
        guard offset >= 0, offset + 8 <= bytes.count else { return nil }
        let ordered = bigEndian ? Array(bytes[offset..<offset + 8]) : Array(bytes[offset..<offset + 8].reversed())
        var value: UInt64 = 0
        for byte in ordered { value = (value << 8) | UInt64(byte) }
        return value
    }
}

// MARK: - Architecture identification (pure)

/// The two CPU types this module has any reason to name. Values transcribed from
/// `<mach/machine.h>`: `CPU_TYPE_ARM64` is `CPU_TYPE_ARM (12) | CPU_ARCH_ABI64 (0x01000000)`;
/// `CPU_TYPE_X86_64` is `CPU_TYPE_I386 (7) | CPU_ARCH_ABI64`.
enum LipoArch {
    static let arm64: UInt32 = 0x0100_000c
    static let x86_64: UInt32 = 0x0100_0007

    static func name(for cpuType: UInt32) -> String {
        switch cpuType {
        case arm64: "arm64"
        case x86_64: "x86_64"
        default: "cpu 0x" + String(cpuType, radix: 16)
        }
    }
}

// MARK: - Savings computation (pure; unit-tested)

/// One fat Mach-O file this module found, plus what it costs on disk today — the minimal shape
/// `LipoSavings`/`LipoSummary` need, decoupled from any real file so both are testable with
/// synthetic values.
struct LipoFatFileMeasurement: Sendable, Equatable {
    let allocatedSize: Int64
    let slices: [MachOFatSlice]
}

enum LipoSavings {
    /// Bytes a `lipo -thin arm64` would free from one fat file: today's on-disk size minus the
    /// arm64 slice's own recorded size.
    ///
    /// **This is an approximation, stated plainly rather than silently assumed**: a fat file pads
    /// each slice to an alignment boundary (`fat_arch.align`), and the offset the *last* slice
    /// starts at is not generally "everything before it, contiguously" — the true byte cost this
    /// module would need to subtract exactly is the union of every *other* slice's aligned
    /// footprint, not simply "total minus the one slice we're keeping." Measuring that precisely
    /// would mean either reimplementing `lipo`'s own layout math or actually running the thin and
    /// diffing before/after sizes (which `LipoThinningService.thin` does, for the number the UI
    /// shows *after* a real thin). This estimate is what the discovery/results list can show
    /// *before* running anything, and it never overstates the user's benefit: the true freed
    /// amount from a real `lipo -thin` is always this value or a little more (padding it drops
    /// besides), never less.
    ///
    /// Returns `nil` when `file` has no arm64 slice at all — nothing this app can thin it to.
    static func wastedBytes(_ file: LipoFatFileMeasurement, nativeCPUType: UInt32 = LipoArch.arm64) -> Int64? {
        guard let native = file.slices.first(where: { $0.cpuType == nativeCPUType }) else { return nil }
        return max(0, file.allocatedSize - Int64(native.size))
    }
}

/// What one universal app is worth listing as, once its main executable and every other fat
/// Mach-O in its bundle have been measured.
struct LipoAppMeasurement: Sendable, Equatable {
    /// Display order: the native architecture first (`"arm64"`), then every other architecture
    /// found across the app's binaries, in first-seen order. Feeds the row's
    /// `"Universal — arm64 + x86_64"` summary text directly.
    let architectures: [String]
    let savingsBytes: Int64
}

enum LipoSummary {
    /// Combines the main executable's own slice table with every other fat Mach-O the bundle
    /// walk found (frameworks, helper tools) into one app-level measurement.
    ///
    /// Gates on the MAIN executable alone for "is this app a thinning candidate at all": it must
    /// be fat (more than one slice) and carry an arm64 slice. A framework or helper elsewhere in
    /// the bundle that happens to be fat-with-no-arm64 (vanishingly rare, but not impossible for
    /// a stray third-party dependency) is simply excluded from the savings sum rather than
    /// disqualifying the whole app — one odd helper binary is not a reason to hide an otherwise
    /// straightforward multi-hundred-MB win on the main executable.
    static func summarize(
        mainSlices: [MachOFatSlice],
        mainAllocatedSize: Int64,
        otherFiles: [LipoFatFileMeasurement],
        nativeCPUType: UInt32 = LipoArch.arm64
    ) -> LipoAppMeasurement? {
        guard mainSlices.count > 1, mainSlices.contains(where: { $0.cpuType == nativeCPUType }) else { return nil }

        var savings = LipoSavings.wastedBytes(
            LipoFatFileMeasurement(allocatedSize: mainAllocatedSize, slices: mainSlices),
            nativeCPUType: nativeCPUType
        ) ?? 0

        var architectureOrder: [UInt32] = []
        for slice in mainSlices where !architectureOrder.contains(slice.cpuType) {
            architectureOrder.append(slice.cpuType)
        }
        for file in otherFiles {
            if let waste = LipoSavings.wastedBytes(file, nativeCPUType: nativeCPUType) {
                savings += waste
            }
            for slice in file.slices where !architectureOrder.contains(slice.cpuType) {
                architectureOrder.append(slice.cpuType)
            }
        }

        // Nothing fat enough to be worth a row (e.g. two arm64-family slices with no real
        // Intel payload — see the cpusubtype caveat on `LipoArch`/`architectureOrder` above).
        guard savings > 0 else { return nil }

        let ordered = [nativeCPUType] + architectureOrder.filter { $0 != nativeCPUType }
        return LipoAppMeasurement(architectures: ordered.map(LipoArch.name(for:)), savingsBytes: savings)
    }
}

// MARK: - Protection / running predicate (pure; unit-tested)

/// "Never touch this" and "quit first" — the two disqualifiers PLAN's Toolbox contract calls for
/// on any module that mutates an installed app.
///
/// Deliberately re-derived here rather than importing `SweepApp/Uninstall/UninstallLogic
/// .isProtected`: that function (same target, `internal`, reachable) also consults a
/// `SweepPolicy` lexical denylist and an injected "is this Sweep itself" bundle identifier — both
/// aimed at the Uninstaller's much larger blast radius (arbitrary leftover file deletion). Lipo
/// only ever mutates a `.app` bundle's own binaries in place; the simplest honest check the task
/// spec calls for — Apple's own system location or bundle identifier — is the whole policy this
/// module needs, and keeping it here means `LipoLogicTests` can exercise it without pulling in
/// `SweepPolicy`.
enum LipoProtection {
    /// A bundle counts as protected when it resolves to somewhere under `/System`, or its bundle
    /// identifier is Apple's own (`com.apple.*`). Not a code-signing trust chain, not a
    /// notarization check — the same two signals this app's own Uninstaller and PearCleaner both
    /// settle for, because a universal, user-installed app is never going to be sitting at either
    /// of those two places to begin with.
    static func isProtected(bundlePath: URL, bundleIdentifier: String?) -> Bool {
        if bundlePath.resolvingSymlinksInPath().path.hasPrefix("/System/") { return true }
        if let bundleIdentifier, bundleIdentifier.hasPrefix("com.apple.") { return true }
        return false
    }

    /// Whether `bundlePath` matches one of the bundle paths in `runningBundlePaths` — plain-data
    /// membership rather than an `NSWorkspace` query, so this stays pure and testable directly.
    /// `LipoModel` is the one real caller and supplies a freshly-read
    /// `NSWorkspace.shared.runningApplications` set at the point it actually matters (right
    /// before enabling/disabling the Thin button and again immediately before the mutation
    /// itself) — matching `RunningAppChecker`'s live-query-every-time contract in the Uninstaller
    /// rather than a snapshot that could go stale while the screen sits open.
    static func isRunning(bundlePath: URL, runningBundlePaths: Set<String>) -> Bool {
        runningBundlePaths.contains(bundlePath.resolvingSymlinksInPath().path)
    }
}

// MARK: - Discovery (impure: FileManager reads, no writes)

/// One universal app this module found, cheap enough to hold in memory for the lifetime of the
/// results list.
struct LipoAppRow: Identifiable, Sendable, Equatable {
    /// The bundle's own path — stable across a session, and the reveal/thin target.
    var id: String { bundlePath.path }
    let name: String
    let bundlePath: URL
    let bundleIdentifier: String?
    let architectures: [String]
    let savingsBytes: Int64
    let isProtected: Bool
}

/// Read-only `.app` bundle enumeration under `/Applications` and `~/Applications`.
///
/// Mirrors the shape of `SweepUninstall.AppInventory.scan` (one level deep past the two roots —
/// a vendor folder like `/Applications/Utilities` is expanded once, a `.app` itself never
/// descended into) without depending on that package's internals, which this module has no need
/// for: it only ever wants bundle URLs, not the signing-info read and cryptex-hidden-symlink
/// handling `AppInventory` also does for every entry. The task spec's own call: "`FileManager
/// .contentsOfDirectory` is fine" — `AppInventory`'s extra rigor exists for macOS-system-app edge
/// cases (Safari's dot-less hidden cryptex symlink, most notably) that can never appear in
/// `/Applications` proper and would be excluded by `LipoProtection.isProtected` even if they did.
enum LipoDiscovery {
    static func defaultApplicationDirectories(fileManager: FileManager = .default) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications"),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
        ]
    }

    static func discoverAppBundles(directories: [URL], fileManager: FileManager = .default) -> [URL] {
        var result: [URL] = []
        var seenPaths = Set<String>()

        func consider(_ entry: URL) {
            guard entry.pathExtension == "app" else { return }
            let standardized = entry.standardizedFileURL.path
            guard seenPaths.insert(standardized).inserted else { return }
            result.append(entry.standardizedFileURL)
        }

        for directory in directories {
            guard let entries = try? fileManager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
            ) else { continue }

            for entry in entries {
                if entry.pathExtension == "app" {
                    consider(entry)
                    continue
                }
                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(atPath: entry.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                    continue
                }
                guard let nested = try? fileManager.contentsOfDirectory(
                    at: entry, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }
                for nestedEntry in nested { consider(nestedEntry) }
            }
        }
        return result
    }
}

// MARK: - Bundle candidate enumeration (impure: FileManager reads)

/// Every file this module will ever consider thinning inside one `.app` bundle: the main
/// executable, every other file directly under `Contents/MacOS` (helper tools some apps embed
/// there — an updater, an XPC service shelled out as a plain binary), and each framework's own
/// versioned binary under `Contents/Frameworks/*.framework/Versions/*/`.
///
/// Enumeration only, "conservatively" per the task spec: this never opens a file for anything
/// beyond the small header read `LipoFileReader.machOKind(at:)` does, and every candidate this
/// returns still has to pass that parse's `.fat` check before either the discovery estimate or
/// the real thin does anything with it. The exact same candidate list is used for both the
/// pre-flight savings estimate (`LipoEngine.scan`) and the real mutation
/// (`LipoThinningService.thin`) — one enumeration, so the number promised in the confirm dialog
/// and the files actually touched can never quietly diverge.
enum LipoBundleWalker {
    static func machOCandidates(bundlePath: URL, mainExecutable: URL?, fileManager: FileManager = .default) -> [URL] {
        var candidates: [URL] = []
        var seenPaths = Set<String>()

        func add(_ url: URL) {
            let standardized = url.standardizedFileURL.path
            guard seenPaths.insert(standardized).inserted else { return }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
                return
            }
            candidates.append(url.standardizedFileURL)
        }

        if let mainExecutable { add(mainExecutable) }

        let macOSDirectory = bundlePath.appending(path: "Contents/MacOS")
        if let entries = try? fileManager.contentsOfDirectory(
            at: macOSDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for entry in entries { add(entry) }
        }

        let frameworksDirectory = bundlePath.appending(path: "Contents/Frameworks")
        if let frameworks = try? fileManager.contentsOfDirectory(
            at: frameworksDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) {
            for framework in frameworks where framework.pathExtension == "framework" {
                let versionsDirectory = framework.appending(path: "Versions")
                guard let versions = try? fileManager.contentsOfDirectory(
                    at: versionsDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
                ) else { continue }
                for version in versions {
                    // The framework's own binary conventionally shares the framework's stem name
                    // (`Foo.framework/Versions/A/Foo`) — the same assumption `Bundle`'s own
                    // framework-loading machinery makes, not a Sweep invention.
                    let binaryName = framework.deletingPathExtension().lastPathComponent
                    add(version.appending(path: binaryName))
                }
            }
        }
        return candidates
    }
}

// MARK: - File reads (impure: reads only, never writes)

enum LipoFileReader {
    static func machOKind(at url: URL) -> MachOKind {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .notMachO }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: MachOFatParser.headerReadLimit), !data.isEmpty else {
            return .notMachO
        }
        return MachOFatParser.parse(data)
    }

    /// Allocated (on-disk) size, matching every other size this app shows — PLAN Appendix B's
    /// `totalFileAllocatedSizeKey` convention, not the logical byte count.
    static func allocatedSize(at url: URL) -> Int64 {
        let value = try? url.resourceValues(forKeys: [.fileAllocatedSizeKey]).fileAllocatedSize
        return Int64((value ?? nil) ?? 0)
    }
}

// MARK: - Scan orchestration (impure: the read-only half of this module)

struct LipoScanOutcome: Sendable {
    let rows: [LipoAppRow]
    /// Apps whose main executable is thin (not fat at all) and NOT arm64 — a Rosetta-only,
    /// Intel-only app. Nothing here can be thinned further (there is no arm64 slice to keep), so
    /// these never appear as a row; this count is the honest accounting for where they went,
    /// per the task spec's "be honest in copy" — surfaced as a footnote rather than silently
    /// vanishing the way a thin-and-native app does.
    let intelOnlyCount: Int
}

enum LipoEngine {
    static func scan(
        directories: [URL] = LipoDiscovery.defaultApplicationDirectories(),
        fileManager: FileManager = .default
    ) -> LipoScanOutcome {
        let bundlePaths = LipoDiscovery.discoverAppBundles(directories: directories, fileManager: fileManager)
        var rows: [LipoAppRow] = []
        var intelOnlyCount = 0

        for bundlePath in bundlePaths {
            guard let bundle = Bundle(url: bundlePath), let executableURL = bundle.executableURL else { continue }
            let mainKind = LipoFileReader.machOKind(at: executableURL)

            let mainSlices: [MachOFatSlice]
            switch mainKind {
            case .fat(let slices):
                mainSlices = slices
            case .thin(let cpuType):
                if cpuType != LipoArch.arm64 { intelOnlyCount += 1 }
                continue // already single-architecture either way: native (nothing to do) or Intel-only (nothing this Mac can do)
            case .notMachO:
                continue // a script wrapper, or unreadable — no opinion
            }

            let allCandidates = LipoBundleWalker.machOCandidates(
                bundlePath: bundlePath, mainExecutable: executableURL, fileManager: fileManager
            )
            let otherMeasurements: [LipoFatFileMeasurement] = allCandidates
                .filter { $0.standardizedFileURL.path != executableURL.standardizedFileURL.path }
                .compactMap { url in
                    guard case .fat(let slices) = LipoFileReader.machOKind(at: url) else { return nil }
                    return LipoFatFileMeasurement(allocatedSize: LipoFileReader.allocatedSize(at: url), slices: slices)
                }

            guard let measurement = LipoSummary.summarize(
                mainSlices: mainSlices,
                mainAllocatedSize: LipoFileReader.allocatedSize(at: executableURL),
                otherFiles: otherMeasurements
            ) else { continue }

            let name = (bundle.infoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.infoDictionary?["CFBundleName"] as? String)
                ?? bundlePath.deletingPathExtension().lastPathComponent

            rows.append(LipoAppRow(
                name: name,
                bundlePath: bundlePath,
                bundleIdentifier: bundle.bundleIdentifier,
                architectures: measurement.architectures,
                savingsBytes: measurement.savingsBytes,
                isProtected: LipoProtection.isProtected(bundlePath: bundlePath, bundleIdentifier: bundle.bundleIdentifier)
            ))
        }

        rows.sort { $0.savingsBytes > $1.savingsBytes }
        return LipoScanOutcome(rows: rows, intelOnlyCount: intelOnlyCount)
    }
}

// MARK: - Thinning (the mutation: process spawns + an in-place file replace)

/// One app's finished (or failed) thin attempt.
struct LipoThinOutcome: Sendable, Equatable {
    let succeeded: Bool
    /// Bytes actually freed, measured from real before/after file sizes — never the
    /// `LipoSavings` estimate, which this action supersedes with ground truth the moment it runs.
    let freedBytes: Int64
    /// Always populated: the success caption ("Freed 412 MB") or an honest failure reason,
    /// surfaced in the row's state chip / tooltip either way.
    let message: String
}

/// Runs the one destructive action this module offers: thin every fat Mach-O in one app bundle
/// down to arm64, then re-sign the bundle so macOS will still launch it.
///
/// **Irreversible.** There is no Trash copy of the removed Intel slice — `LipoScreen`'s confirm
/// dialog is the only safeguard, which is why it states the consequence plainly before this ever
/// runs (task spec). Every step below is sequenced so a failure partway through leaves the
/// clearest possible trail in `LipoThinOutcome.message` rather than a half-mutated bundle with no
/// explanation.
enum LipoThinningService {
    static func thin(appAt bundlePath: URL, fileManager: FileManager = .default) async -> LipoThinOutcome {
        guard let bundle = Bundle(url: bundlePath), let executableURL = bundle.executableURL else {
            return LipoThinOutcome(succeeded: false, freedBytes: 0, message: "Could not read this app's executable.")
        }

        let candidates = LipoBundleWalker.machOCandidates(
            bundlePath: bundlePath, mainExecutable: executableURL, fileManager: fileManager
        )

        var freedBytes: Int64 = 0
        var thinnedAny = false
        var fileFailures: [String] = []

        for file in candidates {
            // Re-parsed fresh here rather than trusting whatever the discovery scan saw earlier:
            // the two can be minutes apart, and this is the one place a stale read would turn
            // into an actual, irreversible mutation of the wrong file.
            guard case .fat(let slices) = LipoFileReader.machOKind(at: file),
                  slices.contains(where: { $0.cpuType == LipoArch.arm64 })
            else { continue }

            let beforeSize = LipoFileReader.allocatedSize(at: file)
            do {
                try thinOneFile(at: file, fileManager: fileManager)
                freedBytes += max(0, beforeSize - LipoFileReader.allocatedSize(at: file))
                thinnedAny = true
            } catch {
                fileFailures.append("\(file.lastPathComponent): \(error)")
            }
        }

        guard thinnedAny else {
            let reason = fileFailures.isEmpty ? "Nothing here needed thinning." : fileFailures.joined(separator: "; ")
            return LipoThinOutcome(succeeded: false, freedBytes: 0, message: reason)
        }

        // Thinning invalidates the bundle's code signature outright — PearCleaner's own approach,
        // and the task spec's explicit call: without a fresh ad-hoc signature macOS refuses to
        // launch the app at all. `--deep` re-signs every embedded framework/helper along with the
        // top-level bundle in one pass, matching everything `machOCandidates` may have touched.
        do {
            try LipoProcessRunner.run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", bundlePath.path])
        } catch {
            return LipoThinOutcome(
                succeeded: false, freedBytes: freedBytes,
                message: "Thinned, but re-signing failed (\(error)). The app may refuse to launch until reinstalled."
            )
        }

        do {
            try LipoProcessRunner.run("/usr/bin/codesign", ["--verify", bundlePath.path])
        } catch {
            return LipoThinOutcome(
                succeeded: false, freedBytes: freedBytes,
                message: "Thinned and re-signed, but signature verification failed (\(error))."
            )
        }

        // Never just trust `lipo`'s exit code: re-read every file this pass touched and confirm
        // each is honestly single-architecture now, the same parser the discovery scan uses.
        for file in candidates {
            if case .fat = LipoFileReader.machOKind(at: file) {
                return LipoThinOutcome(
                    succeeded: false, freedBytes: freedBytes,
                    message: "\(file.lastPathComponent) is still a fat binary after thinning."
                )
            }
        }

        let freedCaption = "Freed \(ByteCountFormatter.lipoDecimalString(freedBytes))"
        if fileFailures.isEmpty {
            return LipoThinOutcome(succeeded: true, freedBytes: freedBytes, message: freedCaption)
        }
        return LipoThinOutcome(
            succeeded: true, freedBytes: freedBytes,
            message: "\(freedCaption). Some files were skipped: \(fileFailures.joined(separator: "; "))"
        )
    }

    /// `lipo -thin arm64` into a same-directory temp file, permissions carried over from the
    /// original, then an atomic same-volume replace — never a remove-then-move, so a crash
    /// mid-operation leaves either the original file intact or the finished replacement, never a
    /// bundle with the executable simply missing.
    private static func thinOneFile(at url: URL, fileManager: FileManager) throws {
        let originalAttributes = try fileManager.attributesOfItem(atPath: url.path)
        let permissions = originalAttributes[.posixPermissions] as? NSNumber

        let tempURL = url.deletingLastPathComponent()
            .appending(path: ".\(url.lastPathComponent).sweeplipo-\(UUID().uuidString.prefix(8))")
        defer { try? fileManager.removeItem(at: tempURL) } // no-op once the replace below has moved it into place

        try LipoProcessRunner.run("/usr/bin/lipo", ["-thin", "arm64", url.path, "-output", tempURL.path])

        if let permissions {
            try fileManager.setAttributes([.posixPermissions: permissions], ofItemAtPath: tempURL.path)
        }

        _ = try fileManager.replaceItemAt(url, withItemAt: tempURL)
    }
}

// MARK: - Process runner (impure: the only two process spawns in this whole module)

/// Spawns exactly two fixed-path system tools, `/usr/bin/lipo` and `/usr/bin/codesign` — never a
/// shell, never a `PATH` lookup, matching PLAN §2's "typed adapters only, fixed absolute
/// executable paths." This is the ONE place `LipoThinningService` forks a process at all, and
/// only ever as a direct, synchronous consequence of the user confirming one specific thin
/// action — never during discovery (`LipoEngine.scan` never calls this). That split is the
/// entire point of `MachOFatParser` existing: see its doc comment for the measured cost of a
/// per-item process spawn during a scan elsewhere in this codebase.
///
/// Deliberately not a reuse of `BrewProcessRunner` (same target, reachable): that runner's
/// sanitized environment is Homebrew-specific (`HOMEBREW_NO_*` flags, a `brew`-relative `PATH`)
/// and its generous byte-capped dual-pipe drain is sized for `brew`'s occasionally-large JSON
/// output. `lipo`/`codesign` need neither — both write at most a few lines, merged onto one pipe
/// below is enough to avoid the classic "child blocks on a full pipe nobody is draining"
/// deadlock, since draining starts immediately after launch rather than after exit.
enum LipoProcessRunner {
    enum RunError: Error, CustomStringConvertible {
        case launchFailed(String)
        case nonZeroExit(Int32, output: String)
        case timedOut

        var description: String {
            switch self {
            case .launchFailed(let reason): "could not launch (\(reason))"
            case .nonZeroExit(let code, let output): "exit \(code): \(output.isEmpty ? "(no output)" : output)"
            case .timedOut: "timed out"
            }
        }
    }

    /// `lipo -thin` on even a large binary is a local, disk-bound copy with no network
    /// dependency, and `codesign --deep` over a whole bundle is the slower of the two operations
    /// this module runs — 60 s is comfortably past what either takes on real hardware for any app
    /// this module has been tested against, without letting a truly hung process hold the confirm
    /// flow open forever.
    static let timeout: TimeInterval = 60

    @discardableResult
    static func run(_ executablePath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let outputPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = outputPipe // merged: neither tool's stderr needs separating from its stdout here

        do {
            try process.run()
        } catch {
            throw RunError.launchFailed(String(describing: error))
        }

        // Draining starts the instant the process is launched, concurrently with it running —
        // the fix for the deadlock described in the type's doc comment. `waitUntilExit()` only
        // ever follows the drain finishing (EOF, meaning the process closed its end), so this
        // never reads a still-growing pipe as if it were already complete.
        let reader = outputPipe.fileHandleForReading
        let group = DispatchGroup()
        var collected = Data()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            collected = reader.readDataToEndOfFile()
            group.leave()
        }

        if group.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            throw RunError.timedOut
        }
        process.waitUntilExit()

        let output = String(data: collected, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw RunError.nonZeroExit(process.terminationStatus, output: output)
        }
        return output
    }
}

/// One decimal byte string, independent of `SweepUI.SweepFormat` — `LipoService` is the engine
/// layer the task spec keeps free of any UI-package import; this is the same decimal-unit
/// convention (`ByteCountFormatter` with `.file` semantics, 1000-based), used only for the plain
/// success/failure `message` string this file itself produces. `LipoScreen` formats every
/// *displayed* byte count through `SweepFormat.bytes` as normal — this exists solely so a
/// `LipoThinOutcome.message` reads sensibly even for a caller that never touches SwiftUI (as
/// `LipoLogicTests` does not).
private extension ByteCountFormatter {
    static func lipoDecimalString(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .decimal
        formatter.allowedUnits = .useAll
        return formatter.string(fromByteCount: bytes)
    }
}
