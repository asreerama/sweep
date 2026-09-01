import XCTest
@testable import SweepCore
import SweepPolicy

/// Review finding #9: a `DeletionPlan` used to be self-describing — it carried a tier and an
/// action nobody proved. ``AuthorizedCleanPlan`` closes that: tier and action come from the
/// catalog rule (looked up by id, never a caller-supplied `Rule` value), and every fact the rule
/// depends on — the path actually matching the rule's root and pattern, ownership, age, running
/// state — is recomputed fresh here rather than trusted from whatever a `ScanCandidate` happened
/// to be stamped with.
///
/// `.userLogs` is used throughout rather than `.userCaches`: `SweepPolicy.candidateRootURLs`
/// resolves `.userCaches` from `FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)`
/// unconditionally, ignoring the injected `home:` — the same reason `PolicyTests` never exercises
/// `.userCaches` against a `TemporaryHome`. `.userLogs` (like most other roots) is fully
/// `home`-relative, so a `FixtureHome` genuinely stands in for the real home.
final class AuthorizedCleanPlanTests: XCTestCase {

    // MARK: - Catalog-rule path

    func testMatchingCandidateIsAuthorizedWithTierAndActionFromTheRule() throws {
        let home = try FixtureHome("acp-match")
        try home.write("Library/Logs/SomeApp/blob.log")
        let rule = Self.cautionTrashRule(id: "test.userlogs.caution")
        let catalog = RuleCatalog(rules: [rule])
        let candidate = try home.candidate(at: "Library/Logs/SomeApp", ruleID: rule.id)

        let plan = try AuthorizedCleanPlan.authorize(ruleID: rule.id, candidate: candidate, catalog: catalog, home: home.root)

        XCTAssertEqual(plan.ruleID, rule.id)
        XCTAssertEqual(plan.tier, .caution, "tier came from the rule, not a default")
        XCTAssertEqual(plan.action, .trash, "action came from the rule")
        XCTAssertEqual(plan.candidate.id, candidate.id)
    }

    /// The whole point of finding #9: tier/action are never anything but what the rule says, no
    /// matter what a caller might have wished were true about the candidate.
    func testTierAndActionAreAlwaysTheRulesNeverACallerDefault() throws {
        let home = try FixtureHome("acp-tier-source")
        try home.write("Library/Logs/DeleteMe/blob.log")
        let rule = Rule(
            id: "test.userlogs.delete",
            title: "Delete-action rule",
            group: .systemJunk,
            root: .userLogs,
            pattern: "*",
            itemTypes: [.directory],
            tier: .safe,
            action: .delete,
            undo: .none,
            rationale: "exercises a non-trash action"
        )
        let catalog = RuleCatalog(rules: [rule])
        let candidate = try home.candidate(at: "Library/Logs/DeleteMe", ruleID: rule.id)

        let plan = try AuthorizedCleanPlan.authorize(ruleID: rule.id, candidate: candidate, catalog: catalog, home: home.root)

        XCTAssertEqual(plan.tier, .safe)
        XCTAssertEqual(plan.action, .delete)
    }

