import Foundation

/// PLAN §3 module 8 + Appendix B: the entire closed set of operations `SweepHelper` will ever
/// run. There is no generic command/path case, and none may be added without also adding a
/// ``MaintenanceCommandPlan`` branch and a ``MaintenanceValidation`` rule — a case that decodes
/// but has no plan/validation simply cannot execute.
///
/// `Codable` conformance is hand-written, not synthesized (see the `Codable` extension below):
/// this is the one wire format an unauthenticated-until-code-signed-and-console-UID-checked peer
/// can send bytes for, so its decode behavior must be exact and auditable rather than inferred
/// from compiler synthesis. Decoding anything that is not exactly one of these three shapes
/// throws — there is no fallback interpretation of an unrecognized request.
public enum MaintenanceOperation: Sendable, Equatable {
    case flushDNS
    /// `volume` is validated against the live mounted-volume list at execution time
    /// (``MaintenanceValidation``), never trusted as given.
    case reindexSpotlight(volume: String)
    /// `urgency` must be `1...4` (``MaintenanceValidation/urgencyRange``), matching `tmutil`'s own
    /// documented range.
    case thinSnapshots(urgency: Int)
}

extension MaintenanceOperation: Codable {
    private enum Kind: String, Codable {
        case flushDNS, reindexSpotlight, thinSnapshots
    }

    private enum CodingKeys: String, CodingKey {
        case kind, volume, urgency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .flushDNS:
            self = .flushDNS
        case .reindexSpotlight:
            self = .reindexSpotlight(volume: try container.decode(String.self, forKey: .volume))
        case .thinSnapshots:
            self = .thinSnapshots(urgency: try container.decode(Int.self, forKey: .urgency))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .flushDNS:
            try container.encode(Kind.flushDNS, forKey: .kind)
        case .reindexSpotlight(let volume):
            try container.encode(Kind.reindexSpotlight, forKey: .kind)
            try container.encode(volume, forKey: .volume)
        case .thinSnapshots(let urgency):
            try container.encode(Kind.thinSnapshots, forKey: .kind)
            try container.encode(urgency, forKey: .urgency)
        }
    }
}

/// The helper's reply to `perform(_:reply:)`. Never carries raw process output beyond a bounded,
/// human-readable summary — nothing here is a generic passthrough of stdout/stderr to an
/// unauthenticated-format wire value.
public enum MaintenanceOutcome: Sendable, Equatable {
    case succeeded(detail: String)
    case failed(reason: String)
}

extension MaintenanceOutcome: Codable {
    private enum Kind: String, Codable { case succeeded, failed }
    private enum CodingKeys: String, CodingKey { case kind, detail, reason }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .succeeded:
            self = .succeeded(detail: try container.decode(String.self, forKey: .detail))
        case .failed:
            self = .failed(reason: try container.decode(String.self, forKey: .reason))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .succeeded(let detail):
            try container.encode(Kind.succeeded, forKey: .kind)
            try container.encode(detail, forKey: .detail)
        case .failed(let reason):
            try container.encode(Kind.failed, forKey: .kind)
            try container.encode(reason, forKey: .reason)
        }
    }
}

/// The XPC protocol version, bumped whenever ``MaintenanceOperation`` or ``MaintenanceOutcome``'s
/// wire shape changes in a way an older peer could not decode. `HelperClient` refuses to send any
/// operation unless a fresh handshake's ``HelperHandshake/protocolVersion`` matches this exactly
/// (PLAN Appendix B: "incompatible-version refusal").
public enum HelperProtocolVersion {
    public static let current = 1
}

/// Separate axis from the XPC protocol version: which revision of ``MaintenanceValidation``'s
/// rules (volume allowlist shape, urgency range) the helper is enforcing. Not currently compared
/// by `HelperClient` — no rule has ever changed — but carried on the wire from day one so a future
/// rule change has a version to check without a second handshake redesign.
public enum MaintenancePolicyVersion {
    public static let current = 1
}

/// The handshake payload PLAN Appendix B's lifecycle calls for: "versioned XPC handshake
/// (protocol/app/helper/policy versions)". `helperBuildVersion` is informational (shown in the UI
/// and logs); only `protocolVersion` gates whether `HelperClient` will ever call `perform`.
public struct HelperHandshake: Sendable, Equatable, Codable {
    public let protocolVersion: Int
    public let helperBuildVersion: String
    public let policyVersion: Int

    public init(protocolVersion: Int, helperBuildVersion: String, policyVersion: Int) {
        self.protocolVersion = protocolVersion
        self.helperBuildVersion = helperBuildVersion
        self.policyVersion = policyVersion
    }
}

