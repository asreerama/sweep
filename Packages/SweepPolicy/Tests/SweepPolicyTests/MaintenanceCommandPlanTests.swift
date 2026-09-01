import XCTest
@testable import SweepPolicy

final class MaintenanceCommandPlanTests: XCTestCase {
    func testFlushDNSExpandsToDscacheutilThenKillall() {
        let commands = MaintenanceCommandPlan.commands(for: .flushDNS)
        XCTAssertEqual(commands.map(\.commandLine), [
            "/usr/bin/dscacheutil -flushcache",
            "/usr/bin/killall -HUP mDNSResponder",
        ])
    }

    func testReindexSpotlightExpandsToMdutilWithTheGivenVolume() {
        let commands = MaintenanceCommandPlan.commands(for: .reindexSpotlight(volume: "/Volumes/Data"))
        XCTAssertEqual(commands.map(\.commandLine), ["/usr/bin/mdutil -E /Volumes/Data"])
    }

    func testThinSnapshotsExpandsToTmutilWithUrgency() {
        let commands = MaintenanceCommandPlan.commands(for: .thinSnapshots(urgency: 2))
        XCTAssertEqual(commands.map(\.commandLine), ["/usr/bin/tmutil thinlocalsnapshots / 500000000000 2"])
    }

    func testPreviewTextIsExactlyTheJoinedCommandLines() {
        let operation = MaintenanceOperation.flushDNS
        XCTAssertEqual(
            MaintenanceCommandPlan.previewText(for: operation),
            MaintenanceCommandPlan.commands(for: operation).map(\.commandLine).joined(separator: "\n")
        )
    }

    /// The app's user-level DNS-flush fallback and the helper's full `flushDNS` must read the
    /// exact same first command — no index coupling, no drift.
    func testUserLevelDNSFlushCommandIsFlushDNSsFirstCommand() {
        XCTAssertEqual(MaintenanceCommandPlan.commands(for: .flushDNS).first, MaintenanceCommandPlan.userLevelDNSFlushCommand)
    }

    func testEveryExecutablePathIsAbsolute() {
        for operation in [MaintenanceOperation.flushDNS, .reindexSpotlight(volume: "/"), .thinSnapshots(urgency: 1)] {
            for command in MaintenanceCommandPlan.commands(for: operation) {
                XCTAssertTrue(command.executablePath.hasPrefix("/"), "\(command.executablePath) must be an absolute path")
            }
        }
    }
}
