import Foundation

/// A filesystem item (or pkgutil receipt) believed to belong to `app`, together with every
/// piece of evidence found for it. Read-only fact record — nothing in this package ever acts
/// on a candidate; `SweepCore`'s `DeletionCoordinator` is the sole consumer authorized to
/// delete anything, later, and only after its own identity revalidation.
public struct LeftoverCandidate: Sendable, Hashable, Identifiable {
    public var id: String { url.path }

    /// The item's location. For `.pkgReceipt` evidence this is a synthetic path under
    /// `/private/var/db/receipts` naming the package id — there is no single file to point at
    /// for a receipt, only the identifier itself.
    public let url: URL
    public let root: SearchRoot
    /// The installed app's bundle identifier this candidate is attributed to (falls back to a
    /// normalized form of the app's display name for the rare bundle without one).
    public let attributedBundleID: String
    public let evidence: OwnershipEvidence
    public let confidence: MatchConfidence

    public init(url: URL, root: SearchRoot, attributedBundleID: String, evidence: OwnershipEvidence) {
        self.url = url
        self.root = root
        self.attributedBundleID = attributedBundleID
        self.evidence = evidence
        self.confidence = MatchConfidence.derive(from: evidence)
    }
}

/// A leftover whose name is shaped like a bundle identifier but matches no installed app —
/// orphan mode (PLAN.md §3 module 5, item 4). Always `MatchConfidence.orphan`: per PLAN.md,
/// orphan detection is tier `caution`, never `safe` — helper tools and licensed-but-uninstalled
/// apps are known false positives, which is exactly what `isLikelyHelperTool` flags rather than
/// silently filters, so a consumer can see and judge them instead of losing them.
public struct OrphanCandidate: Sendable, Hashable, Identifiable {
    public var id: String { url.path }

    public let url: URL
    public let root: SearchRoot
    /// The bundle-id-shaped name parsed from the item itself (not attributed to any app).
    public let apparentBundleID: String
    /// True when the name matches a common helper/agent/daemon/updater suffix pattern — a
    /// likely false positive (background tool with no discrete `.app`, or an app that was
    /// removed by trashing the bundle without uninstalling its helper first).
    public let isLikelyHelperTool: Bool
    public let confidence: MatchConfidence = .orphan
}

/// Given an installed app (or, for orphan mode, the set of installed bundle ids), finds
/// related files across the search roots. Strictly read-only: every method here only reads —
/// `FileManager.contentsOfDirectory`, `Info.plist`/metadata-plist reads, and read-only
/// `pkgutil` queries. No `FileManager` write/remove/trash call exists anywhere in this
/// package; deletion is `SweepCore`'s `DeletionCoordinator`'s job, later, on the caller's own
/// timeline.
public enum LeftoverMatcher {
    /// Finds every leftover candidate for `app` across `roots`.
    ///
    /// Match order per item, most to least specific: exact bundle id, reversed-domain prefix
    /// (component-aware — see `BundleIDMatch`), normalized app name, then the Conditions
    /// table's curated include-fragments and forced paths as a last resort for cases the
    /// generic rules can't discover on their own (see `ConditionsTable`).
    public static func candidates(
        for app: InstalledApp,
        roots: [SearchRoot] = SearchRoot.allCases,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemLaunchDaemonsDirectory: URL = URL(fileURLWithPath: "/Library/LaunchDaemons"),
        receipts: PkgutilReceiptsProviding = PkgutilReceiptsProvider(),
        fileManager: FileManager = .default,
        installedApps: [InstalledApp] = []
    ) -> [LeftoverCandidate] {
        let attributedID = app.bundleIdentifier ?? NameNormalization.alphanumeric(app.name)
        let conditions = ConditionsTable.conditions(for: app.bundleIdentifier)
        let nameForms = nameForms(for: app)
        // See finding #11 in the adversarial review: an exact bundle-id-shaped item was
        // previously promoted to auto-selectable without ever checking whether some OTHER
        // installed app could also depend on it. `installedApps` defaults to empty for backward
        // compatibility with callers that don't (yet) have a full inventory to pass; passing the
        // real inventory (typically `AppInventory.scan()`, `app` included) is what activates
        // this check.
        let sharedOwnership = SharedOwnershipContext(target: app, installedApps: installedApps)

        var results: [LeftoverCandidate] = []

        for root in roots where root != .pkgReceipt {
            let entries = RootWalker.entries(
                in: root,
                homeDirectory: homeDirectory,
                systemLaunchDaemonsDirectory: systemLaunchDaemonsDirectory,
                fileManager: fileManager
            )
            for entry in entries {
                var evidence = evaluate(entry: entry, root: root, app: app, nameForms: nameForms, conditions: conditions, fileManager: fileManager)
                guard !evidence.isEmpty else { continue }
                let comparableName = groupContainerBaseName(entry.baseName, root: root)
                if sharedOwnership.isAmbiguous(comparableName: comparableName) {
                    evidence.insert(.ambiguousOwner)
                }
                results.append(LeftoverCandidate(url: entry.url, root: root, attributedBundleID: attributedID, evidence: evidence))
            }
        }

        if roots.contains(.pkgReceipt) {
            results.append(contentsOf: receiptCandidates(for: app, attributedID: attributedID, receipts: receipts, sharedOwnership: sharedOwnership))
        }

        for path in conditions.flatMap(\.forceIncludePaths) {
            let expanded = resolveForceIncludePath(path, homeDirectory: homeDirectory)
            guard fileManager.fileExists(atPath: expanded.path) else { continue }
            guard let owningRoot = SearchRoot.root(
                containing: expanded,
                homeDirectory: homeDirectory,
                systemLaunchDaemonsDirectory: systemLaunchDaemonsDirectory
            ), roots.contains(owningRoot) else { continue }
            guard !results.contains(where: { $0.url.standardizedFileURL == expanded.standardizedFileURL }) else { continue }
            results.append(LeftoverCandidate(url: expanded, root: owningRoot, attributedBundleID: attributedID, evidence: [.nameMatch]))
        }

        return results
    }

