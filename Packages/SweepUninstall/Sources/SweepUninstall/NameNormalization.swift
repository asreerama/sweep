import Foundation

/// String-normalization helpers used throughout matching.
///
/// `alphanumeric` ports the idea behind Pearcleaner's `pearFormat()` (lowercase,
/// alphanumeric-only) but it is deliberately used ONLY for free-text name comparison
/// (app display names, path stems). Bundle-identifier comparison never goes through it,
/// because collapsing the dots destroys the reverse-DNS component structure and is exactly
/// what lets "com.example.foobar" collide with "com.example.foo" under naive substring
/// matching. See `BundleIDMatch` for the component-aware comparison used there instead.
public enum NameNormalization {
    /// Lowercased, alphanumeric-only normalization. Non-letter/digit characters (spaces,
    /// punctuation, dashes, dots) are dropped entirely.
    public static func alphanumeric(_ s: String) -> String {
        String(s.unicodeScalars.lazy
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(Character.init))
            .lowercased()
    }

    /// The filename stem (last path component, extension removed) — e.g. the "Xcode" in
    /// `/Applications/Xcode.app`.
    public static func stem(of url: URL) -> String {
        url.deletingPathExtension().lastPathComponent
    }
}
