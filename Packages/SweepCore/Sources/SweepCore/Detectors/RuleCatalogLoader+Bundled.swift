import Foundation

/// Convenience for the shape every caller actually has: a directory holding `schema.json` and
/// `catalog.json` side by side (this repo's `rules/` directory, or the app's bundled
/// `Resources/rules` directory). New file, not a change to ``RuleCatalogLoader`` itself, so the
/// existing loader (post-security-review) stays exactly as it was.
extension RuleCatalogLoader {

    public static let bundledSchemaFileName = "schema.json"
    public static let bundledCatalogFileName = "catalog.json"

    /// Loads and validates `directory/catalog.json` exactly as ``load(contentsOf:)`` does.
    ///
    /// The schema itself is never parsed at runtime — the model types encode its constraints
    /// directly (``Rule/validate()``, ``RuleCatalog/validate()``) and `SchemaDriftTests` is the
    /// tripwire that keeps the two in sync — but this requires `schema.json` to be present
    /// alongside the catalog so a directory that is missing half of the pair fails loudly
    /// instead of loading a catalog nobody is actually validated against.
    public static func loadBundled(from directory: URL) throws -> RuleCatalog {
        let schemaURL = directory.appending(path: bundledSchemaFileName)
        guard FileManager.default.fileExists(atPath: schemaURL.path) else {
            throw RuleCatalogError.unreadable(
                url: schemaURL,
                reason: "\(bundledSchemaFileName) not found alongside \(bundledCatalogFileName)"
            )
        }
        return try load(contentsOf: directory.appending(path: bundledCatalogFileName))
    }
}
