import XCTest
@testable import SweepPolicy

/// PLAN §2 "closed enum ops ONLY": the wire format's whole security value is that a peer cannot
/// smuggle anything through it except one of three well-shaped operations. These tests exercise
/// that boundary directly, at the `Codable` layer, rather than trusting it by inspection.
final class MaintenanceOperationCodableTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - Round trips

    func testFlushDNSRoundTrips() throws {
        let data = try encoder.encode(MaintenanceOperation.flushDNS)
        XCTAssertEqual(try decoder.decode(MaintenanceOperation.self, from: data), .flushDNS)
    }

    func testReindexSpotlightRoundTrips() throws {
        let operation = MaintenanceOperation.reindexSpotlight(volume: "/Volumes/Data")
        let data = try encoder.encode(operation)
        XCTAssertEqual(try decoder.decode(MaintenanceOperation.self, from: data), operation)
    }

    func testThinSnapshotsRoundTrips() throws {
        let operation = MaintenanceOperation.thinSnapshots(urgency: 4)
        let data = try encoder.encode(operation)
        XCTAssertEqual(try decoder.decode(MaintenanceOperation.self, from: data), operation)
    }

    // MARK: - Closed-enum strictness: anything else fails to decode

    func testUnknownOperationKindFailsToDecode() {
        let json = Data(#"{"kind": "deleteEverything"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(MaintenanceOperation.self, from: json))
    }

    func testMissingKindFieldFailsToDecode() {
        let json = Data(#"{"volume": "/"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(MaintenanceOperation.self, from: json))
    }

    func testReindexSpotlightMissingVolumeFieldFailsToDecode() {
        // The exact shape PLAN forbids: a case that decodes its discriminator but not the payload
        // must still fail closed, not fall back to an empty/default volume.
        let json = Data(#"{"kind": "reindexSpotlight"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(MaintenanceOperation.self, from: json))
    }

    func testThinSnapshotsNonIntegerUrgencyFailsToDecode() {
        let json = Data(#"{"kind": "thinSnapshots", "urgency": "four"}"#.utf8)
        XCTAssertThrowsError(try decoder.decode(MaintenanceOperation.self, from: json))
    }

    func testEmptyPayloadFailsToDecode() {
        XCTAssertThrowsError(try decoder.decode(MaintenanceOperation.self, from: Data("{}".utf8)))
    }

    // MARK: - MaintenanceOutcome round trips (the reply side)

    func testSucceededOutcomeRoundTrips() throws {
        let outcome = MaintenanceOutcome.succeeded(detail: "did the thing")
        let data = try encoder.encode(outcome)
        XCTAssertEqual(try decoder.decode(MaintenanceOutcome.self, from: data), outcome)
    }

    func testFailedOutcomeRoundTrips() throws {
        let outcome = MaintenanceOutcome.failed(reason: "nope")
        let data = try encoder.encode(outcome)
        XCTAssertEqual(try decoder.decode(MaintenanceOutcome.self, from: data), outcome)
    }
}
