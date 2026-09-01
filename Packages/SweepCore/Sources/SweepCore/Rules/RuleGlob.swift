import Foundation

/// Relative-path glob matcher for rule patterns and exclusions.
///
/// `*` matches within one path component, `**` matches across components (including none),
/// `?` matches one non-separator character. Everything else is literal. No brace or class
/// syntax: rule authors get a small, auditable vocabulary.
public struct RuleGlob: Sendable, Equatable {
    public let pattern: String
    private let segments: [[Character]]

    public init(_ pattern: String) {
        self.pattern = pattern
        self.segments = pattern
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { Array($0) }
    }

    public func matches(_ relativePath: String) -> Bool {
        let text = relativePath
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        return Self.match(segments, 0, text, 0)
    }

    private static func match(_ pattern: [[Character]], _ p: Int, _ text: [String], _ t: Int) -> Bool {
        if p == pattern.count { return t == text.count }
        let segment = pattern[p]
        if segment.count == 2, segment[0] == "*", segment[1] == "*" {
            // `**` consumes zero or more whole components.
            var consumed = t
            while consumed <= text.count {
                if match(pattern, p + 1, text, consumed) { return true }
                consumed += 1
            }
            return false
        }
        guard t < text.count, matchComponent(segment, Array(text[t])) else { return false }
        return match(pattern, p + 1, text, t + 1)
    }

    /// Classic backtracking wildcard match, bounded to a single path component.
    private static func matchComponent(_ pattern: [Character], _ text: [Character]) -> Bool {
        var p = 0, t = 0
        var starIndex = -1, textMark = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == "?" || pattern[p] == text[t] {
                p += 1
                t += 1
            } else if p < pattern.count, pattern[p] == "*" {
                starIndex = p
                textMark = t
                p += 1
            } else if starIndex >= 0 {
                p = starIndex + 1
                textMark += 1
                t = textMark
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}

extension Rule {
    /// True when `relativePath` (relative to the rule's root) is inside this rule's pattern
    /// and not knocked out by one of its own exclusions.
    public func matches(relativePath: String, itemType: RuleItemType) -> Bool {
        guard itemTypes.contains(itemType) else { return false }
        guard !excludes(relativePath: relativePath) else { return false }
        return RuleGlob(pattern).matches(relativePath)
    }

    /// Exclusions are evaluated against the path and against everything under it, so
    /// `exclusions: ["Homebrew"]` knocks out `Homebrew/**` too.
    public func excludes(relativePath: String) -> Bool {
        for exclusion in exclusions {
            if RuleGlob(exclusion).matches(relativePath) { return true }
            if RuleGlob(exclusion + "/**").matches(relativePath) { return true }
        }
        return false
    }
}
