import Darwin
import Foundation
import SweepPolicy

/// Why ``AuthorizedCleanPlan`` refused to be built. Never a policy question about *whether* to
/// clean something — that is ``SweepPolicy/SweepPolicy/DenialReason`` — this is about whether the
/// caller's claim ("this candidate, this rule") was actually true.
enum AuthorizationError: Error, Equatable, CustomStringConvertible {
    /// `ruleID` does not name a rule in the catalog the caller passed. The catalog, not the
    /// caller, is the source of truth for what a rule id means (deliverable #1: a rule can only
    /// come from "a validated RuleCatalog rule").
    case unknownRule(String)
    /// The candidate was never stamped with a rule id at all (it was not produced by a
    /// rule-driven scan), so there is nothing to authorize it against.
    case noRuleID
    /// The candidate was stamped with a *different* rule id than the one being authorized.
    /// A candidate scanned for one rule cannot be laundered through another rule's tier/action.
    case candidateRuleMismatch(candidateRuleID: String?, requestedRuleID: String)
    /// The candidate is a symlink or other non-file/non-directory object. No rule can match it:
    /// `RuleItemType` has no case for it.
    case unsupportedItemType(FileKind)
    /// The candidate is not owned by the account running Sweep (finding #9: "verifies owner
    /// UID"). Refused rather than escalated: a file this process does not own is not this
    /// process's business, regardless of what glob matched its path.
    case ownerMismatch(path: String, owner: UInt32)
    /// The candidate is younger than the rule's `minAgeDays` (finding #9: "verifies... age").
    /// Re-checked here independent of whatever age filter a scan request may or may not have
    /// applied — a stale `ScanResult` handed to `CleanService` long after the scan ran must not
    /// let a since-recreated, too-young file slip through on an old timestamp snapshot... and
    /// conversely a *live* re-check based on `candidate.identity.modification` (captured at scan
    /// time) still catches a candidate that was never old enough in the first place.
    case tooYoung(path: String, ruleID: String, minAgeDays: Int)
    /// The rule's `requiresAppNotRunning` bundle id is running right now (finding #9: "verifies...
    /// process state"), checked fresh at authorization time, not at scan time.
    case appIsRunning(bundleID: String, ruleID: String)
    /// The candidate's path, resolved fresh against the rule's symbolic root, is not under any
    /// real location that root names.
    case pathNotUnderRoot(path: String, root: SweepPolicy.OperationRoot)
    /// The candidate's path *is* under the rule's root, but recomputing the catalog's own
    /// deny-wins resolution against it does not produce this rule as the winner (finding #9's
    /// core: the match is recomputed, never merely trusted from a caller-stamped rule id).
    case ruleDidNotMatch(path: String, ruleID: String)
    /// `SweepPolicy.authorize` (or the external-root equivalent) refused the resolved path.
    case policyDenied(SweepPolicy.DenialReason)

    var description: String {
        switch self {
        case .unknownRule(let id):
            "refused: \(id) is not a rule in the catalog"
        case .noRuleID:
            "refused: candidate carries no rule id"
        case .candidateRuleMismatch(let candidateRuleID, let requestedRuleID):
            "refused: candidate carries rule id \(candidateRuleID ?? "nil"), not \(requestedRuleID)"
        case .unsupportedItemType(let kind):
            "refused: \(kind) has no matching rule item type"
        case .ownerMismatch(let path, let owner):
            "refused: \(path) is owned by uid \(owner), not the account running Sweep"
        case .tooYoung(let path, let ruleID, let minAgeDays):
            "refused: \(path) is younger than rule \(ruleID)'s minAgeDays=\(minAgeDays)"
        case .appIsRunning(let bundleID, let ruleID):
            "refused: \(bundleID) is running; rule \(ruleID) requires it not be"
        case .pathNotUnderRoot(let path, let root):
            "refused: \(path) is not under operation root \(root.rawValue)"
        case .ruleDidNotMatch(let path, let ruleID):
            "refused: \(path) does not resolve to rule \(ruleID) when the catalog is asked fresh"
        case .policyDenied(let reason):
            "refused: \(reason)"
        }
    }
}

