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
    let path: String
    let identity: FileIdentity
    let mintedAt: Date
    let operationID: UUID
}

/// One item — the bundle, or one admitted leftover — inside an ``AuthorizedUninstallPlan``.
/// Internal-only, exactly like `AuthorizedCleanPlan`: constructible only from
/// ``AuthorizedUninstallPlan/authorize(request:operationID:isRunning:now:receipts:protectedLocationPrefixes:)``,
/// never directly, so a caller cannot stamp its own tier/evidence/override and have
/// `UninstallService` mistake it for something this authorization actually proved.
struct AuthorizedUninstallItem: Sendable, Equatable, Identifiable {
    enum Role: Sendable, Equatable {
        case bundle
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
    /// was rule-driven" — nothing here ever was); Gate U's own provenance (role, evidence, manual
    /// override) is carried at this layer and at `CleanItemOutcome` only, exactly how the
    /// code-sign-clone path already keeps `detectorSource` off `DeletionItem`/`JournalItem`
    /// entirely and only ever surfaces it through the bridged report.
    var deletionItem: DeletionItem {
        DeletionItem(
            url: resolvedPath,
            identity: candidate.identity,
            parentIdentity: candidate.parentIdentity,
            action: .trash,
            tier: reportedTier,
            allocatedSize: candidate.allocatedSize,
            ruleID: nil
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
    /// as implicit cleanup" outright) and `.libraryLaunchDaemons` (root-owned; needs the
    /// privileged helper's `launchctl bootout` integration PLAN §3 module 5 already calls out as
    /// a prerequisite — "requires privileged launchctl bootout handling, never a plain delete" is
    /// `OwnershipEvidence.launchDaemon`'s own doc comment). Both roots still count toward evidence
    /// computation (a receipt can corroborate a *different*, admissible leftover's evidence), just
    /// never toward what actually gets admitted here.
    static let excludedLeftoverRoots: Set<SearchRoot> = [.pkgReceipt, .libraryLaunchDaemons]

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

        // 4. NOT running.
        guard !isRunning(liveBundleIdentifier) else {
            throw UninstallAuthorizationError.appIsRunning(bundleIdentifier: liveBundleIdentifier)
        }

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
                    role: .bundle,
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

        // Live, right now — never a caller-supplied inventory snapshot (an incomplete one could
        // only ever hide ambiguity `SharedOwnershipContext` would otherwise have flagged, never
        // manufacture it, which is exactly the wrong direction to trust a caller on).
        let liveInventory = AppInventory.scan(directories: request.applicationsDirectories)

        let recomputed = LeftoverMatcher.candidates(
            for: liveApp,
            roots: SearchRoot.allCases,
            homeDirectory: request.home,
            systemLaunchDaemonsDirectory: request.systemLaunchDaemonsDirectory,
            receipts: receipts,
            installedApps: liveInventory
        )
        // Keyed by a symlink-resolved spelling, not the raw string: `FileManager`'s own directory
        // enumeration (inside `RootWalker`, underneath `LeftoverMatcher`) surfaces entries through
        // the real, firmlink-resolved path (`/private/var/...`), which need not be the exact
        // spelling `selectedLeftoverPaths` happens to carry (`/var/...`, a caller's own
        // un-resolved copy of the same `LeftoverCandidate.id`, or any other equivalent spelling of
        // the same object). Normalizing both sides before comparing only ever widens *matching*,
        // never *trust*: whether a selection is admitted still depends entirely on the evidence
        // this recomputation independently found for whatever real object the path resolves to.
        let byPath = Dictionary(
            recomputed.map { (Self.normalizedPathKey($0.id), $0) }, uniquingKeysWith: { first, _ in first }
        )

        var admitted: [AuthorizedUninstallItem] = []
        var unresolved: [UnresolvedLeftover] = []

        for path in request.selectedLeftoverPaths.sorted() {
            guard let match = byPath[Self.normalizedPathKey(path)], !excludedLeftoverRoots.contains(match.root) else {
                unresolved.append(.init(path: path, error: .leftoverNotIndependentlyMatched(path: path)))
                continue
            }

            switch match.confidence {
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

            let overrideToken: ManualOverrideToken? = match.confidence == .manualReview
                ? ManualOverrideToken(path: path, identity: leftoverIdentity, mintedAt: now(), operationID: operationID)
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

    /// Symlink/firmlink-resolved spelling of a path string, used only to compare two spellings of
    /// what may be the same object (`/var/...` vs `/private/var/...`) — never as an identity
    /// proof. A nonexistent path resolves to itself lexically (nothing to follow), so a forged
    /// selection still safely misses every real `LeftoverCandidate.id` in `byPath`.
    private static func normalizedPathKey(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().path
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
    /// Compact, greppable provenance tag for the bridged report (`CleanItemOutcome.detail`) —
    /// never persisted into `JournalItem`/the real WAL (see `AuthorizedUninstallItem.deletionItem`'s
    /// doc comment for why), only into the ephemeral, caller-inspectable
    /// `CleanReport`/`CleanItemOutcome`, exactly how the code-sign-clone path's own
    /// `detectorSource` is surfaced.
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
