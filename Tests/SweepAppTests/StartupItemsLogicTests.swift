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

    // MARK: - SMAppService status mapping

    func testDescribesEveryDocumentedStatus() {
        XCTAssertEqual(SMAppServiceInventory.describe(.notRegistered), "Not registered")
        XCTAssertEqual(SMAppServiceInventory.describe(.enabled), "Enabled")
        XCTAssertEqual(SMAppServiceInventory.describe(.requiresApproval), "Requires approval")
        XCTAssertEqual(SMAppServiceInventory.describe(.notFound), "Not found")
    }
}
