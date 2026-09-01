import Observation

/// Navigation state plus the one scan every screen reads.
///
/// Lifted out of `RootView` so the selected destination is a real value someone else can set —
/// Smart Scan's "Review items" hands off through it, and the snapshot harness drives the whole
/// shell through it without any screen growing a debug hook of its own.
@MainActor
@Observable
final class AppState {
    var destination: Destination = .smartScan
    let scan: ScanModel
    let environment: ScanEnvironment

    /// Which state `CleanFlowPreviewScreen` (Toolbox debug harness) shows. Lifted out to
    /// `AppState`, same reasoning as `destination`: the snapshot harness drives it externally
    /// without the screen growing a debug hook of its own.
    var cleanFlowPreviewPhase: CleanFlowPreviewPhase = .confirm

    init(environment: ScanEnvironment) {
        self.environment = environment
        self.scan = ScanModel(environment: environment)
    }
}
