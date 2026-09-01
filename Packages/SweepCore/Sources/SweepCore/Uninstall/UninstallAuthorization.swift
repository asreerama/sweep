import Foundation
import SweepPolicy
import SweepUninstall

// MARK: - Gate U (PLAN §3 module 5, §6 "Explicit destructive-release gate before every module
// that can mutate disk"): app-removal authorization.
//
// This mirrors Gate 1's `AuthorizedCleanPlan` architecture end to end, for exactly the reason
// PLAN §3 module 5 gives for why app removal cannot be a catalog rule: "No macOS API lists an
// app's files; glob-over-known-locations is what every uninstaller uses," and the per-item
// predicates involved (is this really the app the caller claims, is it running, does another
// installed app also plausibly own this leftover) are dynamic, not a fixed relative glob a
// `RuleCatalog` rule can express. Gate 1 solved the analogous problem for the code-sign-clone
// detector (`AuthorizedCleanPlan.authorize(codeSignClone:)`, `SweepPolicy.authorize(externalRoot:)`)
// — this is that same shape, generalized to many external roots instead of one, and to leftover
// evidence instead of a fixed per-item predicate set.
//
// Trust boundary, stated once: nothing about "which app," "is it safe to remove," or "does this
// leftover really belong to it" is ever taken from the caller. `UninstallModel` (SweepApp,
// read-only today) already duplicates a *client-side* version of the protected-app check
// (`UninstallLogic.isProtected`) purely for UI responsiveness (greying out a row, showing a
// lock) — PLAN §2 is explicit that UI checks are never authoritative, so every one of those
// checks (Apple-signed heuristic, system location, Sweep-itself, `com.apple.` bundle-id prefix,
// `SweepPolicy` denylist) is re-derived here, server-side, from data this authorization reads
// itself, and the leftover evidence a caller selects by path is independently recomputed via
// `SweepUninstall.LeftoverMatcher` against a live-verified `InstalledApp` — never trusted from
// any `LeftoverCandidate.evidence`/`.confidence` value a caller could otherwise construct
// directly (both are public stored/derived properties on a publicly-constructible struct;
// trusting them would be the exact "self-asserted tier" hole Gate 1 finding #1 closed for
// `DeletionItem`, reopened for uninstall).

/// Why ``AuthorizedUninstallPlan`` refused to be built, or why one specific leftover selection
/// could not be admitted into it. Bundle-level cases void the whole plan (there is no such thing
/// as "leftovers for an app we refuse to call the target"); leftover-level cases only settle that
/// one selection, exactly like a hard filter in `CleanService`.
enum UninstallAuthorizationError: Error, Equatable, CustomStringConvertible {
    // MARK: Bundle-level (void the whole plan)
    case bundleNotFound(path: String)
    case bundleIdentifierUnreadable(path: String)
    case bundleIdentifierMismatch(expected: String, found: String?)
    case protectedAppleBundleIdentifier(String)
    case protectedSystemLocation(path: String)
    case lexicallyDenied(path: String)
    case appIsRunning(bundleIdentifier: String)
    case applicationsRootUnavailable(reason: SweepPolicy.DenialReason?)
    /// Codex Gate-U finding #5: the path is not a real, validated `.app` bundle — a symlink
    /// leaf (accepted by `SweepPolicy.authorize(externalRoot:)`'s own containment proof, which
    /// never type-checks the leaf itself), a missing `.app` extension, a missing/non-directory
    /// `Contents`, a missing/non-regular `Contents/Info.plist`, or `CFBundlePackageType != APPL`.
    /// A system-resolving symlink (macOS cryptex-relocated apps) is refused earlier, by
    /// ``protectedSystemLocation``, before this check ever runs — this exists for everything
    /// else, most importantly a non-system planted symlink.
    case bundleStructureInvalid(path: String, reason: String)
    /// Codex Gate-U finding #4: the fresh, immediately-pre-staging revalidation
    /// (``AuthorizedUninstallPlan/revalidateBundleImmediatelyBeforeStaging(_:expectedBundleIdentifier:isRunning:)``)
    /// found the bundle's signature no longer validates end to end. Distinct from
    /// ``bundleStructureInvalid``/``bundleIdentifierMismatch`` (which can also fire here) so the
    /// specific "someone modified a sealed resource after we authorized this" case is
    /// unambiguous in the report.
    case bundleSignatureInvalidAtStaging(path: String)

    // MARK: Leftover-level (settle just that one selection)
    /// The re-derived matcher output has nothing at this path at all, or only an excluded root
    /// (`pkgReceipt`/`libraryLaunchDaemons` — never trashed by Gate U v1; see
    /// ``AuthorizedUninstallPlan/excludedLeftoverRoots``). A caller-selected path that the
    /// independent re-derivation does not itself confirm is refused exactly like a forged rule id
    /// in Gate 1: recomputed, never trusted.
    case leftoverNotIndependentlyMatched(path: String)
    /// Recomputed evidence is `MatchConfidence.manualReview` and the caller did not set
    /// `UninstallRequest.manualOverrideConfirmedPaths` for this exact path.
    case leftoverManualConfirmationRequired(path: String)
    case leftoverIdentityUnreadable(path: String)
    case leftoverPolicyDenied(path: String, reason: SweepPolicy.DenialReason)

