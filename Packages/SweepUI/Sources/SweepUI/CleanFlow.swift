import Foundation

/// The Clean flow's UI-facing contract.
///
/// SweepUI depends on nothing (see `InventoryModel.swift`), so the confirm/progress/report views
/// in `Components/CleanConfirmSheet.swift`, `CleanProgressView.swift` and `CleanReportView.swift`
/// are built and previewed against these value types and the ``CleanBackend`` protocol below —
/// never against SweepCore directly. `Sources/SweepApp/Scan/CleanAdapter.swift` is the one place
/// in the app that binds a real conformance to SweepCore's pinned `CleanService` contract
/// (BUILDLOG.md "Pinned API contract"): `static isEnabled`, `execute(_:) -> AsyncThrowingStream
/// <CleanEvent>`, trash-only, WAL journaled, report carrying per-item outcomes, Trash restore
/// URLs and honest freed-bytes. Keeping the boundary here means SweepCore landing the real
/// service — even with slight signature drift from the pinned shape — only ever requires editing
/// that one adapter file.

/// One volume a clean request touches, and how much of the request lives there.
///
/// Sweep's v1 `VolumePolicy` scopes scans to local, writable, non-backup volumes (PLAN §2); most
/// requests resolve to exactly one entry here, but the confirm sheet always lists every volume
/// a request spans rather than assuming that.
public struct CleanVolume: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let itemCount: Int
    public let byteCount: Int64

    public init(id: String, name: String, itemCount: Int, byteCount: Int64) {
        self.id = id
        self.name = name
        self.itemCount = itemCount
        self.byteCount = byteCount
    }
}

/// What a clean request is about to do — everything the confirmation sheet shows before a single
/// byte moves.
public struct CleanRequestSummary: Sendable, Hashable {
    public let itemCount: Int
    public let totalBytes: Int64
    public let volumes: [CleanVolume]

    public init(itemCount: Int, totalBytes: Int64, volumes: [CleanVolume]) {
        self.itemCount = itemCount
        self.totalBytes = totalBytes
        self.volumes = volumes
    }
}

/// One item's outcome once the operation reaches it.
public struct CleanItemOutcome: Identifiable, Hashable, Sendable {
    public enum Status: Sendable, Hashable {
        case succeeded
        case failed(reason: String)
        case skipped(reason: String)
    }

    public let id: String
    public let title: String
    public let byteCount: Int64
    public let status: Status

    public init(id: String, title: String, byteCount: Int64, status: Status) {
        self.id = id
        self.title = title
        self.byteCount = byteCount
        self.status = status
    }

    public var failureReason: String? {
        if case .failed(let reason) = status { reason } else { nil }
    }
}

/// One tick of an in-flight clean: what the progress state reads.
///
/// `remainingBytes`/`remainingItems` count DOWN from the confirmed total — the hero counter rolls
/// down to zero (PLAN §5 motion moment two) rather than counting up the way a scan does.
public struct CleanProgressUpdate: Sendable, Hashable {
    public let remainingBytes: Int64
    public let remainingItems: Int
    public let currentItemCaption: String?

    public init(remainingBytes: Int64, remainingItems: Int, currentItemCaption: String?) {
        self.remainingBytes = remainingBytes
        self.remainingItems = remainingItems
        self.currentItemCaption = currentItemCaption
    }
}

/// The finished result: what actually freed, and anything that did not go as planned.
public struct CleanReport: Sendable, Hashable {
    public let freedBytes: Int64
    public let succeededCount: Int
    public let outcomes: [CleanItemOutcome]

    public init(freedBytes: Int64, succeededCount: Int, outcomes: [CleanItemOutcome]) {
        self.freedBytes = freedBytes
        self.succeededCount = succeededCount
        self.outcomes = outcomes
    }

    /// Listed plainly in the report state, with their reasons — never silently dropped.
    public var failures: [CleanItemOutcome] {
        outcomes.filter { if case .failed = $0.status { true } else { false } }
    }

    /// Sum of `byteCount` over outcomes that actually moved to the Trash. `freedBytes` is a
    /// volume-capacity delta and reads as ~0 whenever the move stays on the same volume — the
    /// ordinary case for a move to Trash — so the report hero leads with this instead: what the
    /// user actually watched happen, not a capacity figure that has not moved yet.
    public var movedBytes: Int64 {
        outcomes.filter { $0.status == .succeeded }.reduce(0) { $0 + $1.byteCount }
    }
}

