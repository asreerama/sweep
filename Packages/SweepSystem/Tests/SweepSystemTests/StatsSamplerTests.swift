import Darwin
import XCTest
@testable import SweepSystem

final class StatsSamplerTests: XCTestCase {
    func testSampleOnceReturnsSaneSnapshot() async {
        let sampler = StatsSampler()
        _ = await sampler.sampleOnce() // establishes CPU/network baselines
        let snapshot = await sampler.sampleOnce()

        XCTAssertGreaterThan(snapshot.memory.totalBytes, 0)
        XCTAssertFalse(snapshot.disks.isEmpty)
        XCTAssertFalse(snapshot.topProcesses.isEmpty)
        XCTAssertTrue(MemoryPressureLevel.allCases.contains(snapshot.memoryPressure))
        for value in [snapshot.cpu.aggregateUserPercent, snapshot.cpu.aggregateSystemPercent, snapshot.cpu.aggregateIdlePercent] {
            XCTAssertTrue((0...100).contains(value))
        }
    }

    func testSnapshotsStreamYieldsMultipleSamplesOnConfiguredInterval() async {
        let sampler = StatsSampler(configuration: .init(interval: .milliseconds(30), topProcessCount: 3))

        // Scoped so `stream` (and the internal producer Task it owns) is released, and
        // `onTermination` cancels sampling, as soon as this closure returns — well before the
        // test method itself exits.
        let count: Int = await {
            let stream = await sampler.snapshots()
            var count = 0
            for await snapshot in stream {
                XCTAssertLessThanOrEqual(snapshot.topProcesses.count, 3)
                count += 1
                if count >= 3 { break }
            }
            return count
        }()

        XCTAssertGreaterThanOrEqual(count, 3)
    }

    /// Measures the real cost of one `sampleOnce()` call on this machine: wall time, and process
    /// CPU-seconds consumed (via `getrusage`), projected to a CPU percentage at the module's
    /// default 2-second sampling interval. Generous thresholds — this guards against gross
    /// regressions (e.g. an accidental O(n²) loop), not exact budget enforcement, since absolute
    /// CPU time is inherently noisy on a shared dev machine.
    func testMeasuredSampleCost() async throws {
        let sampler = StatsSampler(configuration: .init(interval: .seconds(2), topProcessCount: 5))
        _ = await sampler.sampleOnce() // warm up CPU/network baselines before timing

        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        let wallStart = ContinuousClock.now

        let iterations = 50
        for _ in 0..<iterations {
            _ = await sampler.sampleOnce()
        }

        let wallElapsed = ContinuousClock.now - wallStart
        var after = rusage()
        getrusage(RUSAGE_SELF, &after)

        let cpuSecondsBefore = Self.seconds(before.ru_utime) + Self.seconds(before.ru_stime)
        let cpuSecondsAfter = Self.seconds(after.ru_utime) + Self.seconds(after.ru_stime)
        let cpuSecondsTotal = max(0, cpuSecondsAfter - cpuSecondsBefore)

        let wallSecondsTotal = Double(wallElapsed.components.seconds)
            + Double(wallElapsed.components.attoseconds) / 1e18
        let wallSecondsPerSample = wallSecondsTotal / Double(iterations)
        let cpuSecondsPerSample = cpuSecondsTotal / Double(iterations)
        let projectedCPUPercentAt2sInterval = cpuSecondsPerSample / 2.0 * 100

        print(String(
            format: "[StatsSampler cost] %d samples: %.2f ms wall/sample, %.2f ms CPU/sample, projected %.3f%% CPU at a 2s interval",
            iterations, wallSecondsPerSample * 1000, cpuSecondsPerSample * 1000, projectedCPUPercentAt2sInterval
        ))

        XCTAssertLessThan(wallSecondsPerSample, 0.25, "one sample should complete in a small fraction of the 2s budget")
        XCTAssertLessThan(projectedCPUPercentAt2sInterval, 5.0, "should be far under budget even generously measured")
    }

    /// Isolates the one deliberately-amortized cost in the sampler: re-reading disk volume
    /// `URLResourceKey`s. On the machine this was built on, that costs far more than every other
    /// reader combined (~1.5-2 ms per mounted volume), which is why `Configuration.diskRefreshInterval`
    /// decouples it from the main sampling cadence. This test reports the two numbers a caller
    /// needs to compute the true steady-state average: the cheap per-tick cost, and the
    /// occasional refresh-tick cost.
    func testMeasuredDiskRefreshCostIsIsolatedFromSteadyStateCost() async {
        let sampler = StatsSampler(configuration: .init(diskRefreshInterval: .seconds(10)))

        var before = rusage()
        getrusage(RUSAGE_SELF, &before)
        _ = await sampler.sampleOnce() // first call always refreshes disk
        var after = rusage()
        getrusage(RUSAGE_SELF, &after)
        let firstCallCPUMs = (Self.seconds(after.ru_utime) + Self.seconds(after.ru_stime)
            - Self.seconds(before.ru_utime) - Self.seconds(before.ru_stime)) * 1000

        before = after
        _ = await sampler.sampleOnce() // cached: no disk refresh
        getrusage(RUSAGE_SELF, &after)
        let steadyStateCPUMs = (Self.seconds(after.ru_utime) + Self.seconds(after.ru_stime)
            - Self.seconds(before.ru_utime) - Self.seconds(before.ru_stime)) * 1000

        let ticksPerRefresh = 5.0 // diskRefreshInterval (10s) / interval (2s)
        let amortizedPerTickMs = steadyStateCPUMs + (max(0, firstCallCPUMs - steadyStateCPUMs) / ticksPerRefresh)
        let amortizedPercentAt2s = amortizedPerTickMs / 2000 * 100

        print(String(
            format: "[StatsSampler cost] disk-refresh tick: %.2f ms CPU, steady-state tick: %.2f ms CPU, amortized (1 refresh per %d ticks): %.2f ms/tick -> %.3f%% CPU at a 2s interval",
            firstCallCPUMs, steadyStateCPUMs, Int(ticksPerRefresh), amortizedPerTickMs, amortizedPercentAt2s
        ))

        XCTAssertLessThan(amortizedPercentAt2s, 0.5, "PLAN.md target: <0.5% CPU at a 2s interval")
    }

    private static func seconds(_ tv: timeval) -> Double {
        Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000
    }
}
