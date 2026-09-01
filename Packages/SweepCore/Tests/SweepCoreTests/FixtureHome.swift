import Foundation
import XCTest
@testable import SweepCore

/// A disposable directory standing in for a user's home directory, so `SweepPolicy.authorize`
/// (and everything built on it — ``AuthorizedCleanPlan``, `CleanService`) can be exercised
/// end-to-end without ever touching the real home directory or real user data (PLAN §6:
/// "Deletion code is only ever pointed at [a fixture]").
///
/// Shaped closely enough after `scripts/make-fixtures.sh` for Gate 1 purposes: junk under
/// `Library/Caches/<app>`, and a VS Code `User` canary that must survive any clean regardless of
/// how broad a rule's selection is.
final class FixtureHome: Sendable {
    let root: URL

    init(_ label: String = "home") throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "SweepCoreTests-\(label)-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func url(_ relative: String) -> URL {
        root.appending(path: relative)
    }

    @discardableResult
    func makeDirectory(_ relative: String) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func write(_ relative: String, contents: String = "junk") throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: target)
        return target
    }

    /// `scripts/make-fixtures.sh`'s VS Code `User` trap: settings that a real cache rule must
    /// never reach, however broadly it is written.
    @discardableResult
    func writeCanary() throws -> URL {
        try write(
            "Library/Application Support/Code/User/FIXTURE_CANARY_DO_NOT_DELETE.txt",
            contents: """
            FIXTURE CANARY: This file marks a critical user data directory.
            If this file is deleted during testing, the clean was incorrect.
            """
        )
    }

    func exists(_ relative: String) -> Bool {
        FileManager.default.fileExists(atPath: url(relative).path)
    }

    /// Builds a `ScanCandidate` the way a real rule-driven scan would: identity read straight off
    /// disk, never asserted by the caller.
    func candidate(at relative: String, ruleID: String?) throws -> ScanCandidate {
        let target = url(relative)
        let identity = try FileIdentity.read(at: target)
        let parentIdentity = try? FileIdentity.read(at: target.deletingLastPathComponent())
        let allocated = (try? target.resourceValues(forKeys: [.totalFileAllocatedSizeKey]))?.totalFileAllocatedSize
        return ScanCandidate(
            url: target,
            identity: identity,
            parentIdentity: parentIdentity,
            allocatedSize: Int64(allocated ?? 0),
            ruleID: ruleID
        )
    }

    /// Wraps ``candidate(at:ruleID:)`` as a ``SelectionReceipt`` — the shape `CleanRequest`
    /// actually takes since Codex Gate-1 finding #6. Package-internal `SelectionReceipt.init` is
    /// reachable here because every SweepCoreTests file is `@testable import SweepCore`; this
    /// stands in for "a real scan already produced this receipt".
    func receipt(at relative: String, ruleID: String?) throws -> SelectionReceipt {
        SelectionReceipt(candidate: try candidate(at: relative, ruleID: ruleID), scanSessionID: UUID())
    }
}