/// The wire envelope `perform(_:reply:)`'s `requestData` actually decodes as — the one
/// ``MaintenanceOperation`` a caller wants run, plus the protocol/policy versions the caller
/// believes are in effect.
///
/// Codex finding #2 ("handshake and policy compatibility are not helper-enforced"): before this
/// type existed, `perform`'s `requestData` decoded as a bare `MaintenanceOperation`, so nothing
/// about a caller's declared versions ever reached the helper — only `HelperClient` compared
/// `HelperHandshake.protocolVersion` after `handshake()`, and a caller could skip the handshake
/// entirely and call `perform` directly. Carrying the versions on *every* `perform` call (not just
/// once at handshake time) lets `HelperService` independently refuse an incompatible or
/// handshake-skipping caller at the one place that actually executes something, closed by
/// construction rather than by the client's own good behavior.
public struct MaintenanceRequest: Sendable, Equatable, Codable {
    public let operation: MaintenanceOperation
    public let protocolVersion: Int
    public let policyVersion: Int

    public init(
        operation: MaintenanceOperation,
        protocolVersion: Int = HelperProtocolVersion.current,
        policyVersion: Int = MaintenancePolicyVersion.current
    ) {
        self.operation = operation
        self.protocolVersion = protocolVersion
        self.policyVersion = policyVersion
    }
}

/// Fixed identifiers shared by the LaunchDaemon plist (`scripts/build-app.sh`), the app's
/// `SMAppService.daemon(plistName:)` registration, and `NSXPCConnection`'s mach service lookup —
/// one spelling, three consumers, so they can never drift apart.
public enum HelperIdentity {
    public static let machServiceName = "com.aditya.sweep.helper"
    public static let launchDaemonPlistName = "com.aditya.sweep.helper.plist"
    public static let launchDaemonLabel = "com.aditya.sweep.helper"

    /// Sweep.app's own `CFBundleIdentifier` (`scripts/build-app.sh`'s `Info.plist`) — the identity
    /// `HelperTrust.designatedRequirement`'s `identifier` clause binds to. Named here, not just
    /// inlined at each call site, so the one property the helper's designated requirement must
    /// check ("is the caller Sweep.app itself", Codex finding #1) has exactly one spelling shared
    /// by the requirement-builder and anything that verifies it.
    public static let appBundleIdentifier = "com.aditya.sweep"
}

/// The one absolute-path, argv-array command (or short fixed sequence of them) each
/// ``MaintenanceOperation`` expands to. This is the single source of truth for both what the app
/// previews ("shows the exact command", PLAN §3 task spec) and what the helper actually executes:
/// neither side composes a command string independently, so the two can never drift.
public enum MaintenanceCommandPlan {
    public struct Command: Sendable, Equatable {
        public let executablePath: String
        public let arguments: [String]

        public init(executablePath: String, arguments: [String]) {
            self.executablePath = executablePath
            self.arguments = arguments
        }

        /// The exact literal the preview card shows and the helper runs — never re-derived, never
        /// shell-quoted or re-parsed (nothing here is ever handed to a shell).
        public var commandLine: String {
            ([executablePath] + arguments).joined(separator: " ")
        }
    }

    /// PLAN Appendix B: "typed adapters (never shell)" — fixed absolute paths only, verified
    /// against this machine's real layout (`/usr/bin/{dscacheutil,killall,mdutil,tmutil}`).
    public enum Executable {
        public static let dscacheutil = "/usr/bin/dscacheutil"
        public static let killall = "/usr/bin/killall"
        public static let mdutil = "/usr/bin/mdutil"
        public static let tmutil = "/usr/bin/tmutil"
    }

    /// The half of `flushDNS` that runs fine without root (PLAN §3 task spec: "dscacheutil part
    /// works without root"). Named so both the full `flushDNS` plan and the app's user-level
    /// fallback adapter read the same value — neither has to know it is "the first command."
    public static let userLevelDNSFlushCommand = Command(
        executablePath: Executable.dscacheutil,
        arguments: ["-flushcache"]
    )

    /// The other half: signalling a daemon this process does not own needs root, which is exactly
    /// what makes it a helper-only step.
    public static let privilegedDNSFlushCommand = Command(
        executablePath: Executable.killall,
        arguments: ["-HUP", "mDNSResponder"]
    )

    /// `tmutil thinlocalsnapshots mount_point [purge_amount] [urgency]` (`man tmutil`, verified on
    /// this machine): there is no documented "unlimited" sentinel for `purge_amount`, so this is a
    /// purge amount far larger than any real local snapshot store — the documented way to ask
    /// tmutil to "thin as much as `urgency` allows."
    public static let snapshotPurgeAmountBytes: Int64 = 500_000_000_000

    /// The commands one operation expands to, in the order they must run.
    public static func commands(for operation: MaintenanceOperation) -> [Command] {
        switch operation {
        case .flushDNS:
            return [userLevelDNSFlushCommand, privilegedDNSFlushCommand]
        case .reindexSpotlight(let volume):
            return [Command(executablePath: Executable.mdutil, arguments: ["-E", volume])]
        case .thinSnapshots(let urgency):
            return [Command(
                executablePath: Executable.tmutil,
                arguments: ["thinlocalsnapshots", "/", String(snapshotPurgeAmountBytes), String(urgency)]
            )]
        }
    }

    /// One line per command — exactly what the preview card renders, computed from the same
    /// function that builds what actually runs.
    public static func previewText(for operation: MaintenanceOperation) -> String {
        commands(for: operation).map(\.commandLine).joined(separator: "\n")
    }
}
