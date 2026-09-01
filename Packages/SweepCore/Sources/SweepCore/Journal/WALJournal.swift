import Darwin
import Foundation

public enum JournalError: Error, CustomStringConvertible {
    case cannotCreate(url: URL, reason: String)
    case writeFailed(reason: String)
    case syncFailed(reason: String)
    case corruptRecord(line: Int, reason: String)
    case unsupportedRecordVersion(line: Int, version: Int)
    case closed

    public var description: String {
        switch self {
        case .cannotCreate(let url, let reason): "cannot open journal at \(url.path): \(reason)"
        case .writeFailed(let reason): "journal write failed: \(reason)"
        case .syncFailed(let reason): "journal fsync failed: \(reason)"
        case .corruptRecord(let line, let reason): "corrupt journal record at line \(line): \(reason)"
        case .unsupportedRecordVersion(let line, let version):
            "journal line \(line) has record version \(version); this build reads \(JournalRecord.currentVersion)"
        case .closed: "journal is closed"
        }
    }
}

/// Versioned write-ahead log, one JSON object per line.
///
/// Order is the contract: `planned` is durable before the first byte of the filesystem is
/// touched, every item result is durable before the next item starts, and `committed` closes
/// the operation. A write that cannot be made durable aborts the operation, because an
/// unlogged deletion is an unrecoverable one.
public actor WALJournal {
    public let url: URL

    private var handle: FileHandle?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Operations found uncommitted by the recovery scan at init.
    public private(set) var interrupted: [InterruptedOperation]
    /// True when the last line of the log was a torn write (a crash mid-append). Tolerated:
    /// the record it would have become never took effect.
    public private(set) var recoveredTornTail: Bool

    public init(url: URL) throws {
        self.url = url
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.interrupted = []
        self.recoveredTornTail = false

        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw JournalError.cannotCreate(url: url, reason: error.localizedDescription)
        }
        if !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: Data()) else {
                throw JournalError.cannotCreate(url: url, reason: "createFile refused")
            }
        }

        // Recovery scan before the first append, so an interrupted operation is known before
        // anything new is planned.
        let scan = try Self.replay(url: url, decoder: decoder)
        self.interrupted = scan.interrupted
        self.recoveredTornTail = scan.tornTail

        do {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            self.handle = handle
        } catch {
            throw JournalError.cannotCreate(url: url, reason: error.localizedDescription)
        }
    }

    deinit {
        try? handle?.close()
    }

    public func close() {
        try? handle?.close()
        handle = nil
    }

    // MARK: - Appends

    public func appendPlanned(operationID: UUID, planVersion: Int, items: [JournalItem]) throws {
        try append(JournalRecord(
            kind: .planned,
            operationID: operationID,
            planVersion: planVersion,
            items: items
        ))
    }

    public func appendStarted(operationID: UUID) throws {
        try append(JournalRecord(kind: .started, operationID: operationID))
    }

    public func appendItemResult(
        operationID: UUID,
        item: JournalItem,
        outcome: ItemOutcome,
        failureReason: ItemFailureReason? = nil,
        trashURL: URL? = nil,
        detail: String? = nil
    ) throws {
        try append(JournalRecord(
            kind: .itemResult,
            operationID: operationID,
            item: item,
            outcome: outcome,
            failureReason: failureReason,
            trashURL: trashURL,
            detail: detail
        ))
    }

    public func appendCommitted(operationID: UUID, detail: String? = nil) throws {
        try append(JournalRecord(kind: .committed, operationID: operationID, detail: detail))
    }

    /// Append + fsync. Any failure throws; callers abort rather than continue unlogged.
    func append(_ record: JournalRecord) throws {
        guard let handle else { throw JournalError.closed }
        var data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw JournalError.writeFailed(reason: "encode: \(error)")
        }
        data.append(0x0A)
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw JournalError.writeFailed(reason: error.localizedDescription)
        }
        // `synchronize()` is fsync(2): the log must survive a power loss, not merely a crash.
        do {
            try handle.synchronize()
        } catch {
            throw JournalError.syncFailed(reason: error.localizedDescription)
        }
    }

    // MARK: - Reading

    public func records() throws -> [JournalRecord] {
        try Self.replay(url: url, decoder: decoder).records
    }

    /// Re-run the recovery scan against the current file contents.
    @discardableResult
    public func recover() throws -> [InterruptedOperation] {
        let scan = try Self.replay(url: url, decoder: decoder)
        interrupted = scan.interrupted
        recoveredTornTail = scan.tornTail
        return scan.interrupted
    }

    public func state(of operationID: UUID) throws -> OperationState? {
        try Self.replay(url: url, decoder: decoder).states[operationID]
    }

    struct Replay: Sendable {
        var records: [JournalRecord] = []
        var interrupted: [InterruptedOperation] = []
        var states: [UUID: OperationState] = [:]
        var tornTail = false
    }

    /// Parses the log. A truncated final line is dropped (crash mid-append); corruption
    /// anywhere else is fatal, because a hole in the middle means records after it cannot be
    /// trusted to describe the same history.
    static func replay(url: URL, decoder: JSONDecoder) throws -> Replay {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw JournalError.cannotCreate(url: url, reason: error.localizedDescription)
        }

        var result = Replay()
        guard !data.isEmpty else { return result }

        let endsWithNewline = data.last == 0x0A
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
        var plannedItems: [UUID: [JournalItem]] = [:]
        var plannedVersion: [UUID: Int] = [:]
        var plannedAt: [UUID: Date] = [:]
        var outcomes: [UUID: [String: ItemOutcome]] = [:]

        for (index, line) in lines.enumerated() {
            let lineNumber = index + 1
            if line.isEmpty {
                let isFinal = index == lines.count - 1
                if isFinal { continue }
                throw JournalError.corruptRecord(line: lineNumber, reason: "empty line")
            }

            let record: JournalRecord
            do {
                record = try decoder.decode(JournalRecord.self, from: Data(line))
            } catch {
                let isFinal = index == lines.count - 1 && !endsWithNewline
                if isFinal {
                    result.tornTail = true
                    continue
                }
                throw JournalError.corruptRecord(line: lineNumber, reason: String(describing: error))
            }
            guard record.version == JournalRecord.currentVersion else {
                throw JournalError.unsupportedRecordVersion(line: lineNumber, version: record.version)
            }

            result.records.append(record)
            switch record.kind {
            case .planned:
                result.states[record.operationID] = .planned
                plannedItems[record.operationID] = record.items ?? []
                plannedVersion[record.operationID] = record.planVersion ?? DeletionPlan.currentVersion
                plannedAt[record.operationID] = record.recordedAt
            case .started:
                result.states[record.operationID] = .started
            case .itemResult:
                if let item = record.item, let outcome = record.outcome {
                    outcomes[record.operationID, default: [:]][item.path] = outcome
                }
            case .committed:
                result.states[record.operationID] = .committed
            }
        }

        for (operationID, state) in result.states where state != .committed {
            result.interrupted.append(InterruptedOperation(
                operationID: operationID,
                planVersion: plannedVersion[operationID] ?? DeletionPlan.currentVersion,
                state: state,
                plannedAt: plannedAt[operationID] ?? Date(timeIntervalSince1970: 0),
                items: plannedItems[operationID] ?? [],
                recordedOutcomes: outcomes[operationID] ?? [:]
            ))
        }
        result.interrupted.sort { $0.plannedAt < $1.plannedAt }
        return result
    }
}