    var description: String {
        switch self {
        case .bundleNotFound(let path):
            "refused: \(path) does not exist"
        case .bundleIdentifierUnreadable(let path):
            "refused: \(path) has no readable CFBundleIdentifier"
        case .bundleIdentifierMismatch(let expected, let found):
            "refused: \(expected) does not match the bundle's live identifier (\(found ?? "nil"))"
        case .protectedAppleBundleIdentifier(let bundleID):
            "refused: \(bundleID) is in Apple's reserved com.apple. namespace"
        case .protectedSystemLocation(let path):
            "refused: \(path) resolves under a protected system location"
        case .lexicallyDenied(let path):
            "refused: \(path) is under SweepPolicy's denylist"
        case .appIsRunning(let bundleID):
            "refused: \(bundleID) is running"
        case .applicationsRootUnavailable(let reason):
            "refused: no Applications root authorizes this bundle (\(reason?.description ?? "none resolved"))"
        case .bundleStructureInvalid(let path, let reason):
            "refused: \(path) is not a validated app bundle (\(reason))"
        case .bundleSignatureInvalidAtStaging(let path):
            "refused: \(path) failed fresh signature revalidation immediately before bundle staging"
        case .leftoverNotIndependentlyMatched(let path):
            "refused: \(path) was not independently matched by the re-derived leftover evidence"
        case .leftoverManualConfirmationRequired(let path):
            "refused: \(path) needs an explicit per-item manual confirmation before it can be authorized"
        case .leftoverIdentityUnreadable(let path):
            "refused: \(path) could not be read live"
        case .leftoverPolicyDenied(let path, let reason):
            "refused: \(path) — \(reason)"
        }
    }
}

/// Proof that a leftover needing human review (`MatchConfidence.manualReview`) was admitted only
/// because the caller explicitly confirmed *this exact item*, not a blanket "confirm everything."
///
/// "Minted by the same authorization" (PLAN task spec): this is never something a caller mints
/// ahead of time and replays — ``AuthorizedUninstallPlan/authorize(request:operationID:isRunning:now:receipts:protectedLocationPrefixes:)``
/// is the only place one is ever constructed, and only when it has already independently
/// recomputed non-empty evidence for the path *and* found the path present in
/// `UninstallRequest.manualOverrideConfirmedPaths`. It carries no capability of its own — it is
/// audit provenance, surfaced back to the caller via `CleanItemOutcome.detectorSource`/`.detail`
/// (see `UninstallService.swift`), never a token a caller can present to skip re-derivation.
struct ManualOverrideToken: Sendable, Equatable {
    /// The caller's own selection string — kept only as an audit label for what the caller
    /// originally named. Codex Gate-U finding #6: never itself trusted as an identity, and never
    /// what the durable record below binds confirmation to.
    let callerPath: String
    /// The independently-matched candidate's own canonical path (`LeftoverCandidate.id`) —
    /// finding #6's "bind confirmation to the canonical matched identity, not the caller
    /// string." This, not `callerPath`, is what ``ManualConsentProvenance`` and the WAL record.
    let canonicalPath: String
    let identity: FileIdentity
    let mintedAt: Date
    let operationID: UUID
    /// Codex Gate-U finding #2: an unguessable, single-use receipt minted exactly once, here, the
    /// moment this specific item is admitted — never re-derived from `manualOverrideConfirmedPaths`
    /// at any later point, and never something a caller can mint or supply themselves (there is no
    /// public initializer for this type outside `AuthorizedUninstallPlan.authorize`).
    let nonce: UUID
}

/// Codex Gate-U finding #2: the durable proof, persisted into the `planned` WAL record via
/// ``DeletionItem``/``JournalItem``, of why one manual-review leftover was admitted. Before this,
/// `ManualOverrideToken` was minted at authorization time and then discarded the moment
/// ``AuthorizedUninstallItem/deletionItem`` built a plain `DeletionItem` — after a crash, the WAL
/// could show a weakly-matched item moved, but nothing durable explained why it had been allowed
/// to. This closes that gap: every field a person or a recovery tool would need to audit the
/// decision, without replaying `UninstallRequest.manualOverrideConfirmedPaths` (an ephemeral,
/// in-memory-only caller value that never reaches the WAL at all).
public struct ManualConsentProvenance: Sendable, Equatable, Codable {
    /// Schema version for this provenance shape, so a future change to what gets recorded can
    /// tell an old journal line apart from a new one instead of guessing.
    public static let currentVersion = 1

    /// Compact evidence tag (`OwnershipEvidence.journalTag`) — e.g. `"nameMatch"` or
    /// `"exactBundleID"` for an item that was capped to manual review despite strong evidence
    /// (Codex Gate-U finding #1: an unsigned/unverified bundle, or an incomplete inventory scan,
    /// caps every leftover at manual review regardless of how strong its own evidence looks).
    public let evidenceTag: String
    /// Why this item needed manual review at all: either the evidence itself was only ever
    /// `manualReview`-tier, or stronger evidence was capped down. Free text, for audit reading,
    /// never parsed back by anything.
    public let reviewReason: String
    /// The matcher's own canonical path for this object (finding #6) — never the caller's raw
    /// selection string.
    public let canonicalPath: String
    public let identity: FileIdentity
    public let manualConfirmed: Bool
    public let confirmedAt: Date
    /// The same single-use nonce minted in `authorize()` — an operation-bound receipt, not a
    /// second, independent check against a caller-supplied string set.
    public let nonce: UUID
    public let operationID: UUID
    public let authorizationVersion: Int

    init(evidence: OwnershipEvidence, reviewReason: String, token: ManualOverrideToken) {
        self.evidenceTag = evidence.journalTag
        self.reviewReason = reviewReason
        self.canonicalPath = token.canonicalPath
        self.identity = token.identity
        self.manualConfirmed = true
        self.confirmedAt = token.mintedAt
        self.nonce = token.nonce
        self.operationID = token.operationID
        self.authorizationVersion = Self.currentVersion
    }
}