    /// Orphan mode: leftover items under `roots` whose bundle-id-shaped name matches none of
    /// `installedBundleIDs` (and, when `receipts` is supplied, no live pkgutil receipt either —
    /// a receipted identifier with no discovered `.app` is more likely a CLI tool or an app in
    /// a location `AppInventory` doesn't scan than a true orphan).
    public static func orphanCandidates(
        installedBundleIDs: Set<String>,
        roots: [SearchRoot] = SearchRoot.filesystemRoots,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        systemLaunchDaemonsDirectory: URL = URL(fileURLWithPath: "/Library/LaunchDaemons"),
        receipts: PkgutilReceiptsProviding? = PkgutilReceiptsProvider(),
        fileManager: FileManager = .default
    ) -> [OrphanCandidate] {
        let installedLower = Set(installedBundleIDs.map { $0.lowercased() })
        let receiptedLower = Set((receipts?.packageIdentifiers() ?? []).map { $0.lowercased() })

        func isOwned(_ candidateID: String) -> Bool {
            if installedLower.contains(candidateID) || receiptedLower.contains(candidateID) { return true }
            return installedLower.contains { installed in
                BundleIDMatch.isComponentPrefix(candidateID, bundleID: installed)
                    || BundleIDMatch.isComponentPrefix(installed, bundleID: candidateID)
            }
        }

        var results: [OrphanCandidate] = []
        for root in roots where root != .pkgReceipt {
            let entries = RootWalker.entries(
                in: root,
                homeDirectory: homeDirectory,
                systemLaunchDaemonsDirectory: systemLaunchDaemonsDirectory,
                fileManager: fileManager
            )
            for entry in entries {
                let candidateName = groupContainerBaseName(entry.baseName, root: root)
                guard looksLikeBundleID(candidateName) else { continue }
                let normalized = candidateName.lowercased()
                guard !isOwned(normalized) else { continue }
                results.append(OrphanCandidate(
                    url: entry.url,
                    root: root,
                    apparentBundleID: candidateName,
                    isLikelyHelperTool: isHelperToolFalsePositive(candidateName)
                ))
            }
        }
        return results
    }

    // MARK: - Per-entry evaluation

    private enum BundleMatchKind { case none, exact, prefix }

    private static func bundleMatchKind(_ name: String, bundleID: String?) -> BundleMatchKind {
        guard let bundleID, !bundleID.isEmpty else { return .none }
        if BundleIDMatch.isExact(name, bundleID: bundleID) { return .exact }
        if BundleIDMatch.isComponentPrefix(name, bundleID: bundleID) { return .prefix }
        return .none
    }

    private static func groupContainerBaseName(_ baseName: String, root: SearchRoot) -> String {
        guard root == .groupContainers, baseName.lowercased().hasPrefix("group.") else { return baseName }
        return String(baseName.dropFirst("group.".count))
    }

