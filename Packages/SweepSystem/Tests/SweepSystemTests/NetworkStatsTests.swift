import XCTest
@testable import SweepSystem

final class NetworkStatsTests: XCTestCase {
    // MARK: - Pure math with mocked counters (deterministic, fixed inputs)

    func testDeltaNormalIncreasingCounters() {
        XCTAssertEqual(NetworkByteCounter.delta(current: 2_000, previous: 1_000), 1_000)
    }

    func testDeltaZeroWhenUnchanged() {
        XCTAssertEqual(NetworkByteCounter.delta(current: 5_000, previous: 5_000), 0)
    }

    /// Simulates the documented "4 GB counter wrap" (PLAN.md Appendix B): the counter was near
    /// `UInt32.max`, wrapped past zero, and kept counting.
    func testDeltaAcrossFourGigabyteWrap() {
        let wrapBoundary = NetworkByteCounter.wrapBoundary // 4_294_967_296
        let previous = wrapBoundary - 100 // 100 bytes from wrapping
        let current: UInt64 = 50 // wrapped, 50 bytes past zero
        let delta = NetworkByteCounter.delta(current: current, previous: previous)

        XCTAssertEqual(delta, 150)
        XCTAssertGreaterThanOrEqual(delta, 0) // UInt64 is always >= 0, but assert the intent explicitly
    }

    func testDeltaExactlyAtWrapBoundary() {
        let wrapBoundary = NetworkByteCounter.wrapBoundary
        let delta = NetworkByteCounter.delta(current: 0, previous: wrapBoundary - 1)
        XCTAssertEqual(delta, 1)
    }

    /// A counter that goes backward far from the wrap boundary is treated as a reset (interface
    /// re-associated), not a bogus near-4GB spike.
    func testDeltaTreatsFarBackwardsJumpAsResetNotWrap() {
        let delta = NetworkByteCounter.delta(current: 200, previous: 100_000)
        XCTAssertEqual(delta, 200, "should report the new counter value, not (2^32 - 100_000 + 200)")
    }

    func testDeltasAreNeverNegativeAcrossManySimulatedWraps() {
        // A UInt64 return type makes negative results structurally impossible, but walk a
        // sequence of samples that wraps multiple times to make sure the arithmetic itself never
        // traps (wrapping subtraction) and always yields a plausible small delta.
        let wrapBoundary = NetworkByteCounter.wrapBoundary
        var previous: UInt64 = wrapBoundary - 300
        let steps: [UInt64] = [wrapBoundary - 200, wrapBoundary - 50, 50, 200, 400] // wraps once in here
        for current in steps {
            let delta = NetworkByteCounter.delta(current: current, previous: previous)
            XCTAssertLessThan(delta, wrapBoundary, "a single-interval delta should never span a full counter range")
            previous = current
        }
    }

    // MARK: - Sampler behavior

    func testSamplerFirstCallHasZeroDeltasSecondCallIsNonNegative() {
        var sampler = NetworkStatsSampler()
        let first = sampler.sample()
        for interfaceStat in first.interfaces {
            XCTAssertEqual(interfaceStat.bytesReceivedDelta, 0)
            XCTAssertEqual(interfaceStat.bytesSentDelta, 0)
        }

        let second = sampler.sample()
        let sumReceived = second.interfaces.reduce(UInt64(0)) { $0 + $1.bytesReceivedDelta }
        let sumSent = second.interfaces.reduce(UInt64(0)) { $0 + $1.bytesSentDelta }
        XCTAssertEqual(sumReceived, second.totalBytesReceivedDelta)
        XCTAssertEqual(sumSent, second.totalBytesSentDelta)
    }

    func testSamplerOnlyIncludesConfiguredPrefix() {
        var sampler = NetworkStatsSampler(interfacePrefix: "en")
        _ = sampler.sample()
        let stats = sampler.sample()
        for interfaceStat in stats.interfaces {
            XCTAssertTrue(interfaceStat.name.hasPrefix("en"), "\(interfaceStat.name) should have been filtered out")
        }
    }
}
