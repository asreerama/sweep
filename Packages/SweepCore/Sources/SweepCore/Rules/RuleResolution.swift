import Foundation
import SweepPolicy

/// Outcome of resolving one path against the catalog.
public enum RuleDecision: Sendable, Equatable {
    /// No rule under this root claims the path.
    case noMatch
    /// An exclusion knocked the path out. Deny-wins: this beats every match.
    case denied(byRuleID: String, exclusion: String)
    /// The winning rule after precedence resolution.
    case matched(Rule)

    public var rule: Rule? {
        if case .matched(let rule) = self { return rule }
        return nil
    }

    public var isDenied: Bool {
        if case .denied = self { return true }
        return false
    }
}

extension RuleItemType {
    /// A rule can only ever describe a file or a directory. A symlink or anything else
    /// (`FileKind.other`) has no ``RuleItemType`` to match against, which is deliberate: nothing
    /// in the catalog authorizes acting on a bare symlink or special file (PLAN §2, rule schema).
    public init?(_ kind: FileKind) {
        switch kind {
        case .file: self = .file
        case .directory: self = .directory
        case .symbolicLink, .other: return nil
        }
    }
}

extension RuleCatalog {

    /// Resolve one path under a symbolic root.
    ///
    /// Deny-wins: if *any* rule for this root excludes the path, the path is denied even when
    /// another rule's pattern matches it. Among survivors the most restrictive tier wins, then
    /// the least destructive action, then the lowest id, so resolution is deterministic and
    /// independent of catalog ordering.
    public func decision(
        forRelativePath relativePath: String,
        root: SweepPolicy.OperationRoot,
        itemType: RuleItemType
    ) -> RuleDecision {
        let scoped = rules(for: root)

        for rule in scoped {
            for exclusion in rule.exclusions {
                if RuleGlob(exclusion).matches(relativePath)
                    || RuleGlob(exclusion + "/**").matches(relativePath) {
                    return .denied(byRuleID: rule.id, exclusion: exclusion)
                }
            }
        }

        let matches = scoped.filter { rule in
            rule.itemTypes.contains(itemType) && RuleGlob(rule.pattern).matches(relativePath)
        }
        guard let winner = matches.min(by: Self.precedes) else { return .noMatch }
        return .matched(winner)
    }

    /// Precedence: stricter tier, then less destructive action, then lowest id.
    private static func precedes(_ lhs: Rule, _ rhs: Rule) -> Bool {
        if lhs.tier != rhs.tier { return lhs.tier > rhs.tier }
        if lhs.action != rhs.action { return lhs.action.destructiveness < rhs.action.destructiveness }
        return lhs.id < rhs.id
    }
}
