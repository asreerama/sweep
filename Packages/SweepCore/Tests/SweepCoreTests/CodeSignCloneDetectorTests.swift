import XCTest
@testable import SweepCore

/// Fixture-based: a fake `X` directory built fresh per test under the system temporary
/// directory (via ``TempTree``), never the real `/var/folders`. ``CodeSignCloneDetector/scan()``
/// (the `confstr`-resolving entry point) is never called here on purpose.
final class CodeSignCloneDetectorTests: XCTestCase {

    private let hourAgo = Date().addingTimeInterval(-3_600)

    func testStaleNotRunningCloneIsDetected() throws {
        let tree = try TempTree("codeSignClone-stale")
        let xDirectory = try tree.makeDirectory("X")
        let clone = try tree.makeDirectory("X/com.example.Stale.code_sign_clone")
        let payload = try tree.write("X/com.example.Stale.code_sign_clone/payload.bin", bytes: 4_096)
        try Self.setModificationDate(hourAgo, at: clone)

        let detector = CodeSignCloneDetector(isRunning: { _ in false })
        let candidates = try detector.scan(directory: xDirectory)

        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidate.bundleIdentifier, "com.example.Stale")
        XCTAssertEqual(candidate.group, .systemJunk)
        XCTAssertEqual(candidate.tier, .safe)
        XCTAssertEqual(candidate.undo, .regenerated)
        XCTAssertEqual(candidate.detectorSource, CodeSignCloneCandidate.detectorSource)
        XCTAssertTrue(candidate.sizeIsCoWApparent)
        XCTAssertNil(candidate.candidate.ruleID)
        // `/var` is itself a symlink to `/private/var`; the enumerator resolves it while the
        // fixture helper's plain path arithmetic does not, so compare resolved paths.
        XCTAssertEqual(
            candidate.candidate.url.resolvingSymlinksInPath().path,
            clone.resolvingSymlinksInPath().path
        )
        XCTAssertEqual(candidate.candidate.allocatedSize, try Self.totalFileAllocatedSize(at: payload))
    }

    func testTooYoungCloneIsSkipped() throws {
        let tree = try TempTree("codeSignClone-young")
        let xDirectory = try tree.makeDirectory("X")
        try tree.makeDirectory("X/com.example.Young.code_sign_clone")
        try tree.write("X/com.example.Young.code_sign_clone/payload.bin", bytes: 1_024)
        // Left at its just-created mtime: newer than the 10-minute default minimum age.

        let detector = CodeSignCloneDetector(isRunning: { _ in false })
        let candidates = try detector.scan(directory: xDirectory)

        XCTAssertTrue(candidates.isEmpty, "a clone younger than the minimum age must not be reported")
    }

    func testCloneOfRunningAppIsSkipped() throws {
        let tree = try TempTree("codeSignClone-running")
        let xDirectory = try tree.makeDirectory("X")
        let clone = try tree.makeDirectory("X/com.example.Running.code_sign_clone")
        try tree.write("X/com.example.Running.code_sign_clone/payload.bin", bytes: 1_024)
        try Self.setModificationDate(hourAgo, at: clone)

        let detector = CodeSignCloneDetector(isRunning: { $0 == "com.example.Running" })
        let candidates = try detector.scan(directory: xDirectory)

        XCTAssertTrue(candidates.isEmpty, "a clone of a running app must not be reported even when stale")
    }

    func testNonCloneDirectoryIsIgnored() throws {
        let tree = try TempTree("codeSignClone-nonclone")
        let xDirectory = try tree.makeDirectory("X")
        let unrelated = try tree.makeDirectory("X/SomeOtherTempDir")
        try tree.write("X/SomeOtherTempDir/file.bin", bytes: 1_024)
        try Self.setModificationDate(hourAgo, at: unrelated)

        let detector = CodeSignCloneDetector(isRunning: { _ in true }) // would report if suffix matched
        let candidates = try detector.scan(directory: xDirectory)

        XCTAssertTrue(candidates.isEmpty, "a directory without the .code_sign_clone suffix is never a candidate")
    }

    func testMixedDirectoryReportsOnlyTheStaleNotRunningClone() throws {
        let tree = try TempTree("codeSignClone-mixed")
        let xDirectory = try tree.makeDirectory("X")

        let stale = try tree.makeDirectory("X/com.example.Stale.code_sign_clone")
        try tree.write("X/com.example.Stale.code_sign_clone/payload.bin", bytes: 4_096)
        try Self.setModificationDate(hourAgo, at: stale)

        try tree.makeDirectory("X/com.example.Young.code_sign_clone")
        try tree.write("X/com.example.Young.code_sign_clone/payload.bin", bytes: 2_048)

        let running = try tree.makeDirectory("X/com.example.Running.code_sign_clone")
        try tree.write("X/com.example.Running.code_sign_clone/payload.bin", bytes: 8_192)
        try Self.setModificationDate(hourAgo, at: running)

        let unrelated = try tree.makeDirectory("X/SomeOtherTempDir")
        try Self.setModificationDate(hourAgo, at: unrelated)

        let detector = CodeSignCloneDetector(isRunning: { $0 == "com.example.Running" })
        let candidates = try detector.scan(directory: xDirectory)

        XCTAssertEqual(candidates.map(\.bundleIdentifier), ["com.example.Stale"])
    }

    func testEmptyOrMissingDirectoryReportsNothing() throws {
        let tree = try TempTree("codeSignClone-missing")
        let missing = tree.url("does-not-exist/X")

        let detector = CodeSignCloneDetector(isRunning: { _ in false })
        XCTAssertEqual(try detector.scan(directory: missing), [])
    }

    // MARK: - Codex G1 finding #7 (NOT-CLOSED): no decoding construction route

    /// Before this fix, `CodeSignCloneCandidate` was still `Codable` even though its memberwise
    /// initializer was already internal. A caller outside this package could
    /// `JSONDecoder().decode(CodeSignCloneCandidate.self, from:)` an arbitrary payload and hand
    /// `CleanService` a candidate with a forged `candidate.identity`. This asserts the dynamic
    /// conformance check itself, not just that no call site in this repo happens to decode one.
    func testCodeSignCloneCandidateHasNoDecodableConformance() {
        XCTAssertNil(
            CodeSignCloneCandidate.self as? Decodable.Type,
            "CodeSignCloneCandidate must not be Decodable: decoding an arbitrary payload would forge a candidate"
        )
    }

    func testBundleIdentifierParsing() {
        XCTAssertEqual(
            CodeSignCloneDetector.bundleIdentifier(forCloneNamed: "com.google.Chrome.code_sign_clone"),
            "com.google.Chrome"
        )
        XCTAssertNil(CodeSignCloneDetector.bundleIdentifier(forCloneNamed: "SomeOtherTempDir"))
        XCTAssertNil(CodeSignCloneDetector.bundleIdentifier(forCloneNamed: ".code_sign_clone"))
    }

    // MARK: - Helpers

    private static func setModificationDate(_ date: Date, at url: URL) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    private static func totalFileAllocatedSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
        return Int64(try XCTUnwrap(values.totalFileAllocatedSize))
    }
}
