import XCTest
@testable import SweepCore

final class ScanEngineTests: XCTestCase {

    func testWalksGeneratedTreeWithCorrectCounts() async throws {
        let tree = try TempTree("scan-counts")
        try tree.write("f1.bin", bytes: 4096)
        try tree.write("f2.bin", bytes: 8192)
        try tree.makeDirectory("nested")
        try tree.write("nested/f3.bin", bytes: 100)
        try tree.makeDirectory("nested/deeper")
        try tree.write("nested/deeper/f4.bin", bytes: 0)

        let engine = ScanEngine()
        let result = try await engine.run(ScanRequest(roots: [tree.root]))

        XCTAssertEqual(result.totals.fileCount, 4)
        XCTAssertEqual(result.totals.directoryCount, 2)
        XCTAssertEqual(result.candidates.count, 6)
        XCTAssertFalse(result.summary.cancelled)
        XCTAssertEqual(result.summary.issues.count, 0)
    }

    func testByteAccountingCoversEveryFileOnDisk() async throws {
        let tree = try TempTree("scan-bytes")
        let logicalSizes = [4096, 8192, 100]
        try tree.write("a.bin", bytes: logicalSizes[0])
        try tree.write("b.bin", bytes: logicalSizes[1])
        try tree.write("nested/c.bin", bytes: logicalSizes[2])

        let engine = ScanEngine()
        let result = try await engine.run(ScanRequest(roots: [tree.root]))

        // Allocated size is block-rounded, so the floor is the logical sum and every file must
        // account for at least its own bytes.
        let logicalTotal = Int64(logicalSizes.reduce(0, +))
        XCTAssertGreaterThanOrEqual(result.allocatedBytes, logicalTotal)

        let files = result.candidates.filter { $0.identity.kind == .file }
        XCTAssertEqual(files.count, 3)
        let summed = files.reduce(Int64(0)) { $0 + $1.allocatedSize }
        XCTAssertEqual(result.allocatedBytes, summed, "no hard links here, so per-file sizes must sum to the total")

        for candidate in files {
            XCTAssertGreaterThan(candidate.allocatedSize, 0, "\(candidate.url.lastPathComponent) reported 0 bytes")
        }
    }

    func testHardLinkedInodeIsCountedOnce() async throws {
        let single = try TempTree("scan-single")
        try single.write("payload.bin", bytes: 16384)
        let engine = ScanEngine()
        let baseline = try await engine.run(ScanRequest(roots: [single.root]))

        let linked = try TempTree("scan-linked")
        try linked.write("payload.bin", bytes: 16384)
        try linked.hardLink(from: "payload.bin", to: "nested/same-inode.bin")
        let withLink = try await engine.run(ScanRequest(roots: [linked.root]))

        XCTAssertEqual(withLink.totals.fileCount, 2, "both paths are seen")
        XCTAssertEqual(withLink.totals.duplicateInodeCount, 1)
        XCTAssertEqual(
            withLink.allocatedBytes,
            baseline.allocatedBytes,
            "a hard link adds a path, not bytes"
        )

        let hardLinked = withLink.candidates.filter { $0.identity.isHardLinked }
        XCTAssertEqual(hardLinked.count, 2)
        XCTAssertEqual(Set(hardLinked.map(\.identity.inode)).count, 1)
    }

    func testCandidatesCarryFullIdentity() async throws {
        let tree = try TempTree("scan-identity")
        try tree.makeDirectory("parent")
        let file = try tree.write("parent/child.bin", bytes: 2048)

        let engine = ScanEngine()
        let result = try await engine.run(ScanRequest(roots: [tree.root]))

        let child = try XCTUnwrap(result.candidates.first { $0.url.lastPathComponent == "child.bin" })
        let parent = try XCTUnwrap(result.candidates.first { $0.url.lastPathComponent == "parent" })
        let expected = try FileIdentity.read(at: file)

        XCTAssertEqual(child.identity.inode, expected.inode)
        XCTAssertEqual(child.identity.deviceID, expected.deviceID)
        XCTAssertEqual(child.identity.kind, .file)
        XCTAssertEqual(child.identity.linkCount, 1)
        XCTAssertEqual(child.identity.modification, expected.modification)
        XCTAssertEqual(child.parentIdentity?.inode, parent.identity.inode, "parent identity is recorded")
        XCTAssertEqual(child.identity.volume.deviceID, parent.identity.volume.deviceID)
    }

    func testEveryCandidateStaysOnTheRootVolume() async throws {
        let tree = try TempTree("scan-volume")
        try tree.write("a/b/c.bin", bytes: 64)

        let volume = try VolumeIdentity.read(at: tree.root)
        let engine = ScanEngine()
        let result = try await engine.run(ScanRequest(roots: [tree.root]))

        XCTAssertFalse(result.candidates.isEmpty)
        for candidate in result.candidates {
            XCTAssertTrue(
                candidate.identity.volume.isSameVolume(as: volume),
                "walk crossed a volume boundary at \(candidate.url.path)"
            )
            XCTAssertEqual(candidate.identity.deviceID, volume.deviceID)
        }
    }