    private static func evaluate(
        entry: RootEntry,
        root: SearchRoot,
        app: InstalledApp,
        nameForms: Set<String>,
        conditions: [AppCondition],
        fileManager: FileManager
    ) -> OwnershipEvidence {
        let normalizedName = NameNormalization.alphanumeric(entry.baseName)

        // Defense in depth: an explicit exclude fragment vetoes any match for this app,
        // regardless of which rule below would otherwise have fired.
        if conditions.contains(where: { condition in condition.excludeNameFragments.contains(where: normalizedName.contains) }) {
            return []
        }

        var evidence: OwnershipEvidence = []
        let comparableName = groupContainerBaseName(entry.baseName, root: root)
        var kind = bundleMatchKind(comparableName, bundleID: app.bundleIdentifier)

        // Sandboxed containers are occasionally named by a container UUID rather than the
        // bundle id directly; fall back to the cheap, read-only sandbox metadata plist.
        if kind == .none, root == .containers, entry.isDirectory, let bundleID = app.bundleIdentifier {
            let metadataURL = entry.url.appendingPathComponent(".com.apple.containermanagerd.metadata.plist")
            if let metadata = NSDictionary(contentsOf: metadataURL),
               (metadata["MCMMetadataIdentifier"] as? String) == bundleID {
                kind = .exact
            }
        }

        // Group container ids are developer-chosen free-form strings (often, but not always,
        // the bundle id verbatim after stripping "group."); allow a controlled substring
        // match here specifically because `sharedGroupContainer` is capped at manualReview
        // regardless of match strength, so loosening the check can't promote anything.
        if kind == .none, root == .groupContainers, let bundleID = app.bundleIdentifier {
            let normalizedBundleID = NameNormalization.alphanumeric(bundleID)
            if !normalizedBundleID.isEmpty, NameNormalization.alphanumeric(comparableName).contains(normalizedBundleID) {
                kind = .prefix
            }
        }

        switch (root, kind) {
        case (_, .none): break
        case (.groupContainers, _): evidence.insert(.sharedGroupContainer)
        case (.libraryLaunchDaemons, _): evidence.insert(.launchDaemon)
        case (_, .exact): evidence.insert(.exactBundleID)
        case (_, .prefix): evidence.insert(.prefixMatch)
        }

        if nameForms.contains(normalizedName) {
            evidence.insert(.nameMatch)
        }
        if conditions.contains(where: { condition in condition.includeNameFragments.contains(where: normalizedName.contains) }) {
            evidence.insert(.nameMatch)
        }

        return evidence
    }

    /// Resolves a `Conditions`-table path (which may start with `~`) against the *injected*
    /// `homeDirectory`, never the real process home — keeping `candidates(for:)` correct under
    /// a non-default home (tests, or a future privileged-helper context acting on behalf of a
    /// specific user) instead of silently falling back to `NSHomeDirectory()`.
    private static func resolveForceIncludePath(_ path: String, homeDirectory: URL) -> URL {
        if path == "~" { return homeDirectory }
        if path.hasPrefix("~/") { return homeDirectory.appendingPathComponent(String(path.dropFirst(2))) }
        return URL(fileURLWithPath: path)
    }

    private static func nameForms(for app: InstalledApp) -> Set<String> {
        var forms: Set<String> = []
        let displayName = NameNormalization.alphanumeric(app.name)
        if !displayName.isEmpty { forms.insert(displayName) }
        let stem = NameNormalization.alphanumeric(NameNormalization.stem(of: app.bundlePath))
        if !stem.isEmpty { forms.insert(stem) }
        return forms
    }

    // MARK: - pkgutil receipts

    private static func receiptCandidates(
        for app: InstalledApp,
        attributedID: String,
        receipts: PkgutilReceiptsProviding,
        sharedOwnership: SharedOwnershipContext
    ) -> [LeftoverCandidate] {
        guard let bundleID = app.bundleIdentifier else { return [] }
        let bundleFileSuffix = "Applications/\(app.bundlePath.lastPathComponent)"

        var results: [LeftoverCandidate] = []
        for packageID in receipts.packageIdentifiers() {
            let isExactID = BundleIDMatch.isExact(packageID, bundleID: bundleID)
            let isPrefixEitherDirection = BundleIDMatch.isComponentPrefix(packageID, bundleID: bundleID)
                || BundleIDMatch.isComponentPrefix(bundleID, bundleID: packageID)

            // Only an exact receipt identifier, or `pkgutil --files` proof that the receipt
            // actually installed this exact app bundle, counts as strong (`.receiptListed`,
            // auto-selectable-eligible) evidence. A broad suite receipt like `com.vendor` for a
            // candidate `com.vendor.product` (or the reverse: a narrow receipt for a broader app
            // id) is a real relationship — it just isn't proof this SPECIFIC package receipt
            // installed THIS SPECIFIC app — so it is downgraded to `.receiptPrefixMatch`, which
            // `MatchConfidence.derive` never promotes past `manualReview`. See finding #12.
            let filesMatch = isExactID ? false : receipts.files(forPackageID: packageID).contains { $0.hasSuffix(bundleFileSuffix) }

            var evidence: OwnershipEvidence
            if isExactID || filesMatch {
                evidence = [.receiptListed]
            } else if isPrefixEitherDirection {
                evidence = [.receiptPrefixMatch]
            } else {
                continue
            }
            if sharedOwnership.isAmbiguous(comparableName: packageID) {
                evidence.insert(.ambiguousOwner)
            }

            let receiptURL = URL(fileURLWithPath: "/private/var/db/receipts/\(packageID).plist")
            results.append(LeftoverCandidate(url: receiptURL, root: .pkgReceipt, attributedBundleID: attributedID, evidence: evidence))
        }
        return results
    }

