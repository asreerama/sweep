import XCTest
@testable import SweepPolicy

final class PolicyTests: XCTestCase {
    func testProtectedAreasDenied() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        XCTAssertTrue(SweepPolicy.isDeniedLexically(home.appending(path: "Documents/taxes.pdf")))
        XCTAssertTrue(SweepPolicy.isDeniedLexically(home.appending(path: "Library/CloudStorage/Dropbox/x")))
        XCTAssertTrue(SweepPolicy.isDeniedLexically(home.appending(path: "Library/Mail/V10/anything")))
        XCTAssertFalse(SweepPolicy.isDeniedLexically(home.appending(path: "Library/Caches/com.example.app")))
    }

    // MARK: - Review finding #4: sweepItself was empty

    func testSweepItselfIsPopulatedFromTheRunningBundle() {
        let areas = SweepPolicy.protectedURLs()
        let sweep = try? XCTUnwrap(areas[.sweepItself])
        XCTAssertFalse(sweep?.isEmpty ?? true, "Sweep must never be able to clean Sweep")

        let inside = Bundle.main.bundleURL.appending(path: "Contents/MacOS/whatever")
        XCTAssertTrue(SweepPolicy.isDeniedLexically(inside), "a path inside the running image is protected")
    }

    // MARK: - Review finding #4: the denylist was case-bypassable

    func testCaseFoldedProtectedPathIsDeniedOnACaseInsensitiveVolume() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let comparison = NameComparison.forVolume(containing: home)
        try XCTSkipIf(comparison.isCaseSensitive, "home volume is case-sensitive; folding does not apply")

        // Byte-wise prefix matching lets this through; the volume does not.
        XCTAssertTrue(SweepPolicy.isDeniedLexically(home.appending(path: "documents/taxes.pdf")))
        XCTAssertTrue(SweepPolicy.isDeniedLexically(home.appending(path: "DOCUMENTS/taxes.pdf")))
        XCTAssertTrue(SweepPolicy.isDeniedLexically(home.appending(path: "Library/cloudstorage/Dropbox/x")))
    }

    func testDecomposedUnicodeNameIsFoldedToTheSameComparison() {
        let comparison = NameComparison(isCaseSensitive: true)
        let precomposed = "/Users/x/Documents/re\u{00E9}sum\u{00E9}"
        let decomposed = "/Users/x/Documents/re\u{0065}\u{0301}sum\u{0065}\u{0301}"
        XCTAssertTrue(comparison.isSame(precomposed, decomposed))
    }

    // MARK: - Review finding #4: operation-scoped, deny-by-default authorization

    func testAuthorizeAllowsAFileUnderTheResolvedRoot() throws {
        let home = try TemporaryHome()
        let file = try home.write("Library/Logs/app/session.log", contents: "hello")
        let identity = try XCTUnwrap(PathIdentity.read(at: file))

        let decision = SweepPolicy.authorize(
            root: .userLogs,
            resolvedPath: file,
            identity: identity,
            home: home.root
        )

        let authorization = try XCTUnwrap(decision.authorization, "unexpected \(decision)")
        XCTAssertEqual(authorization.identity, identity)
        XCTAssertEqual(authorization.root.root, .userLogs)
        XCTAssertFalse(authorization.ancestors.isEmpty, "the parent chain is recorded")
    }

    func testAnythingOutsideTheRequestedRootIsDeniedByDefault() throws {
        let home = try TemporaryHome()
        try home.makeDirectory("Library/Logs")
        let elsewhere = try home.write("Library/Caches/not-a-log.bin", contents: "x")
        let identity = try XCTUnwrap(PathIdentity.read(at: elsewhere))

        let decision = SweepPolicy.authorize(
            root: .userLogs,
            resolvedPath: elsewhere,
            identity: identity,
            home: home.root
        )

        guard case .denied(.outsideRequestedRoot) = decision else {
            return XCTFail("expected outsideRequestedRoot, got \(decision)")
        }
    }

    func testTheRootItselfIsNeverATarget() throws {
        let home = try TemporaryHome()
        let logs = try home.makeDirectory("Library/Logs")
        let identity = try XCTUnwrap(PathIdentity.read(at: logs))

        let decision = SweepPolicy.authorize(
            root: .userLogs,
            resolvedPath: logs,
            identity: identity,
            home: home.root
        )

        guard case .denied(.rootItself) = decision else {
            return XCTFail("expected rootItself, got \(decision)")
        }
    }

    func testUnresolvableRootIsDenied() throws {
        let home = try TemporaryHome()   // no Library/Logs created
        let decision = SweepPolicy.authorize(
            root: .userLogs,
            resolvedPath: home.url("Library/Logs/x.log"),
            identity: PathIdentity(deviceID: 1, inode: 1),
            home: home.root
        )

        guard case .denied(.rootUnavailable(.userLogs)) = decision else {
            return XCTFail("expected rootUnavailable, got \(decision)")
        }
    }

    func testSymlinkedParentBelowTheRootIsRefusedNotFollowed() throws {
        let home = try TemporaryHome()
        try home.makeDirectory("Library/Logs")
        let outside = try home.makeDirectory("elsewhere")
        try Data("secret".utf8).write(to: outside.appending(path: "victim.log"))
        try FileManager.default.createSymbolicLink(
            at: home.url("Library/Logs/link"),
            withDestinationURL: outside
        )

        let through = home.url("Library/Logs/link/victim.log")
        let identity = try XCTUnwrap(PathIdentity.read(at: through))

        let decision = SweepPolicy.authorize(
            root: .userLogs,
            resolvedPath: through,
            identity: identity,
            home: home.root
        )

        guard case .denied(.symlinkComponent(_, let component)) = decision else {
            return XCTFail("expected symlinkComponent, got \(decision)")
        }
        XCTAssertEqual(component, "link")
    }

    func testIdentityMismatchIsDenied() throws {
        let home = try TemporaryHome()
        let file = try home.write("Library/Logs/app.log", contents: "hello")

        let decision = SweepPolicy.authorize(
            root: .userLogs,
            resolvedPath: file,
            identity: PathIdentity(deviceID: 999_999, inode: 999_999),
            home: home.root
        )

        guard case .denied(.identityMismatch) = decision else {
            return XCTFail("expected identityMismatch, got \(decision)")
        }
    }

    /// The denylist has to bite on *resolved* identities. Here ~/Documents is a symlink into the
    /// operation root, so the target is lexically a plain path under an allowed root and only
    /// resolution exposes it as protected user data.
    func testProtectedAreaReachedThroughAnAllowedRootIsDenied() throws {
        let home = try TemporaryHome()
        let hidden = try home.makeDirectory("Library/Logs/docs")
        let file = hidden.appending(path: "taxes.pdf")
        try Data("private".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: home.url("Documents"), withDestinationURL: hidden)

        let identity = try XCTUnwrap(PathIdentity.read(at: file))
        let decision = SweepPolicy.authorize(
            root: .userLogs,
            resolvedPath: file,
            identity: identity,
            home: home.root
        )

        guard case .denied(.protectedArea(.documents, _)) = decision else {
            return XCTFail("expected protectedArea(.documents), got \(decision)")
        }
    }

    func testProtectedAreaMatchesOnIdentityNotOnlyOnPathname() throws {
        let home = try TemporaryHome()
        let documents = try home.makeDirectory("Documents")
        let identity = try XCTUnwrap(PathIdentity.read(at: documents))

        let violation = SweepPolicy.protectedAreaViolation(
            path: "/some/unrelated/pathname",
            identities: [identity],
            comparison: NameComparison(isCaseSensitive: true),
            home: home.root
        )
        XCTAssertEqual(violation, .documents, "an ancestor identity alone is enough to refuse")
    }

    func testResolvedRootsArePinnedToAnIdentity() throws {
        let home = try TemporaryHome()
        let logs = try home.makeDirectory("Library/Logs")
        let roots = SweepPolicy.resolvedRoots(for: .userLogs, home: home.root)

        XCTAssertEqual(roots.count, 1)
        XCTAssertEqual(roots.first?.identity, PathIdentity.read(at: logs))
        XCTAssertEqual(roots.first?.url.path, realpathOf(logs.path))
    }

    // MARK: - External-root authorization (SweepCore's code-sign-clone detector)

    func testExternalRootAllowsAFileBelowIt() throws {
        let home = try TemporaryHome()
        let clone = try home.write("X/com.example.App.code_sign_clone/payload.bin", contents: "hi")
        let identity = try XCTUnwrap(PathIdentity.read(at: clone))

        let decision = SweepPolicy.authorize(
            externalRoot: home.url("X"),
            resolvedPath: clone,
            identity: identity,
            home: home.root
        )

        let authorization = try XCTUnwrap(decision.authorization, "unexpected \(decision)")
        XCTAssertEqual(authorization.identity, identity)
        XCTAssertFalse(authorization.ancestors.isEmpty)
    }

    func testExternalRootItselfIsNeverATarget() throws {
        let home = try TemporaryHome()
        let root = try home.makeDirectory("X")
        let identity = try XCTUnwrap(PathIdentity.read(at: root))

        let decision = SweepPolicy.authorize(externalRoot: root, resolvedPath: root, identity: identity, home: home.root)

        guard case .denied(.outsideRequestedRoot) = decision else {
            return XCTFail("expected outsideRequestedRoot, got \(decision)")
        }
    }

    func testExternalRootAnythingOutsideIsDenied() throws {
        let home = try TemporaryHome()
        try home.makeDirectory("X")
        let elsewhere = try home.write("elsewhere/file.bin", contents: "x")
        let identity = try XCTUnwrap(PathIdentity.read(at: elsewhere))

        let decision = SweepPolicy.authorize(
            externalRoot: home.url("X"),
            resolvedPath: elsewhere,
            identity: identity,
            home: home.root
        )

        guard case .denied(.outsideRequestedRoot) = decision else {
            return XCTFail("expected outsideRequestedRoot, got \(decision)")
        }
    }

    func testExternalRootSymlinkedComponentIsRefused() throws {
        let home = try TemporaryHome()
        try home.makeDirectory("X")
        let outside = try home.makeDirectory("elsewhere")
        try Data("secret".utf8).write(to: outside.appending(path: "victim.bin"))
        try FileManager.default.createSymbolicLink(at: home.url("X/link"), withDestinationURL: outside)

        let through = home.url("X/link/victim.bin")
        let identity = try XCTUnwrap(PathIdentity.read(at: through))

        let decision = SweepPolicy.authorize(
            externalRoot: home.url("X"),
            resolvedPath: through,
            identity: identity,
            home: home.root
        )

        guard case .denied(.symlinkComponent) = decision else {
            return XCTFail("expected symlinkComponent, got \(decision)")
        }
    }

    func testExternalRootIdentityMismatchIsDenied() throws {
        let home = try TemporaryHome()
        let clone = try home.write("X/com.example.App.code_sign_clone/payload.bin", contents: "hi")

        let decision = SweepPolicy.authorize(
            externalRoot: home.url("X"),
            resolvedPath: clone,
            identity: PathIdentity(deviceID: 999_999, inode: 999_999),
            home: home.root
        )

        guard case .denied(.identityMismatch) = decision else {
            return XCTFail("expected identityMismatch, got \(decision)")
        }
    }

    func testExternalRootProtectedAreaIsStillDenied() throws {
        let home = try TemporaryHome()
        let hidden = try home.makeDirectory("X/docs")
        let file = hidden.appending(path: "taxes.pdf")
        try Data("private".utf8).write(to: file)
        try FileManager.default.createSymbolicLink(at: home.url("Documents"), withDestinationURL: hidden)

        let identity = try XCTUnwrap(PathIdentity.read(at: file))
        let decision = SweepPolicy.authorize(
            externalRoot: home.url("X"),
            resolvedPath: file,
            identity: identity,
            home: home.root
        )

        guard case .denied(.protectedArea(.documents, _)) = decision else {
            return XCTFail("expected protectedArea(.documents), got \(decision)")
        }
    }

    func testExternalRootThatDoesNotResolveIsDenied() throws {
        let home = try TemporaryHome()   // no X directory created
        let decision = SweepPolicy.authorize(
            externalRoot: home.url("X"),
            resolvedPath: home.url("X/anything"),
            identity: PathIdentity(deviceID: 1, inode: 1),
            home: home.root
        )

        guard case .denied(.malformedPath) = decision else {
            return XCTFail("expected malformedPath, got \(decision)")
        }
    }

    func testEveryOperationRootHasCandidateLocations() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        for root in SweepPolicy.OperationRoot.allCases {
            XCTAssertFalse(
                SweepPolicy.candidateRootURLs(for: root, home: home).isEmpty,
                "\(root) resolves to nothing, so it can never be authorized"
            )
        }
    }
}