/// Codex Gate-U finding #1: the only admissible proof that a live filesystem object really is the
/// specific signed app it claims to be. Never constructible except through ``verify(bundleURL:liveBundleIdentifier:)``,
/// which requires all of: an identity-pinned read (the caller already did this — `bundleURL` is
/// always a path this authorization itself resolved, never a raw caller string), a full
/// end-to-end `SecStaticCodeCheckValidity` pass (``SweepUninstall/SigningInfoReader/readVerified(at:)``
/// — NOT the cheap header-only read `AppInventory` uses during a full-disk scan), a non-empty
/// signing identifier, and proof that identifier agrees with the bundle's own live
/// `CFBundleIdentifier`.
///
/// That last check is what actually closes the hole: a planted app can trivially set
/// `CFBundleIdentifier` in its `Info.plist` to any string it likes, but it cannot make its own
/// code signature's `kSecCodeInfoIdentifier` equal an id it was never signed under — `codesign`
/// derives that identifier from the bundle id at signing time, and forging it would mean forging
/// the signature itself. An exact-bundle-id leftover match is only as trustworthy as the bundle
/// identity it is attributed to; without one of these, that identity is nothing more than an
/// unvalidated `Info.plist` string.
struct VerifiedBundle: Sendable, Equatable {
    let bundleIdentifier: String
    let signingIdentifier: String
    let teamIdentifier: String?
    let isAppleSigned: Bool

    /// `nil` whenever the bundle is unsigned, ad-hoc-with-no-identifier, fails full validity
    /// checking, or its signing identifier disagrees with its own live bundle id — every one of
    /// which means "this object cannot be cryptographically vouched for as the app it claims to
    /// be," never merely "this object could not be classified."
    static func verify(bundleURL: URL, liveBundleIdentifier: String) -> VerifiedBundle? {
        guard let signing = SigningInfoReader.readVerified(at: bundleURL), signing.isValiditySealed,
              let signingIdentifier = signing.signingIdentifier, !signingIdentifier.isEmpty,
              signingIdentifier == liveBundleIdentifier
        else { return nil }
        return VerifiedBundle(
            bundleIdentifier: liveBundleIdentifier,
            signingIdentifier: signingIdentifier,
            teamIdentifier: signing.teamIdentifier,
            isAppleSigned: signing.isAppleSigned
        )
    }
}

/// One item — the bundle, or one admitted leftover — inside an ``AuthorizedUninstallPlan``.
/// Internal-only, exactly like `AuthorizedCleanPlan`: constructible only from
/// ``AuthorizedUninstallPlan/authorize(request:operationID:isRunning:now:receipts:protectedLocationPrefixes:)``,
/// never directly, so a caller cannot stamp its own tier/evidence/override and have
/// `UninstallService` mistake it for something this authorization actually proved.
struct AuthorizedUninstallItem: Sendable, Equatable, Identifiable {
    enum Role: Sendable, Equatable {
        /// `wasVerified`: whether the bundle already had a ``VerifiedBundle`` at authorization
        /// time. Codex Gate-U finding #1 explicitly keeps an unsigned/invalid app's bundle itself
        /// explicitly trashable — only its leftovers are affected — so
        /// ``AuthorizedUninstallPlan/revalidateBundleImmediatelyBeforeStaging(_:expectedBundleIdentifier:isRunning:)``
        /// (finding #4) must never newly demand a signature that was never there to begin with;
        /// it only refuses a *regression* — a bundle that WAS verifiable and no longer is.
        case bundle(wasVerified: Bool)
        case leftover(evidence: OwnershipEvidence, manualOverride: ManualOverrideToken?)
    }

    let role: Role
    /// Live-re-read identity (never anything a caller asserted) plus the path this authorization
    /// resolved. `ruleID` is always `nil`: nothing here was ever resolved against `RuleCatalog`.
    let candidate: ScanCandidate
    let anchor: TrashOnlyAnchor
    /// `SweepPolicy`'s policy-normalized spelling of the path, mirroring
    /// `AuthorizedCleanPlan.resolvedPath` — used as `DeletionItem.url` so the descriptor descent
    /// and this authorization always agree about which real object is meant.
    let resolvedPath: URL

    var id: String { candidate.id }

    /// Advisory only in trash-only mode (`DeletionCoordinator.validate` only gates `tier` for
    /// `action == .delete`, and Gate U is trash-only, always) — carried purely so the bridged
    /// report can surface "this needed an explicit override" as `.caution` the way a catalog rule
    /// would.
    var reportedTier: Tier {
        switch role {
        case .bundle: .caution
        case .leftover(_, let override): override == nil ? .safe : .caution
        }
    }

    /// The bridge into something `DeletionCoordinator` can execute — the uninstall-path
    /// counterpart of `DeletionItem.init(authorized: AuthorizedCleanPlan)`. `ruleID` stays `nil`
    /// on purpose (see the type's own doc comment: "Rule that claimed this path, when the scan
    /// was rule-driven" — nothing here ever was); most of Gate U's own provenance (role, plain
    /// evidence tag) is still carried only at this layer and at `CleanItemOutcome`, exactly how
    /// the code-sign-clone path keeps `detectorSource` off `DeletionItem`/`JournalItem` entirely.
    ///
    /// Codex Gate-U finding #2 is the one deliberate exception: a manual-review admission's
    /// ``ManualOverrideToken`` — previously minted here and then discarded — is now carried all
    /// the way into `DeletionItem.manualConsentProvenance` and, from there, into the durable
    /// `planned` WAL record via `JournalItem`. That is the only path where an explicit,
    /// per-item human decision changes what authorization allows, so it is the only provenance
    /// that must survive a crash, not just outlive this in-memory report.
    var deletionItem: DeletionItem {
        var provenance: ManualConsentProvenance?
        if case .leftover(let evidence, .some(let token)) = role {
            let reason = evidence.contains(.exactBundleID) || evidence.contains(.receiptListed)
                ? "evidence normally auto-selectable (\(evidence.journalTag)) but capped to manual review"
                : "evidence \(evidence.journalTag) is manual-review tier"
            provenance = ManualConsentProvenance(evidence: evidence, reviewReason: reason, token: token)
        }
        return DeletionItem(
            url: resolvedPath,
            identity: candidate.identity,
            parentIdentity: candidate.parentIdentity,
            action: .trash,
            tier: reportedTier,
            allocatedSize: candidate.allocatedSize,
            ruleID: nil,
            manualConsentProvenance: provenance
        )
    }
}

