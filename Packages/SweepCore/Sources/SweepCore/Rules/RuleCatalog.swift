import Foundation
import SweepPolicy

// Model types mirror rules/schema.json (FROZEN v1, P1). Any change to the schema must be
// mirrored here and vice versa; the loader rejects anything the schema does not allow.

/// Safety tier. Ordered by restrictiveness: `safe` < `caution` < `expert`.
/// Ambiguous rules stay `caution` until a rule-specific audit proves `safe`.
public enum Tier: String, Codable, Sendable, CaseIterable, Comparable {
    case safe
    case caution
    case expert

    /// Higher = more restrictive. Used by deny-wins resolution.
    var restrictiveness: Int {
        switch self {
        case .safe: 0
        case .caution: 1
        case .expert: 2
        }
    }

    public static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.restrictiveness < rhs.restrictiveness }
}

/// Module a rule belongs to.
public enum RuleGroup: String, Codable, Sendable, CaseIterable {
    case systemJunk
    case developer
    case homebrew
    case largeFiles
    case uninstall
    case maintenance
}

/// Filesystem item types a rule may match.
public enum RuleItemType: String, Codable, Sendable, CaseIterable {
    case file
    case directory
}

/// What a rule does with a match. `delete` is only valid on `tier == .safe`;
/// `commandPreview` requires a `command` and never touches the filesystem directly.
public enum RuleAction: String, Codable, Sendable, CaseIterable {
    case trash
    case delete
    case commandPreview

    /// Destructiveness order used by deny-wins resolution (lower = preferred).
    var destructiveness: Int {
        switch self {
        case .commandPreview: 0
        case .trash: 1
        case .delete: 2
        }
    }
}

/// Closed set of typed command adapters. No shell, no caller-supplied arguments.
public enum RuleCommand: String, Codable, Sendable, CaseIterable {
    case brewCleanup
    case brewAutoremove
    case simctlDeleteUnavailable
    case tmutilThin
    case mdutilReindex
    case dnsFlush
}

/// Undo capability advertised to the user.
public enum RuleUndo: String, Codable, Sendable, CaseIterable {
    case trashRestore
    case none
    case regenerated
}

/// One declarative junk-detection rule. Junk detection is data, not code.
public struct Rule: Sendable, Equatable, Codable, Identifiable {
    /// Matches schema pattern `^[a-z0-9][a-z0-9.-]{2,64}$`.
    public let id: String
    public let title: String
    public let group: RuleGroup
    /// Symbolic policy root. Never an absolute path.
    public let root: SweepPolicy.OperationRoot
    /// Fixed relative glob under `root`. No `..`, no leading `/`.
    public let pattern: String
    public let itemTypes: [RuleItemType]
    public let minAgeDays: Int
    /// Bundle id that must not be running, if any.
    public let requiresAppNotRunning: String?
    public let tier: Tier
    public let action: RuleAction
    /// Required iff `action == .commandPreview`; rejected otherwise.
    public let command: RuleCommand?
    /// Undo capability advertised to the user before the operation runs.
    public let undo: RuleUndo
    /// Relative globs never matched within `pattern`. Deny-wins.
    public let exclusions: [String]
    public let rationale: String

    /// Unvalidated memberwise init. Callers building rules in code must call ``validate()``;
    /// every decoding path validates automatically.
    public init(
        id: String,
        title: String,
        group: RuleGroup,
        root: SweepPolicy.OperationRoot,
        pattern: String,
        itemTypes: [RuleItemType],
        minAgeDays: Int = 0,
        requiresAppNotRunning: String? = nil,
        tier: Tier,
        action: RuleAction,
        command: RuleCommand? = nil,
        undo: RuleUndo,
        exclusions: [String] = [],
        rationale: String
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.root = root
        self.pattern = pattern
        self.itemTypes = itemTypes
        self.minAgeDays = minAgeDays
        self.requiresAppNotRunning = requiresAppNotRunning
        self.tier = tier
        self.action = action
        self.command = command
        self.undo = undo
        self.exclusions = exclusions
        self.rationale = rationale
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case id, title, group, root, pattern, itemTypes, minAgeDays
        case requiresAppNotRunning, tier, action, command, undo, exclusions, rationale
    }

    public init(from decoder: any Decoder) throws {
        try RuleCatalogDecoding.rejectUnknownKeys(
            in: decoder,
            known: Set(CodingKeys.allCases.map(\.stringValue)),
            container: "rule"
        )
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let id = try c.decode(String.self, forKey: .id)
        self.id = id
        self.title = try c.decode(String.self, forKey: .title)
        self.group = try RuleCatalogDecoding.decodeEnum(RuleGroup.self, from: c, key: .group, ruleID: id)
        self.root = try RuleCatalogDecoding.decodeEnum(SweepPolicy.OperationRoot.self, from: c, key: .root, ruleID: id)
        self.pattern = try c.decode(String.self, forKey: .pattern)
        self.itemTypes = try RuleCatalogDecoding.decodeEnumArray(RuleItemType.self, from: c, key: .itemTypes, ruleID: id)
        self.minAgeDays = try c.decodeIfPresent(Int.self, forKey: .minAgeDays) ?? 0
        self.requiresAppNotRunning = try c.decodeIfPresent(String.self, forKey: .requiresAppNotRunning)
        self.tier = try RuleCatalogDecoding.decodeEnum(Tier.self, from: c, key: .tier, ruleID: id)
        self.action = try RuleCatalogDecoding.decodeEnum(RuleAction.self, from: c, key: .action, ruleID: id)
        self.command = try RuleCatalogDecoding.decodeOptionalEnum(RuleCommand.self, from: c, key: .command, ruleID: id)
        self.undo = try RuleCatalogDecoding.decodeEnum(RuleUndo.self, from: c, key: .undo, ruleID: id)
        self.exclusions = try c.decodeIfPresent([String].self, forKey: .exclusions) ?? []
        self.rationale = try c.decode(String.self, forKey: .rationale)
        try validate()
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(group, forKey: .group)
        try c.encode(root, forKey: .root)
        try c.encode(pattern, forKey: .pattern)
        try c.encode(itemTypes, forKey: .itemTypes)
        if minAgeDays != 0 { try c.encode(minAgeDays, forKey: .minAgeDays) }
        try c.encodeIfPresent(requiresAppNotRunning, forKey: .requiresAppNotRunning)
        try c.encode(tier, forKey: .tier)
        try c.encode(action, forKey: .action)
        try c.encodeIfPresent(command, forKey: .command)
        try c.encode(undo, forKey: .undo)
        if !exclusions.isEmpty { try c.encode(exclusions, forKey: .exclusions) }
        try c.encode(rationale, forKey: .rationale)
    }

