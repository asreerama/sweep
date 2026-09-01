import Darwin
import Foundation

public enum JournalError: Error, Equatable, CustomStringConvertible {
    case cannotCreate(url: URL, reason: String)
    case locked(url: URL)
    case writeFailed(reason: String)
    case syncFailed(reason: String)
    case corruptRecord(line: Int, reason: String)
    case unsupportedRecordVersion(line: Int, version: Int)
    case closed

    public var description: String {
        switch self {
        case .cannotCreate(let url, let reason): "cannot open journal at \(url.path): \(reason)"
        case .locked(let url):
            "journal at \(url.path) is already open in this or another process; "
                + "one owner at a time, so records cannot interleave"
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
///
/// The descriptor, its lock and every `fsync` live in ``JournalFile`` on a dedicated serial
/// queue. The actor holds only the decoded state, so an `fsync` on a slow volume suspends the
/// caller instead of parking a cooperative-pool thread (review finding #16).
public actor WALJournal {
    public let url: URL

    private let file: JournalFile
    private let queue: BlockingIOQueue
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Operations found uncommitted by the recovery scan at init.
    public private(set) var interrupted: [InterruptedOperation]
    /// True when the last line of the log was a torn write (a crash mid-append). The fragment is
    /// truncated away and the repair `fsync`'d before any append is accepted.
    public private(set) var recoveredTornTail: Bool

    public init(url: URL) async throws {
        self.url = url
        self.queue = BlockingIOQueue(label: "com.sweep.journal.io")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.interrupted = []
        self.recoveredTornTail = false

        self.file = try await queue.run { try JournalFile.open(url: url) }

        // Recovery scan before the first append, so an interrupted operation is known before
        // anything new is planned.
        let file = self.file
        let data = try await queue.run { try file.readAll() }
        let scan = try Self.parse(data: data, decoder: decoder)
        self.interrupted = scan.interrupted
        self.recoveredTornTail = scan.tornTail

        // A torn tail is tolerated but not left in place: the next valid record would be
        // concatenated onto the fragment and turn a survivable crash into fatal mid-file
        // corruption (review finding #6).
        if let truncateTo = scan.truncateTo {
            try await queue.run { try file.truncate(to: truncateTo) }
        }
    }

    /// Directories `fsync`'d when the journal was created. Exposed for the durability test.
    var syncedDirectories: [String] {
        file.syncedDirectories
    }

    public func close() async {
        let file = self.file
        try? await queue.run { file.close() }
    }

    // MARK: - Appends

    public func appendPlanned(operationID: UUID, planVersion: Int, items: [JournalItem]) async throws {
        try await append(JournalRecord(
            kind: .planned,
            operationID: operationID,
            planVersion: planVersion,
            items: items
        ))
    }

    public func appendStarted(operationID: UUID) async throws {
        try await append(JournalRecord(kind: .started, operationID: operationID))
    }

    public func appendItemResult(
        operationID: UUID,
        item: JournalItem,
        outcome: ItemOutcome,
        failureReason: ItemFailureReason? = nil,
        trashURL: URL? = nil,
        detail: String? = nil
    ) async throws {
        try await append(JournalRecord(
            kind: .itemResult,
            operationID: operationID,
            item: item,
            outcome: outcome,
            failureReason: failureReason,
            trashURL: trashURL,
            detail: detail
        ))
    }

    public func appendCommitted(operationID: UUID, detail: String? = nil) async throws {
        try await append(JournalRecord(kind: .committed, operationID: operationID, detail: detail))
    }

    /// Append + fsync. Any failure throws; callers abort rather than continue unlogged.
    /// Encoding stays on the actor (it is CPU work); only the write and the `fsync` hop.
    func append(_ record: JournalRecord) async throws {
        guard !file.isClosed else { throw JournalError.closed }
        var data: Data
        do {
            data = try encoder.encode(record)
        } catch {
            throw JournalError.writeFailed(reason: "encode: \(error)")
        }
        data.append(0x0A)

        let file = self.file
        let payload = data
        try await queue.run { try file.append(payload) }
    }

    // MARK: - Reading

    public func records() async throws -> [JournalRecord] {
        try await replay().records
    }

    /// Re-run the recovery scan against the current file contents.
    @discardableResult
    public func recover() async throws -> [InterruptedOperation] {
        let scan = try await replay()
        interrupted = scan.interrupted
        recoveredTornTail = scan.tornTail
        return scan.interrupted
    }

    public func state(of operationID: UUID) async throws -> OperationState? {
        try await replay().states[operationID]
    }

    private func replay() async throws -> Replay {
        let file = self.file
        let data = try await queue.run { try file.readAll() }
        return try Self.parse(data: data, decoder: decoder)
    }

    struct Replay: Sendable {
        var records: [JournalRecord] = []
        var interrupted: [InterruptedOperation] = []
        var states: [UUID: OperationState] = [:]
        var tornTail = false
        /// Byte length the file should be cut back to, set only when the tail was torn.
        var truncateTo: Int?
    }

    /// Parses the log. A truncated final line is dropped (crash mid-append); corruption
    /// anywhere else is fatal, because a hole in the middle means records after it cannot be
    /// trusted to describe the same history.
    static func parse(data: Data, decoder: JSONDecoder) throws -> Replay {
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
                    result.truncateTo = lastCompleteRecordLength(in: data)
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

    /// Bytes up to and including the last newline: everything the log can still vouch for.
    static func lastCompleteRecordLength(in data: Data) -> Int {
        guard let index = data.lastIndex(of: 0x0A) else { return 0 }
        return data.distance(from: data.startIndex, to: index) + 1
    }
}