/// Proof that one app bundle, plus zero or more of its leftovers, may be sent to
/// `DeletionCoordinator`'s trash-only machinery. Constructible only through
/// ``authorize(request:operationID:isRunning:now:receipts:protectedLocationPrefixes:)``.
struct AuthorizedUninstallPlan: Sendable {
    struct UnresolvedLeftover: Sendable {
        let path: String
        let error: UninstallAuthorizationError
    }

    let bundle: AuthorizedUninstallItem
    let leftovers: [AuthorizedUninstallItem]
    /// Leftover selections that could not be admitted — reported as settled outcomes, never
    /// silently dropped, mirroring `CleanService`'s `settled` list.
    let unresolvedLeftovers: [UnresolvedLeftover]

    /// Roots `SweepUninstall.LeftoverMatcher` may find evidence under, but Gate U v1 never
    /// admits into an actual plan: `.pkgReceipt` (trashing a receipt plist without
    /// `pkgutil --forget` accomplishes nothing and PLAN §3 module 5 forbids "`pkgutil --forget`
    /// as implicit cleanup" outright), `.libraryLaunchDaemons` (root-owned; needs the
    /// privileged helper's `launchctl bootout` integration PLAN §3 module 5 already calls out as
    /// a prerequisite — "requires privileged launchctl bootout handling, never a plain delete" is
    /// `OwnershipEvidence.launchDaemon`'s own doc comment), and `.launchAgents` (Codex Gate-U
    /// finding #3: a *loaded* LaunchAgent must be stopped with `launchctl bootout gui/<uid>/<label>`
    /// before its plist is safe to remove — trashing a loaded agent's plist out from under
    /// `launchd` leaves the in-memory job running with no on-disk definition. This wave adds no
    /// bootout adapter at all, so every LaunchAgents entry stays manual-tier and excluded here
    /// until a typed, fixed-path bootout adapter exists and can confirm the job actually stopped;
    /// it "arrives with helper," per the task spec, not in this change). All three roots still
    /// count toward evidence computation (a receipt or a LaunchAgent can corroborate a
    /// *different*, admissible leftover's evidence), just never toward what actually gets
    /// admitted here.
    static let excludedLeftoverRoots: Set<SearchRoot> = [.pkgReceipt, .libraryLaunchDaemons, .launchAgents]

    /// Task item 2's ordering contract, achieved with zero new `DeletionCoordinator` logic:
    /// leftovers first, bundle last. `DeletionCoordinator.execute` already processes `plan.items`
    /// in array order and already stops immediately — before any later item is ever attempted —
    /// the moment a quarantine-lifecycle journal append degrades (Codex G1 finding #1). Ordering
    /// this array leftovers-first means that existing, unmodified stop-on-degrade behavior *is*
    /// "bundle only if all its leftovers settled without journaling degradation": if a leftover
    /// degrades the journal, the coordinator returns before the bundle entry — the last one in
    /// this array — is ever reached.
    var orderedItems: [AuthorizedUninstallItem] { leftovers + [bundle] }

    /// One anchor per distinct real root across every admitted item, deduplicated by
    /// `TrashOnlyAnchor.key` the same way `CleanService.run` deduplicates `AuthorizedCleanPlan`
    /// anchors before constructing `DeletionMode.trashOnly`.
    var anchors: [TrashOnlyAnchor] {
        var byKey: [TrashAnchorKey: TrashOnlyAnchor] = [:]
        for item in orderedItems { byKey[item.anchor.key] = item.anchor }
        return Array(byKey.values)
    }

    /// The whole authorization gauntlet. Throws (voiding the entire plan) only for a bundle-level
    /// refusal; a leftover-level refusal is collected into `unresolvedLeftovers` and never stops
    /// the bundle or any other leftover from being considered.
    static func authorize(
        request: UninstallRequest,
        operationID: UUID,
        isRunning: @escaping @Sendable (String) -> Bool,
        now: @Sendable () -> Date = Date.init,
        receipts: PkgutilReceiptsProviding = PkgutilReceiptsProvider(),
        // Test seam only (mirrors `home:`/`applicationsDirectories:` on `UninstallRequest`
        // itself): production always uses the real, hardcoded `["/System/"]`. Never anything a
        // real caller can widen or narrow — there is no public route to this parameter.
        protectedLocationPrefixes: [String] = ["/System/"]
    ) throws -> AuthorizedUninstallPlan {
        let bundleItem = try authorizeBundle(
            request: request, isRunning: isRunning, protectedLocationPrefixes: protectedLocationPrefixes
        )

        let (leftovers, unresolved) = authorizeLeftovers(request: request, operationID: operationID, now: now, receipts: receipts)

        return AuthorizedUninstallPlan(bundle: bundleItem, leftovers: leftovers, unresolvedLeftovers: unresolved)
    }

    // MARK: - Bundle verification