    func testSymlinkIsRecordedButNotFollowed() async throws {
        let tree = try TempTree("scan-symlink")
        try tree.makeDirectory("real")
        try tree.write("real/inside.bin", bytes: 32)
        try FileManager.default.createSymbolicLink(at: tree.url("link"), withDestinationURL: tree.url("real"))

        let engine = ScanEngine()
        let result = try await engine.run(ScanRequest(roots: [tree.root]))

        let link = try XCTUnwrap(result.candidates.first { $0.url.lastPathComponent == "link" })
        XCTAssertEqual(link.identity.kind, .symbolicLink)
        XCTAssertEqual(
            result.candidates.filter { $0.url.lastPathComponent == "inside.bin" }.count,
            1,
            "the symlinked directory must not be descended a second time"
        )
    }

    func testDirectoriesCanBeExcluded() async throws {
        let tree = try TempTree("scan-files-only")
        try tree.write("nested/a.bin", bytes: 10)
        try tree.write("nested/b.bin", bytes: 10)

        let engine = ScanEngine()
        let result = try await engine.run(ScanRequest(roots: [tree.root], includesDirectories: false))

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertTrue(result.candidates.allSatisfy { $0.identity.kind == .file })
        XCTAssertEqual(result.totals.directoryCount, 0)
    }

    func testMaximumDepthBoundsTheWalk() async throws {
        let tree = try TempTree("scan-depth")
        try tree.write("top.bin", bytes: 10)
        try tree.write("a/mid.bin", bytes: 10)
        try tree.write("a/b/deep.bin", bytes: 10)

        let engine = ScanEngine()
        let result = try await engine.run(ScanRequest(roots: [tree.root], maximumDepth: 1))

        let names = Set(result.candidates.map(\.url.lastPathComponent))
        XCTAssertEqual(names, ["top.bin", "a"])
    }

    func testMinimumAgeFiltersFreshItems() async throws {
        let tree = try TempTree("scan-age")
        try tree.write("fresh.bin", bytes: 10)

        let engine = ScanEngine()
        let result = try await engine.run(ScanRequest(roots: [tree.root], minimumAge: 3600))

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.totals.fileCount, 0)
    }

    func testProgressIsStreamedAndFinishes() async throws {
        let tree = try TempTree("scan-progress")
        for index in 0..<120 {
            try tree.write("f\(index).bin", bytes: 16)
        }

        var progressEvents = 0
        var candidates = 0
        var started = 0
        var finished: ScanSummary?

        let engine = ScanEngine()
        for try await event in await engine.scan(ScanRequest(roots: [tree.root], progressInterval: 25)) {
            switch event {
            case .started: started += 1
            case .candidate: candidates += 1
            case .progress: progressEvents += 1
            case .finished(let summary): finished = summary
            }
        }

        XCTAssertEqual(started, 1)
        XCTAssertEqual(candidates, 120)
        XCTAssertGreaterThanOrEqual(progressEvents, 4)
        XCTAssertEqual(finished?.totals.fileCount, 120)

        // Bookkeeping is released from the stream's termination handler, which hops back onto
        // the actor, so the release is eventual rather than immediate.
        var remaining = await engine.activeScanCount
        for _ in 0..<100 where remaining != 0 {
            try await Task.sleep(for: .milliseconds(10))
            remaining = await engine.activeScanCount
        }
        XCTAssertEqual(remaining, 0, "the engine forgets a scan once its stream terminates")
    }

    func testAbandoningTheStreamStopsTheWalk() async throws {
        let tree = try TempTree("scan-cancel")
        for index in 0..<400 {
            try tree.write("f\(index).bin", bytes: 16)
        }

        let engine = ScanEngine()
        var seen = 0
        for try await event in await engine.scan(ScanRequest(roots: [tree.root])) {
            if case .candidate = event {
                seen += 1
                if seen == 3 { break }
            }
        }
        XCTAssertEqual(seen, 3)
    }

    func testMissingRootFailsTheStream() async throws {
        let engine = ScanEngine()
        let missing = FileManager.default.temporaryDirectory.appending(path: "sweep-missing-\(UUID())")
        do {
            _ = try await engine.run(ScanRequest(roots: [missing]))
            XCTFail("expected a scan failure for a missing root")
        } catch let error as ScanError {
            guard case .rootUnavailable = error else { return XCTFail("unexpected \(error)") }
        }
    }

    func testEmptyRequestIsRejected() async throws {
        let engine = ScanEngine()
        do {
            _ = try await engine.run(ScanRequest(roots: []))
            XCTFail("expected noRoots")
        } catch let error as ScanError {
            guard case .noRoots = error else { return XCTFail("unexpected \(error)") }
        }
    }
}