    // MARK: - Ambiguous ownership (finding #11)

    /// Ambiguous-ownership detection: an item that textually matches `target` can still be
    /// unsafe to auto-select if another installed app plausibly also depends on it. Built once
    /// per `candidates(for:)` call from the full installed-app inventory the caller supplies.
    ///
    /// Before this, `candidates(for:)` only ever looked at `target`: a broad vendor "Common
    /// Files"-style folder that happened to equal one product's bundle id verbatim was promoted
    /// to auto-selectable even when sibling products from the same vendor/team were also
    /// installed (e.g. `com.adobe.CommonFiles` while `com.adobe.photoshop` and
    /// `com.adobe.bridge` are both present).
    private struct SharedOwnershipContext {
        /// Every OTHER installed app's bundle identifier (lowercased), excluding `target` itself
        /// (compared by bundle path, since two distinct apps could coincidentally share a
        /// nil/empty bundle id).
        private let otherBundleIDs: [String]
        /// True when at least one other installed app shares `target`'s second-level
        /// reverse-DNS vendor prefix (`com.vendor` out of `com.vendor.product`).
        private let vendorPrefixIsShared: Bool
        /// True when at least one other installed app shares `target`'s non-empty code-signing
        /// team identifier.
        private let teamIsShared: Bool

        init(target: InstalledApp, installedApps: [InstalledApp]) {
            let others = installedApps.filter { $0.bundlePath != target.bundlePath }
            otherBundleIDs = others.compactMap { $0.bundleIdentifier?.lowercased() }

            if let targetVendorPrefix = Self.vendorPrefix(of: target.bundleIdentifier) {
                vendorPrefixIsShared = others.contains { Self.vendorPrefix(of: $0.bundleIdentifier) == targetVendorPrefix }
            } else {
                vendorPrefixIsShared = false
            }

            if let targetTeam = target.teamIdentifier, !targetTeam.isEmpty {
                teamIsShared = others.contains { $0.teamIdentifier == targetTeam }
            } else {
                teamIsShared = false
            }
        }

        /// True when `comparableName` should never be treated as exclusively `target`'s: either
        /// the vendor namespace (or signing team) it belongs to has other live consumers, or the
        /// name itself also matches a different installed app's bundle id or prefix.
        func isAmbiguous(comparableName: String) -> Bool {
            if vendorPrefixIsShared || teamIsShared { return true }
            return otherBundleIDs.contains { otherBundleID in
                BundleIDMatch.isExact(comparableName, bundleID: otherBundleID)
                    || BundleIDMatch.isComponentPrefix(comparableName, bundleID: otherBundleID)
            }
        }

        /// First two dot-separated components of a reverse-DNS bundle id, e.g. `"com.adobe"`
        /// from `"com.adobe.photoshop"`. `nil` when the id has fewer than two components — too
        /// generic to mean anything as a "vendor".
        private static func vendorPrefix(of bundleID: String?) -> String? {
            guard let bundleID else { return nil }
            let components = BundleIDMatch.components(bundleID)
            guard components.count >= 2 else { return nil }
            return components.prefix(2).joined(separator: ".")
        }
    }

    // MARK: - Orphan-mode helpers

    /// A conservative "does this look like a reverse-DNS bundle id" check: at least three
    /// dot-separated components, each non-empty and made only of identifier-safe characters.
    /// Requiring three components (not two) trades a few missed short ids for materially fewer
    /// false "orphan" flags on generic folder names.
    private static func looksLikeBundleID(_ name: String) -> Bool {
        let components = BundleIDMatch.components(name)
        guard components.count >= 3 else { return false }
        return components.allSatisfy { component in
            !component.isEmpty && component.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
    }

    private static let helperToolFragments = [
        "helper", "agent", "daemon", "service", "xpc",
        "updater", "installer", "uninstaller", "login", "launcher",
    ]

    private static func isHelperToolFalsePositive(_ name: String) -> Bool {
        let normalized = NameNormalization.alphanumeric(name)
        return helperToolFragments.contains { normalized.hasSuffix($0) || normalized.contains($0) }
    }
}
