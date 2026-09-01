import Darwin
import Foundation

/// PLAN §4: Full Disk Access "cannot be granted programmatically" and "cannot" be read as a plain
/// boolean either — a failed canary read is evidence, not proof. Three states, not two:
///
/// - `.unknown`: nothing has proven either way yet (first launch, every probe came back
///   inconclusive — see `CapabilityProbeOutcome`).
/// - `.available`: at least one probe (a canary read, or a real operation) actually succeeded.
/// - `.denied`: at least one probe hit an explicit TCC-shaped refusal (`EPERM`/`EACCES`).
public enum CapabilityStatus: String, Sendable, Equatable, Codable {
    case unknown
    case available
    case denied
}

/// Capabilities Sweep models this way. One case today — Full Disk Access — but kept as an enum
/// (not a bare boolean flag on the FDA type alone) so a second heuristic capability never has to
/// invent its own parallel `unknown/available/denied` type from scratch.
public enum SweepCapability: String, Sendable, Equatable, Hashable, CaseIterable, Codable {
    case fullDiskAccess
}

/// The result of one non-destructive probe: one canary byte-read, or one real operation's
/// outcome fed back in after the fact (PLAN §4: "multiple non-destructive probes + actual
/// operation errors").
///
/// Deliberately three cases, not a `Result<Void, Error>` — `.inconclusive` is not "an error", it
/// is "this probe had nothing to say" (the canary does not exist on this macOS version, this
/// volume is unmounted, whatever). Collapsing it into a generic failure is exactly the trap PLAN
/// §4 calls out: "canary read failure ≠ proof of denial."
public enum CapabilityProbeOutcome: Sendable, Equatable {
    case success
    case permissionDenied
    case inconclusive
}

/// Classifies a POSIX `errno` into a `CapabilityProbeOutcome`, honoring the same split
/// `SweepCore`'s own filesystem layer already draws (`FileDescriptorPath.isPermissionDenied`/
/// `isNotFound`): `EACCES`/`EPERM` is macOS actually refusing the read (TCC-shaped, on a
/// FDA-protected path); `ENOENT`/`ENOTDIR` means the path simply is not there on this machine —
/// try the next canary rather than reading it as a refusal. Every other errno is folded into
/// `.inconclusive` too: this probe layer only ever asserts a capability is `.denied` on the one
/// errno shape that macOS actually uses for a permission refusal, never on "something else went
/// wrong."
public enum CapabilityErrno {
    public static func classify(_ code: Int32) -> CapabilityProbeOutcome {
        switch code {
        case EACCES, EPERM: .permissionDenied
        default: .inconclusive
        }
    }
}

/// The pure aggregation rule (PLAN §4: "aggregate honestly"), kept as a single free function over
/// plain data specifically so it is exhaustively unit-testable without touching a filesystem or a
/// TCC prompt — see `CapabilitiesTests` for every combination.
///
/// Precedence, in order: any `.success` proves the capability is available, even alongside a
/// `.permissionDenied` from a different canary (a partial grant is still a grant); short of that,
/// any `.permissionDenied` is a real refusal; an empty list, or a list that is entirely
/// `.inconclusive`, proves nothing either way.
public enum CapabilityAggregator {
    public static func status(from outcomes: [CapabilityProbeOutcome]) -> CapabilityStatus {
        if outcomes.contains(.success) { return .available }
        if outcomes.contains(.permissionDenied) { return .denied }
        return .unknown
    }
}

/// Behind a protocol so `CapabilityStore` (Sources/SweepApp/Onboarding) can inject canned
/// outcomes in tests instead of depending on this machine's real TCC state — this package's own
/// tests only exercise `CapabilityErrno`/`CapabilityAggregator` (pure) plus the syscall
/// classification below (which can be forced by chmod-ing a real temp file, see
/// `CapabilitiesTests.swift`), never a real FDA grant/deny.
public protocol FullDiskAccessProbing: Sendable {
    /// One outcome per canary, in `canaryPaths` order. Never partial — every canary is always
    /// probed, so a single denial can never hide a later success.
    func probeOutcomes() -> [CapabilityProbeOutcome]
}

/// Full Disk Access probes: a byte-read of each of a small set of TCC-protected canary paths
/// (PLAN §4). Every canary here is chosen because macOS gates it behind Full Disk Access
/// specifically, for a plain read, regardless of ordinary POSIX permissions — an unprivileged
/// process without FDA gets `EPERM`/`EACCES` reading any of these even though the underlying file
/// mode would otherwise allow it:
///
/// 1. `~/Library/Safari/CloudTabs.db` — Safari's synced-tabs database.
/// 2. `/Library/Preferences/com.apple.TimeMachine.plist` — the system Time Machine preferences.
/// 3. `~/Library/Containers/com.apple.mail/Info.plist` — not mail *content*; just another app's
///    container metadata, which is itself off-limits to a third-party process without FDA.
///
/// Three independent canaries, not one, because any single one can be legitimately absent
/// (Time Machine never configured, Mail never launched, no iCloud tabs) — that must read as
/// `.inconclusive`/try-the-next-one, never as proof of anything (see `CapabilityErrno`).
public struct FullDiskAccessProbe: FullDiskAccessProbing {
    public let canaryPaths: [String]

    public init(canaryPaths: [String] = FullDiskAccessProbe.defaultCanaryPaths()) {
        self.canaryPaths = canaryPaths
    }

    /// `home` is injectable purely so a test can point this at a scratch directory; production
    /// call sites use the default.
    public static func defaultCanaryPaths(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/Library/Safari/CloudTabs.db",
            "/Library/Preferences/com.apple.TimeMachine.plist",
            "\(home)/Library/Containers/com.apple.mail/Info.plist",
        ]
    }

    public func probeOutcomes() -> [CapabilityProbeOutcome] {
        canaryPaths.map { Self.probe(path: $0) }
    }

    /// One non-destructive byte-read: open read-only, read at most one byte, close. Never
    /// truncates, never creates (`open` is not given `O_CREAT`), never writes.
    ///
    /// Uses the raw `open`/`read`/`errno` syscalls rather than `Data(contentsOf:)` or
    /// `FileManager.contents(atPath:)` — both wrap the failure in an `NSError`/`nil` that does
    /// not reliably carry the POSIX `errno` back out, and that errno is the entire signal this
    /// probe exists to read.
    static func probe(path: String) -> CapabilityProbeOutcome {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else {
            return CapabilityErrno.classify(errno)
        }
        defer { close(fd) }
        var byte: UInt8 = 0
        let bytesRead = read(fd, &byte, 1)
        if bytesRead >= 0 {
            // A successful open+read, including of a legitimately empty file (`bytesRead == 0`):
            // macOS already let this process past TCC to get here at all.
            return .success
        }
        return CapabilityErrno.classify(errno)
    }
}
