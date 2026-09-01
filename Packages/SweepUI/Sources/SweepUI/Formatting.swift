import Foundation

/// Presentation-side formatting. Pure functions, no view state, so the numbers the UI shows
/// are unit-testable without rendering anything.
///
/// Byte counts use decimal units (1 KB = 1000 B), matching Finder and every size the user has
/// ever seen for a file on this machine. Memory is the exception and is formatted by
/// `ByteCountFormatter(.memory)` at its one call site.
public enum SweepFormat {

    static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// Value and unit split apart, for the hero counter which sets them at different sizes.
    ///
    /// Always three significant digits, so the glyph count is stable while the number climbs
    /// and the layout never reflows mid-scan: `9.81 GB` → `48.2 GB` → `482 GB`.
    public static func split(_ bytes: Int64) -> (value: String, unit: String) {
        let negative = bytes < 0
        var magnitude = Double(abs(bytes))
        var unitIndex = 0
        while magnitude >= 1000, unitIndex < units.count - 1 {
            magnitude /= 1000
            unitIndex += 1
        }
        let decimals: Int
        if unitIndex == 0 {
            decimals = 0                    // whole bytes are never fractional
        } else if magnitude < 10 {
            decimals = 2
        } else if magnitude < 100 {
            decimals = 1
        } else {
            decimals = 0
        }
        let text = String(format: "%.\(decimals)f", magnitude)
        return (negative ? "-" + text : text, units[unitIndex])
    }

    /// `"9.81 GB"`. One string, for row and column use.
    public static func bytes(_ bytes: Int64) -> String {
        let parts = split(bytes)
        return "\(parts.value) \(parts.unit)"
    }

    /// `"48,201 items"` / `"1 item"`.
    public static func itemCount(_ count: Int) -> String {
        "\(count.formatted(.number)) \(count == 1 ? "item" : "items")"
    }

    public static func count(_ count: Int) -> String {
        count.formatted(.number)
    }

    /// `/Users/me/Library/Caches/x` → `~/Library/Caches/x`.
    public static func abbreviatingHome(_ path: String, home: String) -> String {
        guard !home.isEmpty else { return path }
        let normalized = home.hasSuffix("/") ? String(home.dropLast()) : home
        if path == normalized { return "~" }
        if path.hasPrefix(normalized + "/") {
            return "~" + path.dropFirst(normalized.count)
        }
        return path
    }

    /// Middle-elided path, keeping the head and the (more informative) tail.
    ///
    /// SwiftUI's `.truncationMode(.middle)` does this at render time and is what the ticker
    /// uses; this exists for the places that need a plain `String` (accessibility labels,
    /// tests, anything measured before layout).
    public static func middleTruncated(_ text: String, limit: Int) -> String {
        guard limit > 1, text.count > limit else { return text }
        let keep = limit - 1
        let tail = keep / 2
        let head = keep - tail
        return text.prefix(head) + "\u{2026}" + text.suffix(tail)
    }
}
