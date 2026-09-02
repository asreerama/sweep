import Foundation
import XCTest
@testable import SweepCore

/// Wall-clock comparison of the two walk backends over a real tree.
///
/// Env-gated because it walks the user's actual `~/Library/Caches`: it is a measurement, not an
/// assertion, and it has no business running in a normal test pass or in CI. Run it with
/// `SWEEP_BENCH=1 swift test --filter BulkVolumeWalkerBenchTests`.
final class BulkVolumeWalkerBenchTests: XCTestCase {

    func testWalkThroughputAgainstUserLibraryCaches() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["SWEEP_BENCH"] == "1",
            "set SWEEP_BENCH=1 to run the walk benchmark"
        )

        let root = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Caches")
        let boundary = try VolumeIdentity.read(at: root)

        // One untimed pass first, so neither backend is charged for warming the directory cache.
        _ = try? BulkVolumeWalker().walk(root: root, options: WalkOptions(boundary: boundary)) { _ in .continue }

        var report = "\nwalk benchmark — \(root.path)\n"
        for honorsDenylist in [true, false] {
            // Measured both ways because `SweepPolicy.isDeniedLexically` runs once per entry in
            // *both* backends and is not cheap, so leaving it on hides how much of the walk cost
            // is actually enumeration.
            let options = WalkOptions(boundary: boundary, honorsPolicyDenylist: honorsDenylist)
            let bulk = try measure(BulkVolumeWalker(), root: root, options: options)
            let reference = try measure(FileManagerVolumeWalker(), root: root, options: options)
            report += """

              denylist \(honorsDenylist ? "on " : "off")
                BulkVolumeWalker         \(bulk.entries) entries, \(bulk.issues) issues, \
            \(String(format: "%.3f", bulk.seconds))s
                FileManagerVolumeWalker  \(reference.entries) entries, \(reference.issues) issues, \
            \(String(format: "%.3f", reference.seconds))s
                speedup                  \(String(format: "%.2f", reference.seconds / bulk.seconds))x

            """
            XCTAssertGreaterThan(bulk.entries, 0, "nothing to measure")
            XCTAssertEqual(bulk.entries, reference.entries, "the two backends disagree on a real tree")
        }
        print(report)
    }

    private func measure(
        _ walker: some VolumeWalker,
        root: URL,
        options: WalkOptions
    ) throws -> (entries: Int, issues: Int, seconds: Double) {
        var entries = 0
        let start = DispatchTime.now().uptimeNanoseconds
        // Permission failures are expected under `~/Library/Caches` and are exactly what both
        // backends are supposed to absorb, so they are counted rather than treated as a problem.
        let summary = try walker.walk(root: root, options: options) { _ in
            entries += 1
            return .continue
        }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000_000
        return (entries, summary.issues.count, elapsed)
    }
}
