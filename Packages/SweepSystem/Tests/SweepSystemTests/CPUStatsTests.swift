import Foundation
import XCTest
@testable import SweepSystem

final class CPUStatsTests: XCTestCase {
    // MARK: - Pure math (deterministic, fixed inputs)

    func testWrappingDeltaNormalCase() {
        XCTAssertEqual(CPUMath.wrappingDelta(current: 150, previous: 100), 50)
    }

    func testWrappingDeltaAcrossUInt32Wrap() {
        // previous is 100 ticks before UInt32.max; current wrapped around to 49.
        let previous = UInt32.max - 100
        let current: UInt32 = 49
        XCTAssertEqual(CPUMath.wrappingDelta(current: current, previous: previous), 150)
    }

    func testPercentagesFixedInputsSumToOneHundred() throws {
        let previous = CPUTicks(user: 100, system: 50, idle: 850, nice: 0)
        let current = CPUTicks(user: 150, system: 70, idle: 980, nice: 0)
        // deltas: user 50, system 20, idle 130 -> total 200
        let pct = try XCTUnwrap(CPUMath.percentages(previous: previous, current: current))

        XCTAssertEqual(pct.user, 25.0, accuracy: 0.0001)
        XCTAssertEqual(pct.system, 10.0, accuracy: 0.0001)
        XCTAssertEqual(pct.idle, 65.0, accuracy: 0.0001)
        XCTAssertEqual(pct.user + pct.system + pct.idle, 100.0, accuracy: 0.0001)
    }

    func testPercentagesNilWhenNoElapsedTicks() {
        let ticks = CPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        XCTAssertNil(CPUMath.percentages(previous: ticks, current: ticks))
    }

    func testPercentagesHandlesWraparoundWithoutNegativeResult() throws {
        let previous = CPUTicks(user: UInt32.max - 10, system: 0, idle: 0, nice: 0)
        let current = CPUTicks(user: 39, system: 0, idle: 0, nice: 0) // wrapped: delta = 50
        let pct = try XCTUnwrap(CPUMath.percentages(previous: previous, current: current))
        XCTAssertEqual(pct.user, 100.0, accuracy: 0.0001)
    }

    // MARK: - Live sampling on this machine

    func testSamplerFirstCallIsUnavailableSecondCallIsSane() async throws {
        var sampler = CPUStatsSampler()
        let first = sampler.sample()
        XCTAssertEqual(first, .unavailable, "no prior sample exists yet on the first call")

        // Force some elapsed ticks between samples.
        try await Task.sleep(for: .milliseconds(200))
        let second = sampler.sample()

        XCTAssertFalse(second.perCore.isEmpty, "this machine has at least one core")
        XCTAssertEqual(second.perCore.count, ProcessInfo.processInfo.activeProcessorCount)

        for core in second.perCore {
            for value in [core.userPercent, core.systemPercent, core.idlePercent] {
                XCTAssertTrue((0...100).contains(value), "\(value) out of range")
            }
        }
        for value in [second.aggregateUserPercent, second.aggregateSystemPercent, second.aggregateIdlePercent] {
            XCTAssertTrue((0...100).contains(value), "\(value) out of range")
        }
    }
}
