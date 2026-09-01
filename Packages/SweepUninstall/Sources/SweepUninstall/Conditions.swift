import Foundation

/// A per-app disambiguation rule: pure data, consulted generically by `LeftoverMatcher`. No
/// per-app `if bundleID == "..."` branches exist anywhere in the matching code — every special
/// case an app needs lives here instead, the same shape as Pearcleaner's
/// `Logic/Conditions.swift` (knowledge ported, not code copied; Apache-2.0 + Commons Clause).
public struct AppCondition: Sendable {
    /// Bundle id (or dotted prefix of one) this condition applies to, e.g.
    /// `"com.apple.dt.xcode"` matches that id and any longer id starting with those
    /// components (`com.apple.dt.xcode.something`).
    public let bundleIDPrefix: String
    /// Normalized (alphanumeric) fragments that, if contained in an item's normalized name,
    /// count as a name match for this app even though they are not literally the app's name —
    /// a controlled, opt-in "contains" allowance instead of the generic matcher's strict
    /// equality.
    public let includeNameFragments: [String]
    /// Normalized fragments that veto a match outright for this app, even one the generic
    /// matcher would otherwise report — the mechanism that keeps a sibling/variant app's files
    /// (Insiders, Nightly, a competing "cleaner" utility) from being attributed here.
    public let excludeNameFragments: [String]
    /// Known extra leftover paths (may use `~`) the generic name/bundle-id matching can't
    /// discover on its own, ported from Pearcleaner's `includeForce`. Only added when they
    /// exist on disk, and only when they fall under one of `SearchRoot`'s known roots.
    public let forceIncludePaths: [String]

    public init(
        bundleIDPrefix: String,
        includeNameFragments: [String] = [],
        excludeNameFragments: [String] = [],
        forceIncludePaths: [String] = []
    ) {
        self.bundleIDPrefix = bundleIDPrefix.lowercased()
        self.includeNameFragments = includeNameFragments.map(NameNormalization.alphanumeric)
        self.excludeNameFragments = excludeNameFragments.map(NameNormalization.alphanumeric)
        self.forceIncludePaths = forceIncludePaths
    }
}

/// The condition catalog. Ported knowledge from Pearcleaner's `Logic/Conditions.swift`,
/// narrowed to the cases PLAN.md §3 module 5 names explicitly (Xcode family disambiguation,
/// VS Code vs Insiders) plus a couple of the same-shaped browser pairs as further worked
/// examples of the pattern.
public enum ConditionsTable {
    public static let all: [AppCondition] = [
        // Xcode itself must never absorb the leftovers of the third-party tools that manage
        // or clean it — "xcodes" (the version manager), "Cleaner for Xcode", and the various
        // vendor spellings of both.
        AppCondition(
            bundleIDPrefix: "com.apple.dt.xcode",
            excludeNameFragments: [
                "xcodesapp", "xcodes", "availablexcodes",
                "cleanerforxcode", "xcodecleaner",
            ]
        ),
        AppCondition(bundleIDPrefix: "com.robotsandpencils.xcodesapp"),
        AppCondition(bundleIDPrefix: "com.xcodesorg.xcodesapp"),
        AppCondition(bundleIDPrefix: "io.hyperapp.xcodecleaner"),

        // VS Code vs VS Code Insiders: distinct bundle ids, but each app's own Application
        // Support folder ("Code" / "Code - Insiders") isn't discoverable by the generic
        // name matcher (neither is literally the app's display name), and the two folder
        // names collide under naive substring matching ("Code - Insiders" contains "Code").
        AppCondition(
            bundleIDPrefix: "com.microsoft.vscode",
            excludeNameFragments: ["insiders", "vscodeinsiders"],
            forceIncludePaths: ["~/Library/Application Support/Code"]
        ),
        AppCondition(
            bundleIDPrefix: "com.microsoft.vscodeinsiders",
            includeNameFragments: ["insiders"],
            forceIncludePaths: ["~/Library/Application Support/Code - Insiders"]
        ),

        // Firefox vs Thunderbird share the Mozilla name fragment.
        AppCondition(bundleIDPrefix: "org.mozilla.firefox", excludeNameFragments: ["thunderbird"]),
        AppCondition(bundleIDPrefix: "org.mozilla.thunderbird", excludeNameFragments: ["firefox"]),

        // Chrome vs Brave (Chromium-based, share cache-folder naming fragments).
        AppCondition(bundleIDPrefix: "com.google.chrome", excludeNameFragments: ["brave", "chromium"]),
        AppCondition(bundleIDPrefix: "com.brave.browser", includeNameFragments: ["brave"]),
    ]

    /// Conditions applicable to `bundleID`: those whose prefix is a component-wise prefix of
    /// (or exactly equals) the app's bundle id.
    public static func conditions(for bundleID: String?) -> [AppCondition] {
        guard let bundleID, !bundleID.isEmpty else { return [] }
        let idComponents = BundleIDMatch.components(bundleID)
        return all.filter { condition in
            let prefixComponents = BundleIDMatch.components(condition.bundleIDPrefix)
            guard !prefixComponents.isEmpty, idComponents.count >= prefixComponents.count else { return false }
            return Array(idComponents.prefix(prefixComponents.count)) == prefixComponents
        }
    }
}