/// Proof that one candidate may be cleaned, and exactly how.
///
/// This is deliverable #1 (review finding #9). The type is constructible only from inside
/// `SweepCore`, through the two `authorize` factories below, and only from:
///
/// - a rule looked up **by id in the catalog the caller passed** — never a `Rule` value the
///   caller constructed itself, so a forged tier or action can never be smuggled in as "a
///   validated rule";
/// - a ``ScanCandidate`` whose path is proven, freshly, to resolve to that same rule when the
///   catalog's own deny-wins precedence is asked again — not merely trusted from whatever rule id
///   a `ScanRequest` happened to stamp it with;
/// - a ``SweepPolicy`` authorization success for that rule's root and the candidate's identity.
///
/// `tier` and `action` are read from the rule (or, for the code-sign-clone path, from the
/// detector's fixed policy) and cannot be supplied any other way — there is no initializer that
/// takes them as parameters. ``DeletionItem/init(authorized:)`` is the only bridge from this type
/// into something ``DeletionCoordinator`` can execute.
struct AuthorizedCleanPlan: Sendable, Equatable, Identifiable {
    let ruleID: String?
    /// Set only for the code-sign-clone path; mirrors ``CodeSignCloneCandidate/detectorSource``.
    let detectorSource: String?
    let group: RuleGroup
    let tier: Tier
    let action: RuleAction
    let undo: RuleUndo
    let candidate: ScanCandidate
    /// The authorized root, already opened for identity re-check by ``DeletionCoordinator``.
    let anchor: TrashOnlyAnchor
    /// `SweepPolicy`'s policy-normalized spelling of the candidate's path (the resolved root
    /// rebuilt with the original trailing components) — used as `DeletionItem.url` so the
    /// descriptor descent and this authorization always agree about which real object is meant.
    let resolvedPath: URL

    var id: String { candidate.id }

    private init(
        ruleID: String?,
        detectorSource: String?,
        group: RuleGroup,
        tier: Tier,
        action: RuleAction,
        undo: RuleUndo,
        candidate: ScanCandidate,
        anchor: TrashOnlyAnchor,
        resolvedPath: URL
    ) {
        self.ruleID = ruleID
        self.detectorSource = detectorSource
        self.group = group
        self.tier = tier
        self.action = action
        self.undo = undo
        self.candidate = candidate
        self.anchor = anchor
        self.resolvedPath = resolvedPath
    }

    // MARK: - Catalog-rule path

    /// Authorizes `candidate` against the rule named `ruleID` **inside `catalog`**. `catalog` is
    /// the only source of truth for what `ruleID` means; nothing about the rule is taken from
    /// anywhere else.
    static func authorize(
        ruleID: String,
        candidate: ScanCandidate,
        catalog: RuleCatalog,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @Sendable () -> Date = Date.init,
        isRunning: @escaping @Sendable (String) -> Bool = AuthorizedCleanPlan.defaultIsRunning
    ) throws -> AuthorizedCleanPlan {
        guard let rule = catalog[id: ruleID] else {
            throw AuthorizationError.unknownRule(ruleID)
        }
        guard candidate.ruleID == nil || candidate.ruleID == ruleID else {
            throw AuthorizationError.candidateRuleMismatch(candidateRuleID: candidate.ruleID, requestedRuleID: ruleID)
        }
        guard let itemType = RuleItemType(candidate.identity.kind) else {
            throw AuthorizationError.unsupportedItemType(candidate.identity.kind)
        }
        guard candidate.identity.ownerUserID == UInt32(getuid()) else {
            throw AuthorizationError.ownerMismatch(path: candidate.url.path, owner: candidate.identity.ownerUserID)
        }
        if rule.minAgeDays > 0 {
            let age = now().timeIntervalSince(candidate.identity.modification.date)
            let minimum = TimeInterval(rule.minAgeDays) * 86_400
            guard age >= minimum else {
                throw AuthorizationError.tooYoung(path: candidate.url.path, ruleID: rule.id, minAgeDays: rule.minAgeDays)
            }
        }
        if let bundleID = rule.requiresAppNotRunning, isRunning(bundleID) {
            throw AuthorizationError.appIsRunning(bundleID: bundleID, ruleID: rule.id)
        }

        // The core of finding #9: recompute the match, do not trust the stamp. A path under the
        // rule's root is re-resolved to a relative path and handed back to the catalog's own
        // deny-wins precedence; only a `winner.id == rule.id` result counts as a match.
        let roots = SweepPolicy.resolvedRoots(for: rule.root, home: home)
        let path = candidate.url.standardizedFileURL.path
        guard let matchedRoot = roots.first(where: { Self.isUnder(path: path, root: $0) }) else {
            throw AuthorizationError.pathNotUnderRoot(path: path, root: rule.root)
        }
        let relative = Self.relativePath(path: path, root: matchedRoot)
        let decision = catalog.decision(forRelativePath: relative, root: rule.root, itemType: itemType)
        guard case .matched(let winner) = decision, winner.id == rule.id else {
            throw AuthorizationError.ruleDidNotMatch(path: path, ruleID: rule.id)
        }

        let policyDecision = SweepPolicy.authorize(
            root: rule.root,
            resolvedPath: candidate.url,
            identity: candidate.identity.pathIdentity,
            home: home
        )
        guard case .allowed(let authorization) = policyDecision else {
            throw AuthorizationError.policyDenied(
                policyDecision.denialReason ?? .rootUnavailable(rule.root)
            )
        }

        return AuthorizedCleanPlan(
            ruleID: rule.id,
            detectorSource: nil,
            group: rule.group,
            tier: rule.tier,
            action: rule.action,
            undo: rule.undo,
            candidate: candidate,
            anchor: TrashOnlyAnchor(
                key: .operationRoot(rule.root),
                url: authorization.root.url,
                identity: authorization.root.identity
            ),
            resolvedPath: authorization.path
        )
    }

