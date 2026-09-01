import Foundation

/// Every way a catalog can be rejected. Rejection is always total: a catalog with one bad
/// rule does not load in degraded form.
public enum RuleCatalogError: Error, Equatable, CustomStringConvertible {
    case malformedJSON(String)
    case missingField(ruleID: String?, field: String)
    case unknownField(container: String, field: String)
    case unknownValue(ruleID: String?, field: String, value: String)
    case unsupportedSchemaVersion(Int)
    case invalidRuleID(String)
    case duplicateRuleID(String)
    case fieldTooLong(ruleID: String, field: String, limit: Int)
    case emptyItemTypes(ruleID: String)
    case negativeMinimumAge(ruleID: String)
    case invalidGlob(ruleID: String, field: String, glob: String, reason: String)
    case commandRequired(ruleID: String)
    case commandNotAllowed(ruleID: String, action: String)
    case deleteRequiresSafeTier(ruleID: String, tier: String)
    case unreadable(url: URL, reason: String)

    public var description: String {
        switch self {
        case .malformedJSON(let detail):
            "malformed catalog JSON: \(detail)"
        case .missingField(let ruleID, let field):
            "missing required field `\(field)`\(Self.suffix(ruleID))"
        case .unknownField(let container, let field):
            "unknown field `\(field)` in \(container); the schema forbids additional properties"
        case .unknownValue(let ruleID, let field, let value):
            "unknown value `\(value)` for `\(field)`\(Self.suffix(ruleID))"
        case .unsupportedSchemaVersion(let version):
            "unsupported schemaVersion \(version); this build reads \(RuleCatalog.supportedSchemaVersion)"
        case .invalidRuleID(let id):
            "rule id `\(id)` does not match ^[a-z0-9][a-z0-9.-]{2,64}$"
        case .duplicateRuleID(let id):
            "duplicate rule id `\(id)`"
        case .fieldTooLong(let ruleID, let field, let limit):
            "`\(field)` exceeds \(limit) characters\(Self.suffix(ruleID))"
        case .emptyItemTypes(let ruleID):
            "itemTypes must list at least one type\(Self.suffix(ruleID))"
        case .negativeMinimumAge(let ruleID):
            "minAgeDays must be >= 0\(Self.suffix(ruleID))"
        case .invalidGlob(let ruleID, let field, let glob, let reason):
            "`\(field)` glob `\(glob)` rejected (\(reason))\(Self.suffix(ruleID))"
        case .commandRequired(let ruleID):
            "action=commandPreview requires `command`\(Self.suffix(ruleID))"
        case .commandNotAllowed(let ruleID, let action):
            "`command` is only valid with action=commandPreview, not `\(action)`\(Self.suffix(ruleID))"
        case .deleteRequiresSafeTier(let ruleID, let tier):
            "action=delete requires tier=safe, found `\(tier)`\(Self.suffix(ruleID))"
        case .unreadable(let url, let reason):
            "cannot read catalog at \(url.path): \(reason)"
        }
    }

    private static func suffix(_ ruleID: String?) -> String {
        ruleID.map { " (rule `\($0)`)" } ?? ""
    }
}