/// Disposable home directory, so root resolution is exercised without touching the real one.
final class TemporaryHome {
    let root: URL

    init() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "SweepPolicyTests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
    func write(_ relative: String, contents: String) throws -> URL {
        let target = url(relative)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(contents.utf8).write(to: target)
        return target
    }
}

extension PolicyTests {
    /// P4-B finding: developer-group rules pattern from home, so `home` must resolve as a
    /// `developerToolCaches` candidate root — and widening to home must NOT weaken the
    /// protected-area denylist for operations under that root.
    func testDeveloperToolCachesResolvesHomeButProtectedAreasStayDenied() throws {
        let home = try TemporaryHome()
        let npmCache = try home.write(".npm/_cacache/content-v2/blob", contents: "cache")
        let identity = try XCTUnwrap(PathIdentity.read(at: npmCache))

        let decision = SweepPolicy.authorize(
            root: .developerToolCaches, resolvedPath: npmCache, identity: identity, home: home.root
        )
        XCTAssertNotNil(decision.authorization, "home-relative tool cache must authorize, got \(decision)")

        let doc = try home.write("Documents/notes.txt", contents: "mine")
        let docIdentity = try XCTUnwrap(PathIdentity.read(at: doc))
        let docDecision = SweepPolicy.authorize(
            root: .developerToolCaches, resolvedPath: doc, identity: docIdentity, home: home.root
        )
        guard case .denied(.protectedArea) = docDecision else {
            return XCTFail("Documents must stay denied even under the home-resolved root, got \(docDecision)")
        }
    }
}
