import Foundation
@testable import SweepUninstall

/// Builds a temp-directory tree mimicking a `~/Library` layout, with both planted "real"
/// leftovers and adversarial trap leftovers, so `LeftoverMatcher` can be exercised without
/// touching the real filesystem's actual `~/Library`.
///
/// Building/tearing down these fixtures is test-only scaffolding — the only place in this
/// package's test target that ever writes or removes files. `Sources/SweepUninstall` itself
/// contains no such call.
enum LeftoverFixture {
    struct Tree {
        let root: URL
        let home: URL
        let systemLaunchDaemonsDirectory: URL
        let fileManager: FileManager

        func candidates(
            for app: InstalledApp,
            roots: [SearchRoot] = SearchRoot.filesystemRoots
        ) -> [LeftoverCandidate] {
            LeftoverMatcher.candidates(
                for: app,
                roots: roots,
                homeDirectory: home,
                systemLaunchDaemonsDirectory: systemLaunchDaemonsDirectory,
                receipts: EmptyPkgutilReceiptsProvider(),
                fileManager: fileManager
            )
        }

        func orphanCandidates(installedBundleIDs: Set<String>) -> [OrphanCandidate] {
            LeftoverMatcher.orphanCandidates(
                installedBundleIDs: installedBundleIDs,
                roots: SearchRoot.filesystemRoots,
                homeDirectory: home,
                systemLaunchDaemonsDirectory: systemLaunchDaemonsDirectory,
                receipts: EmptyPkgutilReceiptsProvider(),
                fileManager: fileManager
            )
        }
    }

    static let fooApp = InstalledApp(
        bundleIdentifier: "com.example.foo",
        name: "Foo",
        shortVersion: "1.0",
        buildVersion: "1",
        bundlePath: URL(fileURLWithPath: "/Applications/Foo.app"),
        teamIdentifier: nil,
        signingIdentifier: nil,
        isAppleSigned: false,
        isSystemLocation: false
    )

    static let vsCodeApp = InstalledApp(
        bundleIdentifier: "com.microsoft.VSCode",
        name: "Visual Studio Code",
        shortVersion: "1.0",
        buildVersion: "1",
        bundlePath: URL(fileURLWithPath: "/Applications/Visual Studio Code.app"),
        teamIdentifier: nil,
        signingIdentifier: nil,
        isAppleSigned: false,
        isSystemLocation: false
    )

    static let vsCodeInsidersApp = InstalledApp(
        bundleIdentifier: "com.microsoft.VSCodeInsiders",
        name: "Visual Studio Code - Insiders",
        shortVersion: "1.0",
        buildVersion: "1",
        bundlePath: URL(fileURLWithPath: "/Applications/Visual Studio Code - Insiders.app"),
        teamIdentifier: nil,
        signingIdentifier: nil,
        isAppleSigned: false,
        isSystemLocation: false
    )

    /// Builds the fixture tree on disk under a fresh temp directory. Caller tears it down with
    /// `tearDown(_:)`.
    static func build(fileManager: FileManager = .default) throws -> Tree {
        let root = fileManager.temporaryDirectory.appendingPathComponent("SweepUninstallFixture-\(UUID().uuidString)")
        let home = root.appendingPathComponent("home")
        let library = home.appendingPathComponent("Library")
        let systemLaunchDaemons = root.appendingPathComponent("LaunchDaemons")

        try fileManager.createDirectory(at: systemLaunchDaemons, withIntermediateDirectories: true)

        func makeDir(_ relativePath: String, under base: URL = library) throws -> URL {
            let url = base.appendingPathComponent(relativePath)
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }

        func makeFile(_ name: String, in directory: URL) throws {
            let url = directory.appendingPathComponent(name)
            try Data("fixture".utf8).write(to: url)
        }

        // Application Support: exact match, name-collision trap, VS Code / Insiders forced
        // paths, and an orphan vendor subfolder (Application Support gets one extra level of
        // depth, matching real vendor-folder nesting).
        let appSupport = try makeDir("Application Support")
        _ = try makeDir("com.example.foo", under: appSupport)
        _ = try makeDir("com.example.foobar", under: appSupport)
        _ = try makeDir("Code", under: appSupport)
        _ = try makeDir("Code - Insiders", under: appSupport)
        let orphanVendor = try makeDir("OrphanVendor", under: appSupport)
        _ = try makeDir("com.orphan.tool", under: orphanVendor)
        _ = try makeDir("com.orphan.updater", under: orphanVendor)

        // Caches: exact match only.
        let caches = try makeDir("Caches")
        _ = try makeDir("com.example.foo", under: caches)

        // Preferences: exact match + trap, as plist files (extension must be stripped).
        let preferences = try makeDir("Preferences")
        try makeFile("com.example.foo.plist", in: preferences)
        try makeFile("com.example.foobar.plist", in: preferences)

        // Containers: exact match.
        let containers = try makeDir("Containers")
        _ = try makeDir("com.example.foo", under: containers)

        // Group Containers: "group.<bundle id>" naming.
        let groupContainers = try makeDir("Group Containers")
        _ = try makeDir("group.com.example.foo", under: groupContainers)

        // Saved Application State.
        let savedState = try makeDir("Saved Application State")
        _ = try makeDir("com.example.foo.savedState", under: savedState)

        // LaunchAgents: helper-suffix prefix match.
        let launchAgents = try makeDir("LaunchAgents")
        try makeFile("com.example.foo.helper.plist", in: launchAgents)

        // WebKit / HTTPStorages: exact match.
        let webKit = try makeDir("WebKit")
        _ = try makeDir("com.example.foo", under: webKit)
        let httpStorages = try makeDir("HTTPStorages")
        _ = try makeDir("com.example.foo", under: httpStorages)

        // /Library/LaunchDaemons stand-in.
        try makeFile("com.example.foo.daemon.plist", in: systemLaunchDaemons)

        return Tree(root: root, home: home, systemLaunchDaemonsDirectory: systemLaunchDaemons, fileManager: fileManager)
    }

    static func tearDown(_ tree: Tree) {
        try? tree.fileManager.removeItem(at: tree.root)
    }
}
