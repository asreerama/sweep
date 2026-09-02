import XCTest
import SweepUninstall
@testable import SweepApp

/// Diagnostic probe for the user-reported "Looking for leftovers… takes forever" stall — times
/// each stage of the real click path against this machine's real home. Skipped unless
/// `SWEEP_PERF_PROBE=1`, so CI and normal test runs never pay for (or flake on) a walk of the
/// live `~/Library`.
final class LeftoverPerfProbeTests: XCTestCase {
    func testTimeLeftoverPipelineStages() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SWEEP_PERF_PROBE"] == "1")

        func ms(_ start: Date) -> String { String(format: "%.0f ms", -start.timeIntervalSinceNow * 1000) }

        var t = Date()
        let apps = AppInventory.scan()
        print("PROBE inventory: \(ms(t)) (\(apps.count) apps)")

        t = Date()
        let index = LeftoverRootIndex()
        print("PROBE index build: \(ms(t))")

        guard let code = apps.first(where: { $0.bundleIdentifier == "com.microsoft.VSCode" }) ?? apps.first else {
            return XCTFail("no apps found")
        }

        t = Date()
        let receipts = await PrefetchedPkgutilReceipts.load()
        print("PROBE receipts prefetch: \(ms(t)) (\(receipts.packageIdentifiers().count) packages)")

        t = Date()
        let withIndex = LeftoverMatcher.candidates(for: code, receipts: receipts, installedApps: apps, index: index)
        print("PROBE candidates, prefetched receipts + index — the real click path now: \(ms(t)) (\(withIndex.count) candidates)")

        t = Date()
        _ = LeftoverMatcher.candidates(for: code, installedApps: apps, index: index)
        print("PROBE candidates with LIVE pkgutil per package (the old click path): \(ms(t))")

        t = Date()
        var sized: Int64 = 0
        for candidate in withIndex { sized += FileSizeCalculator.allocatedSize(at: candidate.url) }
        print("PROBE serial sizing of \(withIndex.count) candidates: \(ms(t)) (\(sized / 1_000_000) MB)")
    }
}
