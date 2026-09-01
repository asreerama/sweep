import AppKit
import Observation
import SweepSystem

/// Live, observable capability status for the app (PLAN §4). `SweepSystem/Capabilities.swift`
/// owns the pure probe/aggregation layer, kept filesystem-and-AppKit-free so it is exhaustively
/// unit-testable there (`CapabilitiesTests`); this class is the thin app-side wrapper that turns
/// that pure layer into something a SwiftUI view can read reactively and that knows how to
/// re-check itself — the part of the model that genuinely belongs to the app, not to a system
/// reader package.
///
/// One shared instance, same shape as `MenuBarActivationPolicy`/`SentinelSettings`: a `.shared`
/// singleton with an idempotent `start()` any launch path can call without coordinating who goes
/// first.
@MainActor
@Observable
final class CapabilityStore {
    static let shared = CapabilityStore()

    private(set) var status: [SweepCapability: CapabilityStatus] = Dictionary(
        uniqueKeysWithValues: SweepCapability.allCases.map { ($0, .unknown) }
    )

    /// `true` while a probe run is in flight — the FDA onboarding step shows a "Checking…" chip
    /// instead of a stale `.unknown` while this is true.
    private(set) var isRefreshing = false

    private let fullDiskAccessProbe: any FullDiskAccessProbing
    private var didStart = false

    init(fullDiskAccessProbe: any FullDiskAccessProbing = FullDiskAccessProbe()) {
        self.fullDiskAccessProbe = fullDiskAccessProbe
    }

    func status(for capability: SweepCapability) -> CapabilityStatus {
        status[capability] ?? .unknown
    }

    /// Installs the `NSApplication.didBecomeActiveNotification` re-check (PLAN §4: "re-check on
    /// app activation" — the moment a user comes back from System Settings after granting or
    /// denying FDA) and takes one reading immediately. Idempotent, so both `SweepApp.swift`'s
    /// launch-time call and the onboarding FDA step's own `onAppear` can call this without
    /// either needing to know whether the other already did.
    func start() {
        guard !didStart else { return }
        didStart = true

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }

        Task { await refresh() }
    }

    /// Re-runs every capability's probes and republishes the result. Safe to call as often as
    /// wanted — the FDA onboarding step also calls this from a manual "Check again" action and
    /// from its own `onAppear`, independent of `start()`'s activation-triggered calls.
    func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }
        let probe = fullDiskAccessProbe
        let outcomes = await Task.detached(priority: .utility) {
            probe.probeOutcomes()
        }.value
        status[.fullDiskAccess] = CapabilityAggregator.status(from: outcomes)
    }

    /// Feeds a real operation's failure into the same model a canary probe would (PLAN §4:
    /// "multiple non-destructive probes + actual-operation errors"). No call site exists yet —
    /// this is the seam a future scan/clean path can call the moment it hits `EPERM`/`EACCES` on
    /// a real read, without the capability model needing to change shape to accept it.
    ///
    /// Deliberately one-directional: an operation-level refusal can move a capability from
    /// `.unknown` to `.denied`, but never overrides a `.available` a full canary sweep already
    /// proved — one stray `EPERM` on an unrelated path (a different app's sandbox, a transient
    /// mount issue) is not grounds to walk back a grant the aggregator already confirmed. Only
    /// `refresh()`, re-running every canary honestly, can move a capability *down* from
    /// `.available`.
    func recordOperationError(errno code: Int32, for capability: SweepCapability) {
        guard CapabilityErrno.classify(code) == .permissionDenied else { return }
        guard status[capability] != .available else { return }
        status[capability] = .denied
    }
}
