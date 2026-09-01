import Foundation
import Observation
import SweepCore
import SweepUI

enum ScanPhase: Equatable {
    case idle
    case scanning
    case results
    case failed(String)

    var ringState: ScanRingState {
        switch self {
        case .idle, .failed: .idle
        case .scanning: .scanning
        case .results: .complete
        }
    }
}

/// Screen state for one read-only scan, shared by Smart Scan and System Junk.
///
/// The walk itself runs on the cooperative pool inside `ScanService`; this object only receives
/// throttled ticks and the final outcome. Ticks carry a sequence number because they arrive as
/// independent hops onto the main actor, and a counter that went backwards for one frame would
/// be visible.
@MainActor
@Observable
final class ScanModel {
    private(set) var phase: ScanPhase = .idle
    private(set) var claimedBytes: Int64 = 0
    private(set) var claimedFiles = 0
    private(set) var filesExamined = 0
    private(set) var currentPath: String?
    private(set) var summaryGroups: [InventoryGroup] = []
    private(set) var ruleGroups: [InventoryGroup] = []
    private(set) var skipped: [SkippedLocation] = []
    private(set) var duration: TimeInterval = 0
    private(set) var wasCancelled = false

    /// System Junk selection. Tier-`safe` rows come pre-selected; `caution` and `expert` never
    /// do — the user opts into those, and in this build every path terminates at the Gate 1
    /// notice anyway.
    var selection = InventorySelection()

    private let environment: ScanEnvironment
    private var task: Task<Void, Never>?
    private var lastSequence = 0
    private var lastCounterUpdate = ContinuousClock.now

    init(environment: ScanEnvironment) {
        self.environment = environment
    }

    var hasResults: Bool { phase == .results && !summaryGroups.isEmpty }
    var isScanning: Bool { phase == .scanning }

    var skippedSummary: String? {
        guard !skipped.isEmpty else { return nil }
        let noun = skipped.count == 1 ? "location" : "locations"
        var reasons: [String: Int] = [:]
        for entry in skipped { reasons[entry.reason.summary, default: 0] += 1 }
        let detail = reasons
            .sorted { $0.value > $1.value }
            .map { "\($0.value) \($0.key)" }
            .joined(separator: ", ")
        return "\(skipped.count) \(noun) skipped: \(detail). Sizes below exclude them."
    }

    func start() {
        guard task == nil else { return }
        phase = .scanning
        claimedBytes = 0
        claimedFiles = 0
        filesExamined = 0
        currentPath = nil
        summaryGroups = []
        ruleGroups = []
        skipped = []
        duration = 0
        wasCancelled = false
        lastSequence = 0
        selection = InventorySelection()

        let environment = self.environment
        task = Task { [weak self] in
            let catalog: RuleCatalog
            do {
                catalog = try ScanService.loadCatalog(at: environment.catalogURL)
            } catch {
                self?.fail(String(describing: error))
                return
            }

            // Ticks arrive off the main actor; each one hops back on its own. `weak` unwrapped
            // into a local so the escaping tick closure never captures the mutable weak binding.
            let outcome = await ScanService.run(catalog: catalog, home: environment.home) { [weak self] tick in
                guard let model = self else { return }
                Task { @MainActor in model.apply(tick) }
            }
            self?.finish(outcome)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func rescan() {
        cancel()
        task = nil
        start()
    }

    // MARK: - Updates

    private func apply(_ tick: ScanTick) {
        guard phase == .scanning, tick.sequence > lastSequence else { return }
        lastSequence = tick.sequence
        claimedFiles = tick.claimedFiles
        filesExamined = tick.filesExamined
        currentPath = tick.currentPath

        // The path ticker and the file count are plain text and can move at the tick rate. The
        // hero number cannot: its digit roll is an animation, and re-setting the value before
        // the roll lands restarts it, so the number never resolves. Hold it to one roll's worth.
        let now = ContinuousClock.now
        if now - lastCounterUpdate >= .seconds(SweepMotion.counterCadence) {
            lastCounterUpdate = now
            claimedBytes = tick.claimedBytes
        }
    }

    private func finish(_ outcome: ScanOutcome) {
        task = nil
        claimedBytes = outcome.claimedBytes
        claimedFiles = outcome.claimedFiles
        filesExamined = outcome.filesExamined
        summaryGroups = outcome.summaryGroups
        ruleGroups = outcome.ruleGroups
        skipped = outcome.skipped
        duration = outcome.duration
        wasCancelled = outcome.cancelled
        currentPath = nil
        selection = .safeDefaults(in: outcome.ruleGroups)
        phase = .results
    }

    private func fail(_ message: String) {
        task = nil
        currentPath = nil
        phase = .failed(message)
    }

    // MARK: - Derived copy

    var scanningCaption: String {
        "\(SweepFormat.count(filesExamined)) files examined"
    }

    var resultsCaption: String {
        let locations = summaryGroups.reduce(0) { $0 + $1.itemCount }
        return "\(SweepFormat.count(claimedFiles)) files in \(SweepFormat.count(locations)) locations"
    }
}