    /// "The target app's live-verified bundle (lstat identity, Info.plist bundle id match, NOT
    /// running, NOT protected...)" — every check here reads live, right now; none of it trusts
    /// anything the caller merely asserts about the app beyond *which path and which id it
    /// believes this is*.
    private static func authorizeBundle(
        request: UninstallRequest,
        isRunning: @escaping @Sendable (String) -> Bool,
        protectedLocationPrefixes: [String]
    ) throws -> AuthorizedUninstallItem {
        let bundlePath = request.bundlePath.standardizedFileURL

        // 1. Live identity. `lstat`, never `stat`: a macOS 26 cryptex-relocated system bundle is
        // itself a symlink (see `AppInventory`'s own extensive comments on real Safari.app on
        // this exact class of machine) — kind is not gated here for that reason; only existence.
        let bundleIdentity: FileIdentity
        do {
            bundleIdentity = try FileIdentity.read(at: bundlePath)
        } catch {
            throw UninstallAuthorizationError.bundleNotFound(path: bundlePath.path)
        }

        // 2. Info.plist bundle id, read fresh — never the caller's claim about it, only cross-
        // checked against the caller's claim.
        guard let liveBundleIdentifier = Bundle(url: bundlePath)?.bundleIdentifier, !liveBundleIdentifier.isEmpty else {
            throw UninstallAuthorizationError.bundleIdentifierUnreadable(path: bundlePath.path)
        }
        guard liveBundleIdentifier == request.expectedBundleIdentifier else {
            throw UninstallAuthorizationError.bundleIdentifierMismatch(
                expected: request.expectedBundleIdentifier, found: liveBundleIdentifier
            )
        }

        // 3. NOT protected — duplicated server-side (PLAN task spec), never trusting
        // `UninstallLogic.isProtected`'s client-side copy of the same idea.
        guard !UninstallProtection.isAppleBundleIdentifier(liveBundleIdentifier) else {
            throw UninstallAuthorizationError.protectedAppleBundleIdentifier(liveBundleIdentifier)
        }
        guard !UninstallProtection.isUnderSystemLocation(bundlePath, prefixes: protectedLocationPrefixes) else {
            throw UninstallAuthorizationError.protectedSystemLocation(path: bundlePath.path)
        }
        guard !SweepPolicy.isDeniedLexically(bundlePath, home: request.home) else {
            throw UninstallAuthorizationError.lexicallyDenied(path: bundlePath.path)
        }

        // 3.5. Bundle-object validation (Codex Gate-U finding #5): a real directory, `.app`
        // extension, `CFBundlePackageType == APPL`, and a validated `Contents/Info.plist`
        // structure. Placed AFTER the protected-location check on purpose: a macOS
        // cryptex-relocated system bundle is legitimately a symlink and is already refused above
        // by `protectedSystemLocation` (or the Apple-namespace check) — this exists for
        // everything `SweepPolicy.authorize(externalRoot:)`'s own leaf-agnostic containment proof
        // would otherwise silently accept, most importantly a non-system planted symlink.
        if let structureError = validateBundleStructure(bundlePath: bundlePath, identity: bundleIdentity) {
            throw structureError
        }

        // 4. NOT running.
        guard !isRunning(liveBundleIdentifier) else {
            throw UninstallAuthorizationError.appIsRunning(bundleIdentifier: liveBundleIdentifier)
        }

        // Codex Gate-U finding #4's baseline: recorded now so the immediately-pre-staging
        // revalidation can tell "never signed" (fine — finding #1 keeps an unsigned bundle
        // explicitly trashable) apart from "was verified, and no longer is" (a real regression).
        let wasVerified = VerifiedBundle.verify(bundleURL: bundlePath, liveBundleIdentifier: liveBundleIdentifier) != nil

        // 5. Confined to a real Applications root — `SweepPolicy.authorize(externalRoot:)` proves
        // symlink-free containment, volume-boundary safety and the full protected-area denylist
        // (Documents/Desktop/.../SweepItself/SystemApps) on resolved identity, exactly like the
        // code-sign-clone detector's own root. Unlike a symbolic `OperationRoot`, `/System/
        // Applications` is never one of the roots tried here at all, so it is refused
        // structurally, not merely by policy.
        var lastDenial: SweepPolicy.DenialReason?
        for directory in request.applicationsDirectories {
            let decision = SweepPolicy.authorize(
                externalRoot: directory, resolvedPath: bundlePath,
                identity: bundleIdentity.pathIdentity, home: request.home
            )
            switch decision {
            case .allowed(let authorization):
                let candidate = ScanCandidate(url: bundlePath, identity: bundleIdentity, allocatedSize: 0, ruleID: nil)
                return AuthorizedUninstallItem(
                    role: .bundle(wasVerified: wasVerified),
                    candidate: candidate,
                    anchor: TrashOnlyAnchor(
                        key: .externalRoot(path: authorization.rootURL.path),
                        url: authorization.rootURL,
                        identity: authorization.rootIdentity
                    ),
                    resolvedPath: authorization.path
                )
            case .denied(let reason):
                lastDenial = reason
            }
        }
        throw UninstallAuthorizationError.applicationsRootUnavailable(reason: lastDenial)
    }

    // MARK: - Bundle-object structure validation (Codex Gate-U finding #5)