    private static func isUnder(path: String, root: SweepPolicy.ResolvedRoot) -> Bool {
        for spelling in [root.url.path, root.requestedURL.path] {
            let prefix = spelling.hasSuffix("/") ? spelling : spelling + "/"
            if path == spelling || path.hasPrefix(prefix) { return true }
        }
        return false
    }

    private static func relativePath(path: String, root: SweepPolicy.ResolvedRoot) -> String {
        for spelling in [root.url.path, root.requestedURL.path] {
            let prefix = spelling.hasSuffix("/") ? spelling : spelling + "/"
            if path.hasPrefix(prefix) { return String(path.dropFirst(prefix.count)) }
        }
        return ""
    }

    // MARK: - Code-sign-clone path (parallel to the catalog-rule path; deliverable #1c)

    /// Authorizes a code-sign-clone candidate against its own fixed policy (systemJunk / safe /
    /// trash / regenerated — PLAN.md Appendix A), policy-checked against the real clone root
    /// (`$DARWIN_USER_TEMP_DIR/../X`) via ``SweepPolicy/SweepPolicy/authorize(externalRoot:resolvedPath:identity:home:)``.
    /// Every predicate the detector itself already checked at scan time (bundle id from the
    /// directory name, minimum age, not-running) is re-checked here too, fresh — a
    /// `CodeSignCloneCandidate` handed to `CleanService` long after the scan ran must not be
    /// trusted on a stale snapshot of "was old enough" / "was not running".
    static func authorize(
        codeSignClone: CodeSignCloneCandidate,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        now: @Sendable () -> Date = Date.init,
        isRunning: @escaping @Sendable (String) -> Bool = AuthorizedCleanPlan.defaultIsRunning,
        cloneDirectory: () throws -> URL = CodeSignCloneDetector.resolveCloneDirectory
    ) throws -> AuthorizedCleanPlan {
        let candidate = codeSignClone.candidate
        guard candidate.identity.kind == .directory else {
            throw AuthorizationError.unsupportedItemType(candidate.identity.kind)
        }
        guard candidate.identity.ownerUserID == UInt32(getuid()) else {
            throw AuthorizationError.ownerMismatch(path: candidate.url.path, owner: candidate.identity.ownerUserID)
        }
        guard let bundleIdentifier = CodeSignCloneDetector.bundleIdentifier(forCloneNamed: candidate.url.lastPathComponent),
              bundleIdentifier == codeSignClone.bundleIdentifier
        else {
            throw AuthorizationError.ruleDidNotMatch(path: candidate.url.path, ruleID: CodeSignCloneCandidate.detectorSource)
        }
        let age = now().timeIntervalSince(candidate.identity.modification.date)
        guard age >= CodeSignCloneDetector.defaultMinimumAge else {
            throw AuthorizationError.tooYoung(
                path: candidate.url.path,
                ruleID: CodeSignCloneCandidate.detectorSource,
                minAgeDays: 0
            )
        }
        guard !isRunning(bundleIdentifier) else {
            throw AuthorizationError.appIsRunning(bundleID: bundleIdentifier, ruleID: CodeSignCloneCandidate.detectorSource)
        }

        let root: URL
        do {
            root = try cloneDirectory()
        } catch {
            throw AuthorizationError.policyDenied(.malformedPath(String(describing: error)))
        }

        let decision = SweepPolicy.authorize(
            externalRoot: root,
            resolvedPath: candidate.url,
            identity: candidate.identity.pathIdentity,
            home: home
        )
        guard case .allowed(let authorization) = decision else {
            throw AuthorizationError.policyDenied(decision.denialReason ?? .malformedPath(candidate.url.path))
        }

        return AuthorizedCleanPlan(
            ruleID: nil,
            detectorSource: codeSignClone.detectorSource,
            group: codeSignClone.group,
            tier: codeSignClone.tier,
            action: .trash,
            undo: codeSignClone.undo,
            candidate: candidate,
            anchor: TrashOnlyAnchor(
                key: .codeSignCloneRoot,
                url: authorization.rootURL,
                identity: authorization.rootIdentity
            ),
            resolvedPath: authorization.path
        )
    }
}

#if canImport(AppKit)
import AppKit

extension AuthorizedCleanPlan {
    /// The default a real caller gets for free, mirroring ``CodeSignCloneDetector/appKitIsRunning(bundleIdentifier:)``.
    static func defaultIsRunning(bundleIdentifier: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).isEmpty
    }
}
#else
extension AuthorizedCleanPlan {
    static func defaultIsRunning(bundleIdentifier: String) -> Bool { false }
}
#endif
