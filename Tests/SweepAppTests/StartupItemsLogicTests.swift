import ServiceManagement
import XCTest
@testable import SweepApp

/// Pure logic behind `StartupItemsScreen` (module 6, PLAN §3): plist parsing into rows and
/// broken-item detection. `StartupItemsScanner` is exercised against a real temp directory since
/// it is a thin, already-injectable `FileManager` wrapper with nothing worth mocking.
///
/// NOTE for wiring: see `LargeOldFilesLogicTests.swift` — same target, not yet registered.
final class StartupItemsLogicTests: XCTestCase {

    private func plistData(label: String? = "com.example.agent", program: String? = "/usr/local/bin/agent", arguments: [String]? = nil, runAtLoad: Bool? = true) -> Data {
        var dict: [String: Any] = [:]
        if let label { dict["Label"] = label }
        if let program { dict["Program"] = program }
        if let arguments { dict["ProgramArguments"] = arguments }
        if let runAtLoad { dict["RunAtLoad"] = runAtLoad }
        return try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    // MARK: - Parsing

    func testParsesLabelProgramAndRunAtLoad() {
        let row = StartupItemParser.parse(
            plistData: plistData(),
            path: "/tmp/com.example.agent.plist",
            source: .userLaunchAgent,
            fileExists: { _ in true }
        )
        XCTAssertEqual(row?.label, "com.example.agent")
        XCTAssertEqual(row?.programPath, "/usr/local/bin/agent")
        XCTAssertEqual(row?.runAtLoad, true)
        XCTAssertEqual(row?.source, .userLaunchAgent)
        XCTAssertFalse(row!.isBroken)
    }

    func testFallsBackToFirstProgramArgumentWhenProgramIsMissing() {
        let row = StartupItemParser.parse(
            plistData: plistData(program: nil, arguments: ["/usr/local/bin/helper", "--flag"]),
            path: "/tmp/x.plist",
            source: .systemLaunchDaemon,
            fileExists: { _ in true }
        )
        XCTAssertEqual(row?.programPath, "/usr/local/bin/helper")
    }

    func testMissingLabelIsUnparseable() {
        let row = StartupItemParser.parse(
            plistData: plistData(label: nil),
            path: "/tmp/x.plist",
            source: .userLaunchAgent,
            fileExists: { _ in true }
        )
        XCTAssertNil(row)
    }

    func testMissingRunAtLoadDefaultsToFalse() {
        let row = StartupItemParser.parse(
            plistData: plistData(runAtLoad: nil),
            path: "/tmp/x.plist",
            source: .userLaunchAgent,
            fileExists: { _ in true }
        )
        XCTAssertEqual(row?.runAtLoad, false)
    }

    // MARK: - Broken-item detection

    func testMissingBinaryIsFlaggedBroken() {
        let row = StartupItemParser.parse(
            plistData: plistData(),
            path: "/tmp/x.plist",
            source: .userLaunchAgent,
            fileExists: { _ in false }
        )
        XCTAssertTrue(row!.isBroken)
    }

    func testExistingBinaryIsNotFlaggedBroken() {
        let row = StartupItemParser.parse(
            plistData: plistData(),
            path: "/tmp/x.plist",
            source: .userLaunchAgent,
            fileExists: { _ in true }
        )
        XCTAssertFalse(row!.isBroken)
    }

    func testNoProgramPathAtAllIsNotFlaggedBroken() {
        // Neither `Program` nor `ProgramArguments`: unusual, but this module has no basis to
        // call it broken rather than merely unusual.
        let row = StartupItemParser.parse(
            plistData: plistData(program: nil, arguments: nil),
            path: "/tmp/x.plist",
            source: .userLaunchAgent,
            fileExists: { _ in false }
        )
        XCTAssertNil(row?.programPath)
        XCTAssertFalse(row!.isBroken)
    }

    // MARK: - Directory scan (real temp directory: a thin FileManager wrapper, nothing to mock)

    func testScanDirectoryParsesPlistsAndSkipsOtherFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sweep-startup-items-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let zPlist = directory.appending(path: "zzz.plist")
        try plistData(label: "zzz.agent", program: "/bin/zzz").write(to: zPlist)
        let aPlist = directory.appending(path: "aaa.plist")
        try plistData(label: "aaa.agent", program: "/bin/aaa").write(to: aPlist)
        try "not a plist".data(using: .utf8)!.write(to: directory.appending(path: "notes.txt"))

        let rows = StartupItemsScanner.scanDirectory(directory, source: .userLaunchAgent)

        XCTAssertEqual(rows.count, 2, "the non-plist file must be skipped")
        XCTAssertEqual(rows.map(\.label), ["aaa.agent", "zzz.agent"], "rows are sorted by label")
        XCTAssertTrue(rows.allSatisfy { $0.source == .userLaunchAgent })
    }

