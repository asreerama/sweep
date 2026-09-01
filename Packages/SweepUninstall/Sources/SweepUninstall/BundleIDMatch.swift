import Foundation

/// Component-aware reverse-DNS bundle identifier comparison.
///
/// Pearcleaner's real algorithm normalizes both sides with `pearFormat()` (alphanumeric-only,
/// dots stripped) and then does a plain substring `contains` check. That collapses
/// "com.example.foo" to "comexamplefoo", so a leftover named "com.example.foobar" wrongly
/// contains it ("comexamplefoobar".contains("comexamplefoo") == true) — a real false-positive
/// class. `BundleIDMatch` keeps the dot-delimited component structure intact and compares
/// whole components, so a differing final component ("foo" vs "foobar") never matches.
public enum BundleIDMatch {
    /// Splits a reverse-DNS identifier into lowercased dot-separated components.
    public static func components(_ raw: String) -> [String] {
        raw.lowercased().split(separator: ".").map(String.init)
    }

    /// True when `candidate` is exactly `bundleID`, compared component-by-component
    /// (case-insensitive). Component-wise rather than raw string equality only matters for
    /// consistency with `isComponentPrefix` below; for pure equality it is equivalent to a
    /// case-insensitive string compare.
    public static func isExact(_ candidate: String, bundleID: String) -> Bool {
        guard !bundleID.isEmpty, !candidate.isEmpty else { return false }
        return components(candidate) == components(bundleID)
    }

    /// True when `candidate` extends `bundleID` by one or more whole trailing dot-components
    /// — the real-world "helper/agent/daemon" leftover-naming pattern, e.g. a LaunchAgent
    /// named `com.example.foo.helper` for an app whose bundle id is `com.example.foo`.
    ///
    /// Deliberately one-directional (candidate longer than bundleID) and requires the
    /// bundle id to carry real reverse-DNS specificity (>= 2 components) — matching a bare
    /// one-component fragment like "com" against everything would be far too loose. The
    /// reverse direction (a leftover named with fewer components than the bundle id) is not
    /// treated as a prefix match here: it is much weaker evidence (more likely a shared
    /// vendor folder than a specific app) and is handled, where relevant, by the more
    /// conservative shared-container / orphan logic instead.
    public static func isComponentPrefix(_ candidate: String, bundleID: String) -> Bool {
        let c = components(candidate)
        let b = components(bundleID)
        guard b.count >= 2, c.count > b.count else { return false }
        return Array(c.prefix(b.count)) == b
    }
}