    /// A real directory, `.app` extension, `CFBundlePackageType == APPL`, and a validated
    /// `Contents/Info.plist` structure — the "mutation gate" refusal for a trailing symlink or a
    /// hollowed-out fake bundle. `nil` means the structure is valid; returns (never throws) so the
    /// same check can be reused both as a throwing gate in ``authorizeBundle`` and as a plain
    /// yes/no answer in ``revalidateBundleImmediatelyBeforeStaging(_:expectedBundleIdentifier:isRunning:)``.
    private static func validateBundleStructure(bundlePath: URL, identity: FileIdentity) -> UninstallAuthorizationError? {
        guard bundlePath.pathExtension == "app" else {
            return .bundleStructureInvalid(path: bundlePath.path, reason: "missing .app extension")
        }
        guard identity.kind == .directory else {
            return .bundleStructureInvalid(path: bundlePath.path, reason: "not a real directory; a trailing symlink is refused")
        }
        let contentsURL = bundlePath.appendingPathComponent("Contents")
        guard let contentsIdentity = try? FileIdentity.read(at: contentsURL), contentsIdentity.kind == .directory else {
            return .bundleStructureInvalid(path: bundlePath.path, reason: "Contents is missing or not a real directory")
        }
        let infoPlistURL = contentsURL.appendingPathComponent("Info.plist")
        guard let infoPlistIdentity = try? FileIdentity.read(at: infoPlistURL), infoPlistIdentity.kind == .file else {
            return .bundleStructureInvalid(path: bundlePath.path, reason: "Contents/Info.plist is missing or not a real file")
        }
        guard (Bundle(url: bundlePath)?.infoDictionary?["CFBundlePackageType"] as? String) == "APPL" else {
            return .bundleStructureInvalid(path: bundlePath.path, reason: "CFBundlePackageType is not APPL")
        }
        return nil
    }

    // MARK: - Bundle-last transactional safety (Codex Gate-U finding #4)

    /// Everything ``authorizeBundle`` already proved, re-read live one more time, immediately
    /// before the bundle is ever handed to `DeletionCoordinator` for staging. Leftovers execute
    /// first (``orderedItems``'s own doc comment) and can take an arbitrary amount of real
    /// wall-clock time — each one is a real rename plus a real `FileManager.trashItem` call —
    /// during which nothing about "this app is safe to remove" is assumed to still hold.
    ///
    /// Distinct from `DeletionCoordinator.perform`'s own per-item identity re-check: that check
    /// can only ever compare the bundle *directory's* own `stat` fields (mtime/ctime/size/
    /// link-count/flags) against what authorization captured. A deep, in-place edit to a sealed
    /// resource nested inside the bundle — replacing the signed executable without touching the
    /// top-level directory entry at all — would not necessarily change any of those fields, but
    /// would invalidate the signature. `VerifiedBundle.verify` catches exactly that, because it
    /// runs a fresh `SecStaticCodeCheckValidity`, not a cached one.
    static func revalidateBundleImmediatelyBeforeStaging(
        _ item: AuthorizedUninstallItem,
        expectedBundleIdentifier: String,
        isRunning: @Sendable (String) -> Bool
    ) -> UninstallAuthorizationError? {
        guard case .bundle(let wasVerified) = item.role else { return nil }
        let bundlePath = item.resolvedPath

        let identity: FileIdentity
        do {
            identity = try FileIdentity.read(at: bundlePath)
        } catch {
            return .bundleNotFound(path: bundlePath.path)
        }
        if let structureError = validateBundleStructure(bundlePath: bundlePath, identity: identity) {
            return structureError
        }
        guard let liveBundleIdentifier = Bundle(url: bundlePath)?.bundleIdentifier, !liveBundleIdentifier.isEmpty else {
            return .bundleIdentifierUnreadable(path: bundlePath.path)
        }
        guard liveBundleIdentifier == expectedBundleIdentifier else {
            return .bundleIdentifierMismatch(expected: expectedBundleIdentifier, found: liveBundleIdentifier)
        }
        // Only a *regression* is refused: a bundle that was never verifiable to begin with stays
        // exactly as removable as `authorizeBundle` originally allowed (finding #1's "unsigned/
        // invalid apps may still be explicitly trashed"). A bundle that WAS verified and no longer
        // is means something changed a sealed resource after authorization — refused.
        if wasVerified {
            guard VerifiedBundle.verify(bundleURL: bundlePath, liveBundleIdentifier: liveBundleIdentifier) != nil else {
                return .bundleSignatureInvalidAtStaging(path: bundlePath.path)
            }
        }
        guard !isRunning(liveBundleIdentifier) else {
            return .appIsRunning(bundleIdentifier: liveBundleIdentifier)
        }
        return nil
    }

    // MARK: - Leftover re-derivation

