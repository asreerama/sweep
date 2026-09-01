import XCTest
@testable import SweepSystem

final class BatteryStatsTests: XCTestCase {
    func testPercentageMath() {
        XCTAssertEqual(BatteryStatsReader.percentage(current: 50, max: 100), 50)
        XCTAssertEqual(BatteryStatsReader.percentage(current: 100, max: 100), 100)
        XCTAssertEqual(BatteryStatsReader.percentage(current: 0, max: 100), 0)
    }

    func testPercentageClampsAndHandlesMissingData() {
        XCTAssertEqual(BatteryStatsReader.percentage(current: nil, max: 100), 0)
        XCTAssertEqual(BatteryStatsReader.percentage(current: 50, max: nil), 0)
        XCTAssertEqual(BatteryStatsReader.percentage(current: 50, max: 0), 0)
        XCTAssertEqual(BatteryStatsReader.percentage(current: 999, max: 100), 100, "should clamp, never report over 100%")
    }

    /// This package was built and tested on a Mac mini, a desktop with no battery — the correct
    /// result there is `nil`, not an error. On hardware with a battery, the reader must instead
    /// return sane, bounded values. Both outcomes are accepted; only a crash or a
    /// nonsense/out-of-range value fails this test.
    func testReadIsSaneWhetherOrNotABatteryIsPresent() {
        if let battery = BatteryStatsReader.read() {
            XCTAssertTrue((0...100).contains(battery.percentage))
            XCTAssertTrue(battery.isPresent)
            if let timeToEmpty = battery.timeToEmptyMinutes {
                XCTAssertGreaterThanOrEqual(timeToEmpty, 0)
            }
            if let timeToFull = battery.timeToFullChargeMinutes {
                XCTAssertGreaterThanOrEqual(timeToFull, 0)
            }
        }
        // else: no power source on this machine — a legitimate, expected result on a desktop Mac.
    }
}
