import XCTest
@testable import SweepSystem

/// Regression coverage for finding #15 in the adversarial review: Mach out-array element counts
/// must be validated before the buffer they describe is rebound to typed records and indexed, or
/// read field-by-field. These test the pure validation helpers directly with fixed, deliberately
/// bad counts — no live `host_processor_info`/`host_statistics64` call needed.
final class MachBufferValidationTests: XCTestCase {
    // MARK: - exactCountMatches (CPUStats' processor-load-info usage)

    func testExactCountMatchesValidCase() {
        XCTAssertTrue(MachBufferValidation.exactCountMatches(reported: 12, elementCount: 4, perElementCount: 3))
    }

    func testExactCountMatchesRejectsShortResponse() {
        // The kernel claims fewer integer_t elements than processorCount * PROCESSOR_CPU_LOAD_INFO_COUNT
        // would require — must never be treated as valid, or CPUStats would index past the
        // actual out-of-line allocation.
        XCTAssertFalse(MachBufferValidation.exactCountMatches(reported: 11, elementCount: 4, perElementCount: 3))
    }

    func testExactCountMatchesRejectsOverlongResponse() {
        XCTAssertFalse(MachBufferValidation.exactCountMatches(reported: 13, elementCount: 4, perElementCount: 3))
    }

    func testExactCountMatchesRejectsZeroReportedAgainstNonZeroExpectation() {
        XCTAssertFalse(MachBufferValidation.exactCountMatches(reported: 0, elementCount: 4, perElementCount: 3))
    }

    func testExactCountMatchesAcceptsZeroElementsWithZeroReported() {
        XCTAssertTrue(MachBufferValidation.exactCountMatches(reported: 0, elementCount: 0, perElementCount: 3))
    }

    func testExactCountMatchesRejectsOverflowingMultiplication() {
        XCTAssertFalse(MachBufferValidation.exactCountMatches(reported: 0, elementCount: Int.max, perElementCount: 3))
    }

    func testExactCountMatchesRejectsNegativeElementCount() {
        XCTAssertFalse(MachBufferValidation.exactCountMatches(reported: 0, elementCount: -1, perElementCount: 3))
    }

    func testExactCountMatchesRejectsNegativePerElementCount() {
        XCTAssertFalse(MachBufferValidation.exactCountMatches(reported: 0, elementCount: 4, perElementCount: -3))
    }

    // MARK: - atLeast (MemoryStats' host_statistics64 usage)

    func testAtLeastAcceptsExactMatch() {
        XCTAssertTrue(MachBufferValidation.atLeast(reported: 10, needed: 10))
    }

    func testAtLeastAcceptsGreaterThanNeeded() {
        XCTAssertTrue(MachBufferValidation.atLeast(reported: 11, needed: 10))
    }

    func testAtLeastRejectsShortResponse() {
        // A short `host_statistics64` response must never be trusted — trailing fields of the
        // decoded struct would silently retain whatever was there before the call.
        XCTAssertFalse(MachBufferValidation.atLeast(reported: 9, needed: 10))
    }

    func testAtLeastRejectsNegativeNeeded() {
        XCTAssertFalse(MachBufferValidation.atLeast(reported: 10, needed: -1))
    }
}