    /// "Leftover candidates ONLY with evidence tier exactBundleID or receiptListed (re-derived
    /// server-side via a provided SweepUninstall-style matcher output revalidated by live
    /// identity...)". The re-derivation is total: this never reads a `LeftoverCandidate`'s
    /// `.evidence`/`.confidence` from anything the caller supplied — it builds a fresh
    /// `InstalledApp` from exactly the identity/bundle-id/signing facts ``authorizeBundle``
    /// already verified, scans the real, current inventory for `LeftoverMatcher`'s
    /// ambiguous-ownership context, and calls `LeftoverMatcher.candidates(for:)` itself. A caller
    /// only ever supplies *paths* (`UninstallRequest.selectedLeftoverPaths`), matched by id
    /// against this independently-computed result — the same "recompute the match, do not trust
    /// the stamp" discipline as `AuthorizedCleanPlan.authorize(ruleID:candidate:catalog:)`.
    private static func authorizeLeftovers(
        request: UninstallRequest,
        operationID: UUID,
        now: @Sendable () -> Date,
        receipts: PkgutilReceiptsProviding
    ) -> (admitted: [AuthorizedUninstallItem], unresolved: [UnresolvedLeftover]) {
        guard !request.selectedLeftoverPaths.isEmpty else { return ([], []) }

        let signing = SigningInfoReader.read(at: request.bundlePath)
        let bundle = Bundle(url: request.bundlePath)
        let displayName = (bundle?.infoDictionary?["CFBundleDisplayName"] as? String)
            ?? (bundle?.infoDictionary?["CFBundleName"] as? String)
            ?? request.bundlePath.deletingPathExtension().lastPathComponent

        // `request.expectedBundleIdentifier`, not a re-read: `authorizeBundle` already proved it
        // equals the bundle's live `CFBundleIdentifier` (step 2) before this function is ever
        // called, and `authorize(request:...)` never reaches here otherwise.
        let liveApp = InstalledApp(
            bundleIdentifier: request.expectedBundleIdentifier,
            name: displayName,
            shortVersion: bundle?.infoDictionary?["CFBundleShortVersionString"] as? String,
            buildVersion: bundle?.infoDictionary?["CFBundleVersion"] as? String,
            bundlePath: request.bundlePath.standardizedFileURL,
            teamIdentifier: signing?.teamIdentifier,
            signingIdentifier: signing?.signingIdentifier,
            isAppleSigned: signing?.isAppleSigned ?? false,
            isSystemLocation: UninstallProtection.isUnderSystemLocation(request.bundlePath, prefixes: ["/System/"])
        )

        // Codex Gate-U finding #1: exact-bundle-id (and receipt-listed) admission requires a
        // cryptographic ``VerifiedBundle``, not merely a `CFBundleIdentifier` string read from an
        // unvalidated `Info.plist`. An unsigned or invalid app's bundle may still be explicitly
        // trashed (that decision is `authorizeBundle`'s alone, already made before this function
        // is ever reached) — but every one of its leftovers is capped at manual review below.
        let verifiedBundle = VerifiedBundle.verify(bundleURL: request.bundlePath, liveBundleIdentifier: request.expectedBundleIdentifier)

        // Live, right now — never a caller-supplied inventory snapshot (an incomplete one could
        // only ever hide ambiguity `SharedOwnershipContext` would otherwise have flagged, never
        // manufacture it, which is exactly the wrong direction to trust a caller on).
        let inventoryScan = AppInventory.scanReportingCompleteness(directories: request.applicationsDirectories)

        // Codex Gate-U finding #1: a scan that could not read everywhere it was supposed to look
        // can never prove no sibling consumer exists for whatever leftover evidence it DID find —
        // so an incomplete inventory caps everything at manual review too, exactly like an
        // unverified bundle does.
        let capReason: String?
        if verifiedBundle == nil {
            capReason = "the app's bundle is not a verified signed bundle (unsigned, invalid, or its signing identifier disagrees with its bundle id)"
        } else if !inventoryScan.isComplete {
            capReason = "the installed-applications inventory scan was incomplete; a sibling consumer of this leftover cannot be ruled out"
        } else {
            capReason = nil
        }

        let recomputed = LeftoverMatcher.candidates(
            for: liveApp,
            roots: SearchRoot.allCases,
            homeDirectory: request.home,
            systemLaunchDaemonsDirectory: request.systemLaunchDaemonsDirectory,
            receipts: receipts,
            installedApps: inventoryScan.apps
        )
        // Codex Gate-U finding #6: keyed by the matcher's own exact spelling. `resolvingSymlinksInPath()`
        // previously resolved a caller-supplied path through EVERY symlink it happened to contain,
        // not merely the narrow `/var` vs `/private/var` firmlink alias this was meant to
        // accommodate — a caller path routed through any planted symlink could lexically collapse
        // onto a completely different candidate's canonical path and be treated as a match for it.
        // Matching is now exact-string-first; ``matchedCandidate(for:in:)`` is the only place an
        // alias is still accepted, and only after `lstat`-verifying both spellings name the
        // identical device/inode.
        let byExactPath = Dictionary(recomputed.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var admitted: [AuthorizedUninstallItem] = []
        var unresolved: [UnresolvedLeftover] = []

        for path in request.selectedLeftoverPaths.sorted() {
            guard let match = matchedCandidate(for: path, in: byExactPath), !excludedLeftoverRoots.contains(match.root) else {
                unresolved.append(.init(path: path, error: .leftoverNotIndependentlyMatched(path: path)))
                continue
            }

            // Codex Gate-U finding #1: strong evidence (`exactBundleID`/`receiptListed`, which is
            // what actually derives `.autoSelectable`) is downgraded to `.manualReview` whenever
            // the bundle could not be cryptographically verified or the inventory scan was
            // incomplete — regardless of how strong the matcher's own confidence looks.
            let effectiveConfidence: MatchConfidence = (capReason != nil && match.confidence == .autoSelectable)
                ? .manualReview
                : match.confidence

            switch effectiveConfidence {
            case .orphan:
                // Unreachable in practice: `LeftoverMatcher.candidates(for:)` only ever emits
                // non-empty evidence, and `MatchConfidence.derive` maps non-empty evidence to
                // `.autoSelectable` or `.manualReview`, never `.orphan` (that confidence is only
                // ever produced by the separate `orphanCandidates(...)` entry point, which this
                // code never calls). Handled explicitly anyway rather than assumed away.
                unresolved.append(.init(path: path, error: .leftoverNotIndependentlyMatched(path: path)))
                continue
            case .manualReview:
                guard request.manualOverrideConfirmedPaths.contains(path) else {
                    unresolved.append(.init(path: path, error: .leftoverManualConfirmationRequired(path: path)))
                    continue
                }
            case .autoSelectable:
                break
            }

            let leftoverIdentity: FileIdentity
            do {
                leftoverIdentity = try FileIdentity.read(at: match.url)
            } catch {
                unresolved.append(.init(path: path, error: .leftoverIdentityUnreadable(path: path)))
                continue
            }

            let rootURL = match.root.url(
                homeDirectory: request.home, systemLaunchDaemonsDirectory: request.systemLaunchDaemonsDirectory
            )
            let decision = SweepPolicy.authorize(
                externalRoot: rootURL, resolvedPath: match.url, identity: leftoverIdentity.pathIdentity, home: request.home
            )
            guard case .allowed(let authorization) = decision else {
                let reason = decision.denialReason ?? .malformedPath(match.url.path)
                unresolved.append(.init(path: path, error: .leftoverPolicyDenied(path: path, reason: reason)))
                continue
            }

            // Codex Gate-U finding #6: bound to the matcher's own canonical path (`match.id`),
            // never the caller's raw selection string.
            let overrideToken: ManualOverrideToken? = effectiveConfidence == .manualReview
                ? ManualOverrideToken(
                    callerPath: path, canonicalPath: match.id, identity: leftoverIdentity,
                    mintedAt: now(), operationID: operationID, nonce: UUID()
                  )
                : nil

            let candidate = ScanCandidate(url: match.url, identity: leftoverIdentity, allocatedSize: 0, ruleID: nil)
            admitted.append(AuthorizedUninstallItem(
                role: .leftover(evidence: match.evidence, manualOverride: overrideToken),
                candidate: candidate,
                anchor: TrashOnlyAnchor(
                    key: .externalRoot(path: authorization.rootURL.path),
                    url: authorization.rootURL,
                    identity: authorization.rootIdentity
                ),
                resolvedPath: authorization.path
            ))
        }

        return (admitted, unresolved)
    }

    /// Codex Gate-U finding #6: matches a caller-supplied path against the independently
    /// recomputed candidates, exact string first. Only when no exact match exists does this fall
    /// back to a narrow, *identity*-verified alias check (the `/var` vs `/private/var` firmlink
    /// case this existed for): both spellings are `lstat`'d and only accepted as the same object
    /// when they name the identical device and inode — never merely the identical resolved
    /// string, which is what let an arbitrary planted symlink alias onto a different candidate's
    /// canonical path. Whichever way a match is found, everything downstream (identity,
    /// `SweepPolicy` authorization, the eventual mutation) always proceeds against `match.url` —
    /// the matcher's own canonical object — never the caller's string.
    private static func matchedCandidate(
        for path: String, in candidatesByExactPath: [String: LeftoverCandidate]
    ) -> LeftoverCandidate? {
        if let exact = candidatesByExactPath[path] { return exact }
        guard let callerIdentity = try? FileIdentity.read(at: URL(fileURLWithPath: path)) else { return nil }
        return candidatesByExactPath.values.first { candidate in
            guard let candidateIdentity = try? FileIdentity.read(at: candidate.url) else { return false }
            return candidateIdentity.deviceID == callerIdentity.deviceID && candidateIdentity.inode == callerIdentity.inode
        }
    }
}

/// Pure, independently-testable protection predicates — extracted so "fake com.apple. bundle" /
/// "fake /System-resolved symlink" can each be exercised in isolation (a real `/System` app is
/// always `com.apple.`-prefixed too, which would otherwise couple the two checks in any
/// filesystem-backed test). Mirrors `Sources/SweepApp/Uninstall/UninstallLogic.isProtected`'s own
/// reasoning exactly, server-side and unbypassable rather than advisory.
enum UninstallProtection {
    static func isAppleBundleIdentifier(_ bundleIdentifier: String) -> Bool {
        bundleIdentifier.hasPrefix("com.apple.")
    }