    /// Every schema constraint the JSON Schema keywords express, plus the two cross-field
    /// `allOf` conditions and strictness the loader adds (no stray `command`, no duplicate ids
    /// — the latter checked at catalog level).
    public func validate() throws {
        guard Self.isValidID(id) else { throw RuleCatalogError.invalidRuleID(id) }
        guard title.count <= 80 else {
            throw RuleCatalogError.fieldTooLong(ruleID: id, field: "title", limit: 80)
        }
        guard rationale.count <= 300 else {
            throw RuleCatalogError.fieldTooLong(ruleID: id, field: "rationale", limit: 300)
        }
        guard !itemTypes.isEmpty else { throw RuleCatalogError.emptyItemTypes(ruleID: id) }
        guard minAgeDays >= 0 else { throw RuleCatalogError.negativeMinimumAge(ruleID: id) }
        try Self.validateRelativeGlob(pattern, ruleID: id, field: "pattern")
        for exclusion in exclusions {
            try Self.validateRelativeGlob(exclusion, ruleID: id, field: "exclusions")
        }
        if action == .commandPreview {
            guard command != nil else { throw RuleCatalogError.commandRequired(ruleID: id) }
        } else if command != nil {
            throw RuleCatalogError.commandNotAllowed(ruleID: id, action: action.rawValue)
        }
        if action == .delete, tier != .safe {
            throw RuleCatalogError.deleteRequiresSafeTier(ruleID: id, tier: tier.rawValue)
        }
    }

    /// `^[a-z0-9][a-z0-9.-]{2,64}$`, hand-checked so the loader carries no regex dependency.
    static func isValidID(_ id: String) -> Bool {
        guard (3...65).contains(id.count) else { return false }
        var first = true
        for ch in id.unicodeScalars {
            let isLower = ch >= "a" && ch <= "z"
            let isDigit = ch >= "0" && ch <= "9"
            if first {
                guard isLower || isDigit else { return false }
                first = false
            } else {
                guard isLower || isDigit || ch == "." || ch == "-" else { return false }
            }
        }
        return true
    }

    static func validateRelativeGlob(_ glob: String, ruleID: String, field: String) throws {
        func fail(_ reason: String) -> RuleCatalogError {
            .invalidGlob(ruleID: ruleID, field: field, glob: glob, reason: reason)
        }
        guard !glob.isEmpty else { throw fail("empty") }
        guard !glob.hasPrefix("/") else { throw fail("leading /") }
        guard !glob.contains("\0") else { throw fail("NUL byte") }
        guard !glob.hasPrefix("~") else { throw fail("tilde expansion") }
        let components = glob.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.contains("..") else { throw fail("`..` component") }
        guard !components.dropLast().contains("") else { throw fail("empty path component") }
    }
}

/// A versioned, read-only rule catalog. Ships inside the signed bundle.
public struct RuleCatalog: Sendable, Equatable, Codable {
    public static let supportedSchemaVersion = 1

    public let schemaVersion: Int
    public let rules: [Rule]

    /// Unvalidated memberwise init; ``validate()`` runs on every decoding path.
    public init(schemaVersion: Int = RuleCatalog.supportedSchemaVersion, rules: [Rule]) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }

    enum CodingKeys: String, CodingKey, CaseIterable {
        case schemaVersion, rules
    }

    public init(from decoder: any Decoder) throws {
        try RuleCatalogDecoding.rejectUnknownKeys(
            in: decoder,
            known: Set(CodingKeys.allCases.map(\.stringValue)),
            container: "catalog"
        )
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        self.rules = try c.decode([Rule].self, forKey: .rules)
        try validate()
    }

    public func validate() throws {
        guard schemaVersion == Self.supportedSchemaVersion else {
            throw RuleCatalogError.unsupportedSchemaVersion(schemaVersion)
        }
        var seen = Set<String>()
        for rule in rules {
            try rule.validate()
            guard seen.insert(rule.id).inserted else {
                throw RuleCatalogError.duplicateRuleID(rule.id)
            }
        }
    }

    public subscript(id id: String) -> Rule? {
        rules.first { $0.id == id }
    }

    public func rules(for root: SweepPolicy.OperationRoot) -> [Rule] {
        rules.filter { $0.root == root }
    }
}