    func testScanDirectoryOnMissingDirectoryReturnsEmpty() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "sweep-does-not-exist-\(UUID().uuidString)")
        XCTAssertTrue(StartupItemsScanner.scanDirectory(missing, source: .systemLaunchDaemon).isEmpty)
    }

    // MARK: - Filename fallback label

    func testFilenameFallbackLabelsAPlistWithNoLabelKey() {
        // Google Keystone ships a literally empty agent plist; launchd falls back to the filename
        // and so does the scanner, or two items vanish from a real Mac's inventory.
        let empty = try! PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
        let row = StartupItemParser.parse(
            plistData: empty,
            path: "/Library/LaunchAgents/com.google.keystone.agent.plist",
            source: .systemLaunchAgent,
            fallbackLabel: "com.google.keystone.agent",
            fileExists: { _ in true }
        )
        XCTAssertEqual(row?.label, "com.google.keystone.agent")
        XCTAssertEqual(row?.trigger, .onDemand)
    }

    func testScanDirectoryFallsBackToFilenameForALabellessPlist() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "sweep-startup-fallback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let empty = try PropertyListSerialization.data(fromPropertyList: [String: Any](), format: .xml, options: 0)
        try empty.write(to: directory.appending(path: "com.vendor.agent.plist"))

        let rows = StartupItemsScanner.scanDirectory(directory, source: .systemLaunchAgent)
        XCTAssertEqual(rows.map(\.label), ["com.vendor.agent"])
    }

    // MARK: - Trigger derivation

    func testKeepAliveBeatsRunAtLoad() {
        XCTAssertEqual(StartupItemParser.trigger(from: ["KeepAlive": true, "RunAtLoad": true], runAtLoad: true), .alwaysOn)
    }

    func testKeepAliveDictionaryIsAlsoAlwaysOn() {
        XCTAssertEqual(StartupItemParser.trigger(from: ["KeepAlive": ["SuccessfulExit": false]], runAtLoad: false), .alwaysOn)
    }

    func testStartIntervalIsReportedWhenNothingStartsItAtLogin() {
        XCTAssertEqual(
            StartupItemParser.trigger(from: ["StartInterval": 3600], runAtLoad: false),
            .everyInterval(seconds: 3600)
        )
    }

    func testCalendarWatchAndOnDemandTriggers() {
        XCTAssertEqual(StartupItemParser.trigger(from: ["StartCalendarInterval": ["Hour": 3]], runAtLoad: false), .onSchedule)
        XCTAssertEqual(StartupItemParser.trigger(from: ["WatchPaths": ["/tmp"]], runAtLoad: false), .onFileChange)
        XCTAssertEqual(StartupItemParser.trigger(from: [:], runAtLoad: false), .onDemand)
    }

    func testZeroOrNegativeStartIntervalIsNotReportedAsATimer() {
        XCTAssertEqual(StartupItemParser.trigger(from: ["StartInterval": 0], runAtLoad: false), .onDemand)
    }

    func testIntervalPhrasesReadCorrectlyAfterEvery() {
        XCTAssertEqual(StartupItemTrigger.intervalPhrase(45), "45 seconds")
        XCTAssertEqual(StartupItemTrigger.intervalPhrase(1800), "30 min")
        XCTAssertEqual(StartupItemTrigger.intervalPhrase(3600), "hour")
        XCTAssertEqual(StartupItemTrigger.intervalPhrase(10_800), "3 hours")
        XCTAssertEqual(StartupItemTrigger.intervalPhrase(86_400), "day")
    }

    func testStartsByItselfExcludesOnDemandAndFileWatchers() {
        XCTAssertTrue(row(trigger: ["RunAtLoad": true]).startsByItself)
        XCTAssertTrue(row(trigger: ["StartInterval": 600]).startsByItself)
        XCTAssertFalse(row(trigger: ["WatchPaths": ["/tmp"]]).startsByItself)
        XCTAssertFalse(row(trigger: [:]).startsByItself)
    }

    private func row(trigger keys: [String: Any], label: String = "com.example.agent", program: String = "/bin/true") -> StartupItemRow {
        var dict: [String: Any] = ["Label": label, "Program": program]
        dict.merge(keys) { _, new in new }
        let data = try! PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
        return StartupItemParser.parse(
            plistData: data, path: "/tmp/x.plist", source: .userLaunchAgent, fileExists: { _ in true }
        )!
    }

    // MARK: - Category

    func testAppleLabelsAreClassifiedAsSystemRegardlessOfKeywords() {
        XCTAssertEqual(
            StartupItemCategory.classify(label: "com.apple.backupd", executablePath: "/usr/bin/backupd", isScriptJob: false),
            .appleSystem
        )
    }

    func testUpdaterBeatsTheVendorsOtherVocabulary() {
        // us.zoom.updater is a conferencing vendor shipping an updater — the job is the updater.
        XCTAssertEqual(
            StartupItemCategory.classify(label: "us.zoom.updater", executablePath: "/Applications/zoom.us.app/Contents/MacOS/ZoomUpdater", isScriptJob: false),
            .updater
        )
    }

    func testScriptJobsWithNoKeywordFallBackToCustomJob() {
        XCTAssertEqual(
            StartupItemCategory.classify(label: "com.aditya.jobpilot.cycle", executablePath: "/Users/x/bin/cycle.sh", isScriptJob: true),
            .automation
        )
        XCTAssertEqual(
            StartupItemCategory.classify(label: "com.vendor.thing", executablePath: "/usr/local/bin/thing", isScriptJob: false),
            .helper
        )
    }

    // MARK: - launchctl parsing

    func testParsesLaunchctlListColumns() {
        let output = """
        PID\tStatus\tLabel
        884\t0\tcom.microsoft.teams2.agent
        -\t0\tus.zoom.updater
        -\t78\tcom.egnyte.egnyteWebEdit
        -\t-9\tcom.apple.progressd
        """
        let statuses = LaunchctlListParser.parse(output)
        XCTAssertEqual(statuses.count, 4, "the header row must not become an entry")
        XCTAssertEqual(statuses["com.microsoft.teams2.agent"]?.pid, 884)
        XCTAssertNil(statuses["us.zoom.updater"]?.pid)
        XCTAssertEqual(statuses["com.egnyte.egnyteWebEdit"]?.lastExitStatus, 78)
        XCTAssertEqual(statuses["com.apple.progressd"]?.lastExitStatus, -9)
    }

    func testMalformedLaunchctlLinesAreSkipped() {
        XCTAssertTrue(LaunchctlListParser.parse("garbage\nalso garbage\n").isEmpty)
    }

    // MARK: - Run state

    func testRunStateReadsPIDThenExitStatus() {
        let agent = row(trigger: [:])
        XCTAssertEqual(StartupItemRunState.resolve(row: agent, status: LaunchdStatus(pid: 42, lastExitStatus: 0)), .running(pid: 42))
        XCTAssertEqual(StartupItemRunState.resolve(row: agent, status: LaunchdStatus(pid: nil, lastExitStatus: 78)), .failed(code: 78))
        XCTAssertEqual(StartupItemRunState.resolve(row: agent, status: LaunchdStatus(pid: nil, lastExitStatus: 0)), .loaded)
        XCTAssertEqual(StartupItemRunState.resolve(row: agent, status: nil), .notLoaded)
    }

    func testAnAbsentRootDaemonIsUnknownNotNotLoaded() {
        // `launchctl list` only sees the caller's own domain, so silence about a daemon proves
        // nothing and must never be rendered as "not loaded".
        let data = try! PropertyListSerialization.data(
            fromPropertyList: ["Label": "com.vendor.daemon", "Program": "/bin/true"], format: .xml, options: 0
        )
        let daemon = StartupItemParser.parse(
            plistData: data, path: "/tmp/d.plist", source: .systemLaunchDaemon, fileExists: { _ in true }
        )!
        XCTAssertEqual(StartupItemRunState.resolve(row: daemon, status: nil), .unknown)
        XCTAssertNil(StartupItemRunState.unknown.label, "an unknown state must render no chip at all")
    }

    func testDisabledInPlistWinsOverEverything() {
        let disabled = row(trigger: ["Disabled": true, "RunAtLoad": true])
        XCTAssertEqual(StartupItemRunState.resolve(row: disabled, status: LaunchdStatus(pid: 9, lastExitStatus: 0)), .disabled)
    }

    // MARK: - Attribution

    func testInterpreterProgramsAttributeToTheScriptTheyWereHanded() {
        XCTAssertEqual(
            StartupItemAttribution.executablePath(programPath: "/bin/zsh", arguments: ["/bin/zsh", "/Users/x/bin/cycle.sh"]),
            "/Users/x/bin/cycle.sh"
        )
        XCTAssertEqual(
            StartupItemAttribution.executablePath(programPath: "/usr/local/bin/agent", arguments: ["/usr/local/bin/agent", "--flag"]),
            "/usr/local/bin/agent"
        )
    }

    func testInterpreterWithNoScriptArgumentKeepsTheInterpreter() {
        XCTAssertEqual(
            StartupItemAttribution.executablePath(programPath: "/bin/zsh", arguments: ["/bin/zsh", "-c", "echo hi"]),
            "/bin/zsh"
        )
    }

    func testOutermostAppBundleWinsOverANestedHelperBundle() {
        XCTAssertEqual(
            StartupItemAttribution.outermostAppBundlePath(
                for: "/Applications/zoom.us.app/Contents/Library/LaunchAgents/ZoomUpdater.app/Contents/MacOS/ZoomUpdater"
            ),
            "/Applications/zoom.us.app"
        )
        XCTAssertNil(StartupItemAttribution.outermostAppBundlePath(for: "/usr/local/bin/agent"))
    }

    func testVendorTokenSkipsTheReverseDNSPrefix() {
        XCTAssertEqual(StartupItemAttribution.vendorToken(fromLabel: "com.google.keystone.agent"), "google")
        XCTAssertEqual(StartupItemAttribution.vendorToken(fromLabel: "us.zoom.updater"), "zoom")
        XCTAssertEqual(StartupItemAttribution.vendorToken(fromLabel: "io.tailscale.ipn.macsys"), "tailscale")
        XCTAssertNil(StartupItemAttribution.vendorToken(fromLabel: "singleton"))
    }

    func testVendorDisplayNamesFallBackToACapitalizedToken() {
        XCTAssertEqual(StartupItemAttribution.vendorDisplayName(forToken: "nordvpn"), "NordVPN")
        XCTAssertEqual(StartupItemAttribution.vendorDisplayName(forToken: "acmesoft"), "Acmesoft")
    }

    func testBundleIDPrefixesAreLongestFirst() {
        XCTAssertEqual(
            StartupItemAttribution.bundleIDPrefixes(forLabel: "com.google.keystone.agent"),
            ["com.google.keystone", "com.google"]
        )
        XCTAssertTrue(StartupItemAttribution.bundleIDPrefixes(forLabel: "solo").isEmpty)
    }

    func testFriendlyNameDropsTheVendorPrefixAndKeepsGenericTailsInContext() {
        XCTAssertEqual(StartupItemAttribution.friendlyName(fromLabel: "com.google.keystone.agent"), "Keystone Agent")
        XCTAssertEqual(StartupItemAttribution.friendlyName(fromLabel: "us.zoom.updater"), "Updater")
        XCTAssertEqual(StartupItemAttribution.friendlyName(fromLabel: "com.microsoft.OneDriveStandaloneUpdater"), "OneDriveStandaloneUpdater")
        XCTAssertEqual(StartupItemAttribution.friendlyName(fromLabel: "com.asreerama.ssd-janitor"), "SSD Janitor")
        XCTAssertEqual(StartupItemAttribution.friendlyName(fromLabel: "com.google.keystone.xpcservice"), "Keystone XPC Service")
    }

    // MARK: - Owner resolution

    private var emptyIndex: InstalledAppIndex { InstalledAppIndex(byBundleID: [:]) }

    func testAssociatedBundleIdentifierWinsOverEveryOtherSignal() {
        let index = InstalledAppIndex(byBundleID: ["us.zoom.xos": "/Applications/zoom.us.app"])
        let data = try! PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "us.zoom.updater",
                "AssociatedBundleIdentifiers": ["us.zoom.xos"],
                "ProgramArguments": ["/opt/zoom/helper"],
            ] as [String: Any],
            format: .xml, options: 0
        )
        let parsed = StartupItemParser.parse(plistData: data, path: "/tmp/z.plist", source: .systemLaunchAgent, fileExists: { _ in true })!
        let owner = StartupOwnerResolver.owner(for: parsed, index: index)
        XCTAssertEqual(owner.kind, .app)
        XCTAssertEqual(owner.appPath, "/Applications/zoom.us.app")
    }

    func testAVendorPrefixMatchingExactlyOneInstalledAppAttributesToThatApp() {
        let index = InstalledAppIndex(byBundleID: ["com.acme.Widget": "/Applications/Widget.app"])
        let owner = StartupOwnerResolver.owner(for: row(trigger: [:], label: "com.acme.updater"), index: index)
        XCTAssertEqual(owner.appPath, "/Applications/Widget.app")
    }

    func testAVendorPrefixMatchingSeveralAppsFallsBackToTheVendorName() {
        let index = InstalledAppIndex(byBundleID: [
            "com.google.Chrome": "/Applications/Google Chrome.app",
            "com.google.drivefs": "/Applications/Google Drive.app",
        ])
        let owner = StartupOwnerResolver.owner(for: row(trigger: [:], label: "com.google.keystone.agent"), index: index)
        XCTAssertEqual(owner.kind, .vendor)
        XCTAssertEqual(owner.name, "Google")
        XCTAssertNil(owner.appPath)
    }

    func testAppleLabelsGroupUnderMacOSRatherThanAFabricatedVendor() {
        let owner = StartupOwnerResolver.owner(for: row(trigger: [:], label: "com.apple.somethingd"), index: emptyIndex)
        XCTAssertEqual(owner.kind, .apple)
        XCTAssertTrue(owner.isApple)
    }

    func testHandWrittenScriptJobsGroupUnderScriptsNotAMadeUpVendor() {
        let data = try! PropertyListSerialization.data(
            fromPropertyList: [
                "Label": "com.asreerama.ssd-janitor",
                "ProgramArguments": ["/bin/zsh", "/usr/local/bin/janitor.sh"],
            ] as [String: Any],
            format: .xml, options: 0
        )
        let parsed = StartupItemParser.parse(plistData: data, path: "/tmp/j.plist", source: .systemLaunchDaemon, fileExists: { _ in true })!
        let owner = StartupOwnerResolver.owner(for: parsed, index: emptyIndex)
        XCTAssertEqual(owner.kind, .scripts)
    }

    // MARK: - SMAppService status mapping

    func testDescribesEveryDocumentedStatus() {
        XCTAssertEqual(SMAppServiceInventory.describe(.notRegistered), "Not registered")
        XCTAssertEqual(SMAppServiceInventory.describe(.enabled), "Enabled")
        XCTAssertEqual(SMAppServiceInventory.describe(.requiresApproval), "Requires approval")
        XCTAssertEqual(SMAppServiceInventory.describe(.notFound), "Not found")
    }
}