    /// Resolves symlinks before comparing, so a dot-less symlinked bundle (macOS 26
    /// cryptex-relocated system apps; see `AppInventory`'s own comments on this) cannot hide a
    /// `/System/...` destination behind an `/Applications/...` name.
    static func isUnderSystemLocation(_ url: URL, prefixes: [String]) -> Bool {
        let resolved = url.resolvingSymlinksInPath().path
        return prefixes.contains { resolved.hasPrefix($0) }
    }
}

extension OwnershipEvidence {
    /// Compact, greppable provenance tag, always surfaced in the ephemeral, caller-inspectable
    /// `CleanReport`/`CleanItemOutcome` (`.detail`) exactly how the code-sign-clone path's own
    /// `detectorSource` is surfaced. For an auto-admitted item this is the only place the tag
    /// appears — it is never persisted into `JournalItem`/the real WAL, per
    /// `AuthorizedUninstallItem.deletionItem`'s doc comment. Codex Gate-U finding #2 is the one
    /// exception: for a manual-review admission, this same tag is ALSO copied into
    /// `ManualConsentProvenance.evidenceTag` and does reach the durable `planned` WAL record —
    /// because that is the one case where explaining *why* something was authorized has to
    /// survive a crash, not just outlive this report.
    var journalTag: String {
        var tags: [String] = []
        if contains(.exactBundleID) { tags.append("exactBundleID") }
        if contains(.receiptListed) { tags.append("receiptListed") }
        if contains(.prefixMatch) { tags.append("prefixMatch") }
        if contains(.nameMatch) { tags.append("nameMatch") }
        if contains(.sharedGroupContainer) { tags.append("sharedGroupContainer") }
        if contains(.launchDaemon) { tags.append("launchDaemon") }
        if contains(.receiptPrefixMatch) { tags.append("receiptPrefixMatch") }
        if contains(.ambiguousOwner) { tags.append("ambiguousOwner") }
        return tags.isEmpty ? "none" : tags.joined(separator: "+")
    }
}
