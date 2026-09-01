import Foundation

/// Where the rule catalog and the scan's home directory come from.
///
/// Both are injected once, at the app entry point, and travel down as values. No view knows a
/// path: a screen that hardcoded `~/Library/Caches` would also be the screen nobody could point
/// at a fixture tree, and the fixture tree is how the list gets tested at ten thousand rows.
struct ScanEnvironment: Sendable {
    /// `rules/catalog.json`. Nil when no catalog can be found, which the UI reports rather
    /// than silently scanning nothing.
    let catalogURL: URL?
    /// Home the symbolic operation roots resolve against. Override with `SWEEP_HOME` to scan a
    /// fixture tree from `scripts/make-fixtures.sh` instead of the real account.
    let home: URL
    /// Debug: expose the inventory stress harness in the Toolbox. `SWEEP_UI_STRESS=<rows>`
    /// sets the row count; bare `SWEEP_UI_STRESS=1` means the default ten thousand.
    let showsStressHarness: Bool
    let stressRowCount: Int

    static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> ScanEnvironment {
        let home = environment["SWEEP_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
            ?? FileManager.default.homeDirectoryForCurrentUser
        let stress = environment["SWEEP_UI_STRESS"]
        let rows = stress.flatMap(Int.init).map { $0 > 1 ? $0 : 10_000 } ?? 10_000
        return ScanEnvironment(
            catalogURL: locateCatalog(environment: environment),
            home: home,
            showsStressHarness: stress != nil,
            stressRowCount: rows
        )
    }

    /// Resolution order: explicit override, the signed bundle's read-only copy, then the repo
    /// checkout the executable is sitting in (`swift run` during development).
    private static func locateCatalog(environment: [String: String]) -> URL? {
        if let override = environment["SWEEP_RULES"] {
            let url = URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        if let bundled = Bundle.main.url(forResource: "catalog", withExtension: "json", subdirectory: "rules") {
            return bundled
        }
        var directory = (Bundle.main.executableURL ?? Bundle.main.bundleURL)
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        for _ in 0..<8 {
            let candidate = directory.appending(path: "rules/catalog.json")
            if FileManager.default.isReadableFile(atPath: candidate.path) { return candidate }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
    }
}
