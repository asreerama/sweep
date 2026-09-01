import Foundation
@testable import SweepCore

/// Test-only support for Codex Gate-1 finding #1: `CleanService` no longer accepts a caller
/// catalog, it loads and hash-pins the bundled one itself. Every test that exercises
/// `CleanService`'s real pipeline (`runPipeline`/`execute`) needs to point that internal loader
/// at a fixture directory instead of the app's real `rules/`.
enum BundledCatalogFixture {

    /// Writes `catalog` (plus a placeholder `schema.json` — its *presence*, not its contents, is
    /// all `RuleCatalogLoader.loadBundled` checks; `SchemaDriftTests` is the schema's real
    /// content tripwire) into `root/rules`, then points `CleanService`'s write-once bundled-
    /// catalog directory at it.
    ///
    /// Callers must call `CleanService.resetBundledCatalogDirectoryForTesting()` first (most
    /// conveniently from `setUp()`), since the write-once box only ever accepts the *first*
    /// directory it is given per reset — this is exactly the write-once discipline the real
    /// setter has in production, exercised here so each test gets its own fixture catalog
    /// instead of racing whichever test happened to configure one first in the process.
    @discardableResult
    static func install(_ catalog: RuleCatalog, atRoot root: URL) throws -> URL {
        let directory = root.appending(path: "rules")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: directory.appending(path: "schema.json"))
        let data = try JSONEncoder().encode(catalog)
        try data.write(to: directory.appending(path: "catalog.json"))
        CleanService.configureBundledCatalogDirectory(directory)
        return directory
    }
}