/// One step of the async clean stream — the UI-facing mirror of SweepCore's pinned `CleanEvent`.
public enum CleanEvent: Sendable {
    case progress(CleanProgressUpdate)
    case finished(CleanReport)
}

/// What the Clean flow needs from a backend, independent of how cleaning is actually implemented.
///
/// Mirrors the pinned SweepCore contract member-for-member (`isEnabled`, `execute(_:)`) so the
/// adapter binding a real `CleanService` to it in `CleanAdapter.swift` is close to mechanical.
public protocol CleanBackend: Sendable {
    /// Mirrors `CleanService.isEnabled`: false until Fable flips the Gate 1 switch. The Clean
    /// entry points stay disabled and the flow never starts while this is false — that is the
    /// "dead-ends at the existing Gate 1 lock state" contract for this build.
    static var isEnabled: Bool { get }

    /// Mirrors `CleanService.execute(_:)`. `itemIDs` are `InventoryItem.id`s — the same stable
    /// path-based identities the selection model already tracks.
    func execute(itemIDs: Set<String>) -> AsyncThrowingStream<CleanEvent, Error>
}

extension CleanBackend {
    /// Instance-level mirror of the static requirement, so an `any CleanBackend` existential can
    /// read it without knowing its concrete type.
    public var isEnabled: Bool { Self.isEnabled }
}

/// Where one Clean flow currently is.
public enum CleanFlowPhase: Sendable {
    case confirm(CleanRequestSummary)
    case running(CleanProgressUpdate)
    case report(CleanReport)
    case failed(String)
}

/// Drives one Clean flow: confirm → running → report, entirely against ``CleanBackend`` so it
/// is previewable and testable without SweepCore.
///
/// Every phase transition is a plain assignment to `phase`, never a `withAnimation` chain — the
/// views drive their springs off `.animation(_:value:)` (see `CleanProgressView`), which is what
/// makes every state here retargetable mid-flight: a fast run whose progress updates land faster
/// than one spring settles simply redirects the in-flight animation onto the new value instead of
/// queuing a second one behind it.
@MainActor
@Observable
public final class CleanFlowModel {
    public private(set) var phase: CleanFlowPhase
    public let requestSummary: CleanRequestSummary

    private let backend: any CleanBackend
    private let itemIDs: Set<String>
    private var task: Task<Void, Never>?

    public init(requestSummary: CleanRequestSummary, itemIDs: Set<String>, backend: any CleanBackend) {
        self.requestSummary = requestSummary
        self.itemIDs = itemIDs
        self.backend = backend
        self.phase = .confirm(requestSummary)
    }

    public var isBackendEnabled: Bool { backend.isEnabled }

    /// Starts the operation. No-op if the backend is not enabled (Gate 1 not flipped) or a run
    /// is already in flight — the confirm sheet's Clean button is the only caller and it is
    /// disabled in both those states, but the guard keeps the model correct on its own terms too.
    public func confirmClean() {
        guard isBackendEnabled, task == nil else { return }
        run(ids: itemIDs, remainingBytes: requestSummary.totalBytes)
    }

    /// Re-run only the items that failed in the report currently on screen — the "fix permission,
    /// then try again" path (`CleanReportState`). No-op unless the backend is enabled, nothing is
    /// already running, and the current phase is a report that actually has failures.
    public func retryFailed() {
        guard isBackendEnabled, task == nil, case .report(let report) = phase else { return }
        let failed = report.failures
        guard !failed.isEmpty else { return }
        run(ids: Set(failed.map(\.id)), remainingBytes: failed.reduce(0) { $0 + $1.byteCount })
    }

    private func run(ids: Set<String>, remainingBytes: Int64) {
        phase = .running(CleanProgressUpdate(
            remainingBytes: remainingBytes,
            remainingItems: ids.count,
            currentItemCaption: nil
        ))
        let backend = self.backend
        task = Task { [weak self] in
            do {
                for try await event in backend.execute(itemIDs: ids) {
                    guard !Task.isCancelled else { return }
                    self?.apply(event)
                }
            } catch {
                self?.phase = .failed(String(describing: error))
            }
            self?.task = nil
        }
    }

    public func cancel() {
        task?.cancel()
        task = nil
    }

    private func apply(_ event: CleanEvent) {
        switch event {
        case .progress(let update): phase = .running(update)
        case .finished(let report): phase = .report(report)
        }
    }
}
