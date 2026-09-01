import Foundation
import SweepPolicy

// MARK: - Pure logic (unit-testable; see Tests/SweepAppTests/MaintenanceModelLogicTests.swift)

/// The three cards on screen, in PLAN order.
enum MaintenanceOperationKind: String, CaseIterable, Identifiable, Sendable {
    case flushDNS
    case reindexSpotlight
    case thinSnapshots

    var id: String { rawValue }

    var title: String {
        switch self {
        case .flushDNS: "Flush DNS Cache"
        case .reindexSpotlight: "Rebuild Spotlight Index"
        case .thinSnapshots: "Thin Local Snapshots"
        }
    }

    var symbol: String {
        switch self {
        case .flushDNS: "network"
        case .reindexSpotlight: "magnifyingglass"
        case .thinSnapshots: "camera.aperture"
        }
    }

    /// Plain-language description (PLAN §3 task spec: "plain-language descriptions").
    var explanation: String {
        switch self {
        case .flushDNS:
            "Clears cached DNS lookups. Fixes sites that resolve to the wrong address after a network change."
        case .reindexSpotlight:
            "Rebuilds Spotlight\u{2019}s index for a volume. Fixes search that returns stale or missing results."
        case .thinSnapshots:
            "Frees space held by local Time Machine snapshots. macOS keeps some automatically; this asks it to keep less."
        }
    }

    /// Only `flushDNS` has a real user-level fallback; the other two do nothing without the
    /// helper.
    var hasUserLevelFallback: Bool { self == .flushDNS }
}

enum MaintenanceRunState: Equatable {
    case idle
    case running
    case succeeded(String)
    case failed(String)
}

/// The four `tmutil`-documented urgency levels, in plain language.
enum MaintenanceUrgencyLevel: Int, CaseIterable, Identifiable {
    case light = 1
    case moderate = 2
    case aggressive = 3
    case maximum = 4

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .light: "Light"
        case .moderate: "Moderate"
        case .aggressive: "Aggressive"
        case .maximum: "Maximum"
        }
    }
}

/// Maps `HelperClientState` to what the screen actually says — kept as pure functions so the
/// mapping is unit-testable without rendering a view.
enum MaintenanceHelperPresentation {
    static func statusLine(for state: HelperClientState) -> String {
        switch state {
        case .notRegistered: "Not requested yet."
        case .registering: "Requesting permission\u{2026}"
        case .requiresApproval: "Waiting for approval in Login Items."
        case .handshaking: "Connecting\u{2026}"
        case .ready(let handshake): "Connected (helper v\(handshake.helperBuildVersion))."
        case .incompatible: "The helper doesn\u{2019}t match this build."
        case .unavailable(let error): error.description
        }
    }

    /// Whether the status banner is worth showing at all — the calm, common `.ready` path stays
    /// quiet rather than adding a permanent "Connected" banner nobody needs to read twice.
    static func showsBanner(for state: HelperClientState) -> Bool {
        switch state {
        case .notRegistered: false
        default: true
        }
    }
}

// MARK: - Model

/// Screen state for Maintenance (module 8, PLAN §3): three privileged-adjacent operations, each
/// preview-first, each streaming its own run state, all gated by one shared `HelperClient`.
@MainActor
@Observable
final class MaintenanceModel {
    let helper: HelperClient
    private(set) var runStates: [MaintenanceOperationKind: MaintenanceRunState] = [:]
    private(set) var volumeOptions: [MaintenanceVolumeOption] = []
    var selectedVolumePath = "/"
    var selectedUrgency = MaintenanceUrgencyLevel.moderate.rawValue

    init(helper: HelperClient = HelperClient()) {
        self.helper = helper
    }

    var isHelperReady: Bool {
        if case .ready = helper.state { return true }
        return false
    }

    func runState(for kind: MaintenanceOperationKind) -> MaintenanceRunState {
        runStates[kind] ?? .idle
    }

    /// Read-only: populates the volume picker and peeks at the helper's existing status. Never
    /// calls `requestAccess()` — PLAN §3's lazy-registration rule applies to screen appearance too.
    func onAppear() async {
        volumeOptions = MountedVolumeLister.current()
        if !volumeOptions.contains(where: { $0.id == selectedVolumePath }) {
            selectedVolumePath = volumeOptions.first?.id ?? "/"
        }
        await helper.refreshFromCurrentStatus()
    }

    func operation(for kind: MaintenanceOperationKind) -> MaintenanceOperation {
        switch kind {
        case .flushDNS: .flushDNS
        case .reindexSpotlight: .reindexSpotlight(volume: selectedVolumePath)
        case .thinSnapshots: .thinSnapshots(urgency: selectedUrgency)
        }
    }

    /// The exact command the confirm sheet shows — computed from the same
    /// `MaintenanceCommandPlan` the helper executes from, so preview and reality can never drift.
    func previewText(for kind: MaintenanceOperationKind) -> String {
        MaintenanceCommandPlan.previewText(for: operation(for: kind))
    }

    /// Confirmed by the preview sheet. `flushDNS` degrades to the user-level-only adapter when the
    /// helper is not ready; the other two operations have no user-level path and always go through
    /// `HelperClient`, which is where PLAN §3's "first use of Maintenance prompts" lazy
    /// registration actually happens.
    func run(_ kind: MaintenanceOperationKind) async {
        runStates[kind] = .running
        let outcome: MaintenanceOutcome
        if kind.hasUserLevelFallback, !isHelperReady {
            outcome = await LocalDNSFlushAdapter.run()
        } else {
            if !isHelperReady {
                await helper.requestAccess()
            }
            outcome = await helper.run(operation(for: kind))
        }
        switch outcome {
        case .succeeded(let detail): runStates[kind] = .succeeded(detail)
        case .failed(let reason): runStates[kind] = .failed(reason)
        }
    }
}
