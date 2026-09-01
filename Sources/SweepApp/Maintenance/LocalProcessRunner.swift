import Foundation

/// Minimal fixed-absolute-path runner for the one user-level command Maintenance needs directly
/// (`dscacheutil -flushcache`) — never a shell, never `sudo`. Same bounded-pipe/timeout shape as
/// `BrewProcessRunner` (this target) and `SweepUninstall.PkgutilReceipts.ProcessRunner`, trimmed
/// to this one caller rather than shared — see either of those two for why this codebase
/// re-implements this pattern per call site instead of importing it across a target boundary.
enum LocalProcessRunner {
    enum RunError: Error, Sendable, CustomStringConvertible {
        case nonZeroExit(Int32, stderr: String)
        case timedOut
        case outputLimitExceeded

        var description: String {
            switch self {
            case .nonZeroExit(let code, let stderr): "exited \(code): \(stderr)"
            case .timedOut: "timed out"
            case .outputLimitExceeded: "output exceeded the byte cap"
            }
        }
    }

    static let defaultTimeout: TimeInterval = 10
    static let defaultOutputByteLimit = 256 * 1024
    private static let sanitizedEnvironment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory()]
    private static let sanitizedWorkingDirectory = URL(fileURLWithPath: "/private/var/empty")

    @discardableResult
    static func run(
        _ executablePath: String,
        _ arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        outputByteLimit: Int = defaultOutputByteLimit
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.environment = sanitizedEnvironment
        process.currentDirectoryURL = sanitizedWorkingDirectory

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let stdoutReader = LocalBoundedPipeReader(pipe: stdoutPipe, byteLimit: outputByteLimit)
        let stderrReader = LocalBoundedPipeReader(pipe: stderrPipe, byteLimit: outputByteLimit)

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async { stdoutReader.readToLimitOrEOF(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { stderrReader.readToLimitOrEOF(); group.leave() }
        group.enter()
        DispatchQueue.global(qos: .utility).async { process.waitUntilExit(); group.leave() }

        let deadline = Date().addingTimeInterval(timeout)
        var didTimeOut = false
        var didOverflow = false
        while true {
            if stdoutReader.overflowed || stderrReader.overflowed {
                didOverflow = true
                break
            }
            if group.wait(timeout: .now() + 0.05) == .success {
                break
            }
            if Date() >= deadline {
                didTimeOut = true
                break
            }
        }

        if didOverflow || didTimeOut {
            stdoutReader.requestStop()
            stderrReader.requestStop()
            if process.isRunning {
                process.terminate()
            }
            _ = group.wait(timeout: .now() + 2)
        }

        if didTimeOut { throw RunError.timedOut }
        if didOverflow { throw RunError.outputLimitExceeded }

        guard process.terminationStatus == 0 else {
            throw RunError.nonZeroExit(process.terminationStatus, stderr: stderrReader.string)
        }
        return stdoutReader.string
    }
}

private final class LocalBoundedPipeReader: @unchecked Sendable {
    private let handle: FileHandle
    private let byteLimit: Int
    private let lock = NSLock()
    private var data = Data()
    private var stopRequested = false
    private(set) var overflowed = false

    init(pipe: Pipe, byteLimit: Int) {
        handle = pipe.fileHandleForReading
        self.byteLimit = byteLimit
    }

    func requestStop() {
        lock.lock()
        stopRequested = true
        lock.unlock()
    }

    private var shouldStop: Bool {
        lock.lock()
        defer { lock.unlock() }
        return stopRequested
    }

    func readToLimitOrEOF() {
        while !shouldStop {
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            lock.lock()
            data.append(chunk)
            let exceeded = data.count > byteLimit
            if exceeded { overflowed = true }
            lock.unlock()
            if exceeded { return }
        }
    }

    var string: String {
        lock.lock()
        defer { lock.unlock() }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
