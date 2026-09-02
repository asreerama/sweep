import XCTest
@testable import SweepApp

final class BrewGatewayTests: XCTestCase {

    // MARK: - `brew outdated --json=v2` decoding

    /// Captured verbatim from a real `brew outdated --json=v2` run (Homebrew 6.0.15, 2026-09-01) —
    /// a schema-drift tripwire, same spirit as `SchemaDriftTests` for the rule catalog: if
    /// Homebrew ever renames a field, this fails loudly instead of `HomebrewModel` quietly
    /// showing zero outdated packages.
    private static let realShapedJSON = """
    {
      "formulae": [
        {
          "name": "node",
          "installed_versions": ["26.4.0"],
          "current_version": "26.8.1",
          "pinned": false,
          "pinned_version": null
        },
        {
          "name": "go",
          "installed_versions": ["1.26.1", "1.26.4"],
          "current_version": "1.27.0",
          "pinned": false,
          "pinned_version": null
        }
      ],
      "casks": [
        {
          "name": "home-assistant",
          "installed_versions": ["2026.4,2026.1862"],
          "current_version": "2026.9.0,2026.2874",
          "pinned": false,
          "pinned_version": null
        }
      ]
    }
    """

    func testDecodesRealShapedOutdatedJSON() throws {
        let data = try XCTUnwrap(Self.realShapedJSON.data(using: .utf8))
        let response = try JSONDecoder().decode(BrewOutdatedResponse.self, from: data)

        XCTAssertEqual(response.formulae.count, 2)
        XCTAssertEqual(response.formulae[0].name, "node")
        XCTAssertEqual(response.formulae[0].installedVersions, ["26.4.0"])
        XCTAssertEqual(response.formulae[0].currentVersion, "26.8.1")
        // Multiple installed versions kept side-by-side (e.g. `go`): the last one is what
        // `RealBrewGateway.buildSnapshot` shows as "installed" — the most recently installed.
        XCTAssertEqual(response.formulae[1].installedVersions, ["1.26.1", "1.26.4"])

        XCTAssertEqual(response.casks.count, 1)
        XCTAssertEqual(response.casks[0].name, "home-assistant")
    }

    func testDecodesEmptyOutdatedResponse() throws {
        let data = try XCTUnwrap("{\"formulae\": [], \"casks\": []}".data(using: .utf8))
        let response = try JSONDecoder().decode(BrewOutdatedResponse.self, from: data)
        XCTAssertTrue(response.formulae.isEmpty)
        XCTAssertTrue(response.casks.isEmpty)
    }

    // MARK: - DirectorySize

    func testAllocatedBytesSumsRegularFilesUnderADirectory() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        try Data(repeating: 0, count: 4096).write(to: root.appending(path: "a.bin"))
        let nested = root.appending(path: "nested", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 8192).write(to: nested.appending(path: "b.bin"))

        let total = DirectorySize.allocatedBytes(atPath: root.path)
        // Allocated (block) size, not logical size: assert a reasonable floor rather than an
        // exact byte count, since APFS block allocation can round up.
        XCTAssertGreaterThanOrEqual(total, 4096 + 8192)
    }

    func testAllocatedBytesOfAMissingPathIsZeroNotAnError() {
        let missing = URL(fileURLWithPath: "/private/tmp/sweep-directorysize-does-not-exist-\(UUID().uuidString)")
        XCTAssertEqual(DirectorySize.allocatedBytes(atPath: missing.path), 0)
    }

    func testAllocatedBytesDoesNotFollowSymlinksIntoASiblingTree() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let real = root.appending(path: "real", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 4096).write(to: real.appending(path: "f.bin"))

        let linked = root.appending(path: "linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: real)

        // Sizing `root` should count `real/f.bin` exactly once via the `real` subdirectory, and
        // the symlink `linked` itself contributes nothing (never followed, never a regular file).
        let total = DirectorySize.allocatedBytes(atPath: root.path)
        XCTAssertGreaterThanOrEqual(total, 4096)
        XCTAssertLessThan(total, 4096 * 2, "the symlink must not be followed into a second copy of `real`")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "sweep-directorysize-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - BrewExecutable (sanity only — the two candidate paths are fixed, not injectable)

    func testLocateOnlyEverReturnsOneOfTheTwoFixedAbsolutePaths() {
        guard let located = BrewExecutable.locate() else { return }
        XCTAssertTrue(
            located == BrewExecutable.appleSiliconPath || located == BrewExecutable.intelPath,
            "locate() returned a path outside the fixed candidate set: \(located)"
        )
        XCTAssertTrue(located.hasPrefix("/"), "must be an absolute path — PLAN §2 typed adapters")
    }
}