    func testUnknownRuleIDIsRefused() throws {
        let home = try FixtureHome("acp-unknown-rule")
        try home.write("Library/Logs/SomeApp/blob.log")
        let catalog = RuleCatalog(rules: [Self.cautionTrashRule(id: "test.real.rule")])
        let candidate = try home.candidate(at: "Library/Logs/SomeApp", ruleID: "test.real.rule")

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(ruleID: "test.forged.rule", candidate: candidate, catalog: catalog, home: home.root)
        ) { error in
            guard case .unknownRule("test.forged.rule") = error as? AuthorizationError else {
                return XCTFail("expected unknownRule, got \(error)")
            }
        }
    }

    func testCandidateStampedForADifferentRuleCannotBeLaunderedThroughAnotherRulesID() throws {
        let home = try FixtureHome("acp-laundering")
        try home.write("Library/Logs/SomeApp/blob.log")
        let safeRule = Self.cautionTrashRule(id: "test.safe.rule", tier: .safe)
        let otherRule = Self.cautionTrashRule(id: "test.other.rule", tier: .safe)
        let catalog = RuleCatalog(rules: [safeRule, otherRule])
        // The scan stamped this candidate for `otherRule`.
        let candidate = try home.candidate(at: "Library/Logs/SomeApp", ruleID: otherRule.id)

        // A caller tries to authorize it against `safeRule` instead.
        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(ruleID: safeRule.id, candidate: candidate, catalog: catalog, home: home.root)
        ) { error in
            guard case .candidateRuleMismatch = error as? AuthorizationError else {
                return XCTFail("expected candidateRuleMismatch, got \(error)")
            }
        }
    }

    /// The core of finding #9: even if a candidate is (incorrectly) stamped with a rule id whose
    /// root has nothing to do with where the candidate actually lives, authorization recomputes
    /// the match and refuses it — the stamp is never trusted on its own.
    func testCandidateWhosePathDoesNotActuallyMatchTheClaimedRuleIsRefused() throws {
        let home = try FixtureHome("acp-path-mismatch")
        try home.writeCanary()
        let rule = Self.cautionTrashRule(id: "test.userlogs.safe", tier: .safe)
        let catalog = RuleCatalog(rules: [rule])

        // A forged candidate: real identity, but the URL is under Application Support (where the
        // VS Code canary lives), not under the rule's `userLogs` root at all — despite claiming
        // `rule.id`.
        let canaryDirectory = home.url("Library/Application Support/Code/User")
        let identity = try FileIdentity.read(at: canaryDirectory)
        let forged = ScanCandidate(url: canaryDirectory, identity: identity, allocatedSize: 0, ruleID: rule.id)

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(ruleID: rule.id, candidate: forged, catalog: catalog, home: home.root)
        ) { error in
            guard case .pathNotUnderRoot = error as? AuthorizationError else {
                return XCTFail("expected pathNotUnderRoot, got \(error)")
            }
        }
        XCTAssertTrue(home.exists("Library/Application Support/Code/User/FIXTURE_CANARY_DO_NOT_DELETE.txt"))
    }

    /// A path that *is* under the rule's root, but not matched by the rule's own pattern/item
    /// type, is refused the same way — the rematch is against the whole rule, not just the root.
    func testCandidateUnderTheRootButOutsideThePatternIsRefused() throws {
        let home = try FixtureHome("acp-pattern-mismatch")
        try home.write("Library/Logs/nested/too/deep/blob.log")
        // Pattern "*" only matches immediate children of the root.
        let rule = Self.cautionTrashRule(id: "test.userlogs.shallow", tier: .safe)
        let catalog = RuleCatalog(rules: [rule])
        let candidate = try home.candidate(at: "Library/Logs/nested/too/deep", ruleID: rule.id)

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(ruleID: rule.id, candidate: candidate, catalog: catalog, home: home.root)
        ) { error in
            guard case .ruleDidNotMatch = error as? AuthorizationError else {
                return XCTFail("expected ruleDidNotMatch, got \(error)")
            }
        }
    }

    func testOwnerMismatchIsRefused() throws {
        let home = try FixtureHome("acp-owner")
        try home.write("Library/Logs/SomeApp/blob.log")
        let rule = Self.cautionTrashRule(id: "test.userlogs.owner", tier: .safe)
        let catalog = RuleCatalog(rules: [rule])
        let real = try home.candidate(at: "Library/Logs/SomeApp", ruleID: rule.id)
        // Same identity, forged ownership.
        let forgedIdentity = FileIdentity(
            deviceID: real.identity.deviceID,
            inode: real.identity.inode,
            volume: real.identity.volume,
            kind: real.identity.kind,
            linkCount: real.identity.linkCount,
            modification: real.identity.modification,
            statusChange: real.identity.statusChange,
            size: real.identity.size,
            flags: real.identity.flags,
            ownerUserID: real.identity.ownerUserID + 1
        )
        let forged = ScanCandidate(
            url: real.url, identity: forgedIdentity, parentIdentity: real.parentIdentity,
            allocatedSize: real.allocatedSize, ruleID: rule.id
        )

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(ruleID: rule.id, candidate: forged, catalog: catalog, home: home.root)
        ) { error in
            guard case .ownerMismatch = error as? AuthorizationError else {
                return XCTFail("expected ownerMismatch, got \(error)")
            }
        }
    }

    func testCandidateYoungerThanMinAgeDaysIsRefused() throws {
        let home = try FixtureHome("acp-too-young")
        try home.write("Library/Logs/App/recent.log")
        let rule = Rule(
            id: "test.userlogs.aged",
            title: "Aged logs",
            group: .systemJunk,
            root: .userLogs,
            pattern: "*/*",
            itemTypes: [.file],
            minAgeDays: 7,
            tier: .safe,
            action: .trash,
            undo: .trashRestore,
            rationale: "only logs older than a week"
        )
        let catalog = RuleCatalog(rules: [rule])
        let candidate = try home.candidate(at: "Library/Logs/App/recent.log", ruleID: rule.id)

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(ruleID: rule.id, candidate: candidate, catalog: catalog, home: home.root)
        ) { error in
            guard case .tooYoung(_, _, let minAgeDays) = error as? AuthorizationError else {
                return XCTFail("expected tooYoung, got \(error)")
            }
            XCTAssertEqual(minAgeDays, 7)
        }
    }

    func testCandidateOldEnoughPassesTheAgeCheck() throws {
        let home = try FixtureHome("acp-old-enough")
        let file = try home.write("Library/Logs/App/old.log")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-30 * 86_400)],
            ofItemAtPath: file.path
        )
        let rule = Rule(
            id: "test.userlogs.aged2",
            title: "Aged logs",
            group: .systemJunk,
            root: .userLogs,
            pattern: "*/*",
            itemTypes: [.file],
            minAgeDays: 7,
            tier: .safe,
            action: .trash,
            undo: .trashRestore,
            rationale: "only logs older than a week"
        )
        let catalog = RuleCatalog(rules: [rule])
        let candidate = try home.candidate(at: "Library/Logs/App/old.log", ruleID: rule.id)

        let plan = try AuthorizedCleanPlan.authorize(ruleID: rule.id, candidate: candidate, catalog: catalog, home: home.root)
        XCTAssertEqual(plan.ruleID, rule.id)
    }

    func testRunningAppPreventsAuthorization() throws {
        let home = try FixtureHome("acp-running")
        try home.write("Library/Logs/SomeApp/blob.log")
        let rule = Rule(
            id: "test.userlogs.notrunning",
            title: "Not running",
            group: .systemJunk,
            root: .userLogs,
            pattern: "*",
            itemTypes: [.directory],
            requiresAppNotRunning: "com.example.SomeApp",
            tier: .safe,
            action: .trash,
            undo: .trashRestore,
            rationale: "requires the app be quit first"
        )
        let catalog = RuleCatalog(rules: [rule])
        let candidate = try home.candidate(at: "Library/Logs/SomeApp", ruleID: rule.id)

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(
                ruleID: rule.id, candidate: candidate, catalog: catalog, home: home.root,
                isRunning: { $0 == "com.example.SomeApp" }
            )
        ) { error in
            guard case .appIsRunning(let bundleID, _) = error as? AuthorizationError else {
                return XCTFail("expected appIsRunning, got \(error)")
            }
            XCTAssertEqual(bundleID, "com.example.SomeApp")
        }

        // And succeeds once the app is not running.
        let plan = try AuthorizedCleanPlan.authorize(
            ruleID: rule.id, candidate: candidate, catalog: catalog, home: home.root,
            isRunning: { _ in false }
        )
        XCTAssertEqual(plan.ruleID, rule.id)
    }

    func testSymlinkCandidateHasNoMatchingItemType() throws {
        let home = try FixtureHome("acp-symlink")
        let target = try home.write("Library/Logs/target.log")
        let link = home.url("Library/Logs/link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        let rule = Self.cautionTrashRule(id: "test.userlogs.symlink", tier: .safe)
        let catalog = RuleCatalog(rules: [rule])
        let identity = try FileIdentity.read(at: link)
        let candidate = ScanCandidate(url: link, identity: identity, allocatedSize: 0, ruleID: rule.id)

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(ruleID: rule.id, candidate: candidate, catalog: catalog, home: home.root)
        ) { error in
            guard case .unsupportedItemType = error as? AuthorizationError else {
                return XCTFail("expected unsupportedItemType, got \(error)")
            }
        }
    }

    func testProtectedAreaIsRefusedEvenWithAClaimedSafeRule() throws {
        let home = try FixtureHome("acp-protected")
        // A rule that would (wrongly) claim to cover Documents if it could ever resolve there.
        let hidden = try home.makeDirectory("Library/Logs/docs")
        try Data("secret".utf8).write(to: hidden.appending(path: "taxes.pdf"))
        try FileManager.default.createSymbolicLink(at: home.url("Documents"), withDestinationURL: hidden)
        let file = hidden.appending(path: "taxes.pdf")

        let rule = Rule(
            id: "test.userlogs.deep",
            title: "Deep",
            group: .systemJunk,
            root: .userLogs,
            pattern: "**",
            itemTypes: [.file],
            tier: .safe,
            action: .trash,
            undo: .trashRestore,
            rationale: "matches anything under logs"
        )
        let catalog = RuleCatalog(rules: [rule])
        let identity = try FileIdentity.read(at: file)
        let candidate = ScanCandidate(url: file, identity: identity, allocatedSize: 0, ruleID: rule.id)

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(ruleID: rule.id, candidate: candidate, catalog: catalog, home: home.root)
        ) { error in
            guard case .policyDenied(.protectedArea(.documents, _)) = error as? AuthorizationError else {
                return XCTFail("expected policyDenied(.protectedArea(.documents)), got \(error)")
            }
        }
    }

    // MARK: - Code-sign-clone path (deliverable #1c)

    func testCodeSignCloneCandidateIsAuthorized() throws {
        let tree = try TempTree("acp-clone-ok")
        let xDirectory = try tree.makeDirectory("X")
        let clone = try tree.makeDirectory("X/com.example.Stale.code_sign_clone")
        try tree.write("X/com.example.Stale.code_sign_clone/payload.bin", bytes: 4_096)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: clone.path
        )
        let detector = CodeSignCloneDetector(isRunning: { _ in false })
        let candidates = try detector.scan(directory: xDirectory)
        let cloneCandidate = try XCTUnwrap(candidates.first)

        let plan = try AuthorizedCleanPlan.authorize(
            codeSignClone: cloneCandidate,
            isRunning: { _ in false },
            cloneDirectory: { xDirectory }
        )

        XCTAssertNil(plan.ruleID)
        XCTAssertEqual(plan.detectorSource, CodeSignCloneCandidate.detectorSource)
        XCTAssertEqual(plan.tier, .safe)
        XCTAssertEqual(plan.action, .trash)
    }

    func testCodeSignCloneBundleIdentifierMismatchIsRefused() throws {
        let tree = try TempTree("acp-clone-mismatch")
        let xDirectory = try tree.makeDirectory("X")
        let clone = try tree.makeDirectory("X/com.example.Stale.code_sign_clone")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: clone.path
        )
        let identity = try FileIdentity.read(at: clone)
        let scanCandidate = ScanCandidate(url: clone, identity: identity, allocatedSize: 0)
        // Forged: claims a bundle id that does not match the directory name.
        let forged = CodeSignCloneCandidate(candidate: scanCandidate, bundleIdentifier: "com.forged.App")

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(codeSignClone: forged, isRunning: { _ in false }, cloneDirectory: { xDirectory })
        ) { error in
            guard case .ruleDidNotMatch = error as? AuthorizationError else {
                return XCTFail("expected ruleDidNotMatch, got \(error)")
            }
        }
    }

    func testCodeSignCloneTooYoungIsRefused() throws {
        let tree = try TempTree("acp-clone-young")
        let xDirectory = try tree.makeDirectory("X")
        let clone = try tree.makeDirectory("X/com.example.Fresh.code_sign_clone")
        // Left at just-created mtime: newer than the minimum age.
        let identity = try FileIdentity.read(at: clone)
        let scanCandidate = ScanCandidate(url: clone, identity: identity, allocatedSize: 0)
        let cloneCandidate = CodeSignCloneCandidate(candidate: scanCandidate, bundleIdentifier: "com.example.Fresh")

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(codeSignClone: cloneCandidate, isRunning: { _ in false }, cloneDirectory: { xDirectory })
        ) { error in
            guard case .tooYoung = error as? AuthorizationError else {
                return XCTFail("expected tooYoung, got \(error)")
            }
        }
    }

    func testCodeSignCloneOfARunningAppIsRefused() throws {
        let tree = try TempTree("acp-clone-running")
        let xDirectory = try tree.makeDirectory("X")
        let clone = try tree.makeDirectory("X/com.example.Running.code_sign_clone")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: clone.path
        )
        let identity = try FileIdentity.read(at: clone)
        let scanCandidate = ScanCandidate(url: clone, identity: identity, allocatedSize: 0)
        let cloneCandidate = CodeSignCloneCandidate(candidate: scanCandidate, bundleIdentifier: "com.example.Running")

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(
                codeSignClone: cloneCandidate,
                isRunning: { $0 == "com.example.Running" },
                cloneDirectory: { xDirectory }
            )
        ) { error in
            guard case .appIsRunning = error as? AuthorizationError else {
                return XCTFail("expected appIsRunning, got \(error)")
            }
        }
    }

    /// Codex G1 finding #7: `candidate.identity` is never trusted for a decision — authorization
    /// re-reads live from disk. A forged owner uid and a forged too-recent mtime (either of
    /// which would otherwise refuse this) are both ignored in favor of the real, live identity.
    func testCodeSignCloneAuthorizationIgnoresAForgedIdentityAndUsesLiveOwnershipAndAge() throws {
        let tree = try TempTree("acp-clone-live-reread")
        let xDirectory = try tree.makeDirectory("X")
        let clone = try tree.makeDirectory("X/com.example.Live.code_sign_clone")
        try tree.write("X/com.example.Live.code_sign_clone/payload.bin", bytes: 1_024)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: clone.path
        )

        let realIdentity = try FileIdentity.read(at: clone)
        let forgedIdentity = FileIdentity(
            deviceID: realIdentity.deviceID, inode: realIdentity.inode, volume: realIdentity.volume,
            kind: realIdentity.kind, linkCount: realIdentity.linkCount,
            // Too recent to pass the age check on its own — the live mtime is what must count.
            modification: FileTimestamp(seconds: Int64(Date().timeIntervalSince1970), nanoseconds: 0),
            statusChange: realIdentity.statusChange, size: realIdentity.size, flags: realIdentity.flags,
            ownerUserID: realIdentity.ownerUserID + 1
        )
        let forgedCandidate = ScanCandidate(url: clone, identity: forgedIdentity, allocatedSize: 0)
        let cloneCandidate = CodeSignCloneCandidate(candidate: forgedCandidate, bundleIdentifier: "com.example.Live")

        let plan = try AuthorizedCleanPlan.authorize(
            codeSignClone: cloneCandidate, isRunning: { _ in false }, cloneDirectory: { xDirectory }
        )

        XCTAssertEqual(
            plan.candidate.identity.ownerUserID, realIdentity.ownerUserID,
            "the plan carries the live identity forward, never the forged one"
        )
        XCTAssertEqual(plan.candidate.identity.modification, realIdentity.modification)
    }

    /// Codex G1 finding #7: a clone nested more than one component below `X` is refused, even
    /// though its own directory name still parses as a plausible clone.
    func testCodeSignCloneNestedMoreThanOneLevelBelowXIsRefused() throws {
        let tree = try TempTree("acp-clone-nested")
        let xDirectory = try tree.makeDirectory("X")
        let nested = try tree.makeDirectory("X/sub/com.example.Nested.code_sign_clone")
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(-3_600)],
            ofItemAtPath: nested.path
        )
        let identity = try FileIdentity.read(at: nested)
        let scanCandidate = ScanCandidate(url: nested, identity: identity, allocatedSize: 0)
        let cloneCandidate = CodeSignCloneCandidate(candidate: scanCandidate, bundleIdentifier: "com.example.Nested")

        XCTAssertThrowsError(
            try AuthorizedCleanPlan.authorize(codeSignClone: cloneCandidate, isRunning: { _ in false }, cloneDirectory: { xDirectory })
        ) { error in
            guard case .notDirectChildOfCloneRoot = error as? AuthorizationError else {
                return XCTFail("expected notDirectChildOfCloneRoot, got \(error)")
            }
        }
    }

    // MARK: - Helpers

    static func cautionTrashRule(id: String, tier: Tier = .caution) -> Rule {
        Rule(
            id: id,
            title: "Test rule",
            group: .systemJunk,
            root: .userLogs,
            pattern: "*",
            itemTypes: [.directory],
            tier: tier,
            action: .trash,
            undo: .trashRestore,
            rationale: "fixture rule for AuthorizedCleanPlanTests"
        )
    }
}
