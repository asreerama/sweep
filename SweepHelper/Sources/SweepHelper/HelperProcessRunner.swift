import Foundation

/// Fixed-executable-path process runner for the helper's four typed command adapters
/// (`dscacheutil`, `killall`, `mdutil`, `tmutil`) — never a shell, never `sh -c`. Same hardened
/// concurrent-drain shape as `SweepUninstall.PkgutilReceipts.ProcessRunner` and
/// `SweepApp.BrewProcessRunner`: both of those re-implement rather than share this pattern across
/// their own target boundary (see either file's doc comment), and this is a third target with its
/// own root-daemon-specific environment/timeout defaults, so the same choice applies here.
enum HelperProcessRunner {
    enum RunError: Error, Sendable, Equatable, CustomStringConvertible {
        case nonZeroExit(Int32, stderr: String)
        /// Neither exit nor either pipe reaching EOF within `timeout`.
        case timedOut
        /// One of the two streams exceeded `outputByteLimit` before the process finished.
        case outputLimitExceeded

        var description: String {
            switch self {
            case .nonZeroExit(let code, let stderr): "exited \(code): \(stderr)"
            case .timedOut: "timed out"
            case .outputLimitExceeded: "output exceeded the byte cap"
            }
        }
    }

    /// `tmutil thinlocalsnapshots` on a large local snapshot store can legitimately run for a
    /// while; the other three commands finish in well under a second. One generous shared ceiling
    /// rather than a per-command table — still far short of "hung."
    static let defaultTimeout: TimeInterval = 120
    static let defaultOutputByteLimit = 1 * 1024 * 1024

    /// Minimal, explicit environment — never this process's inherited environment (which, for a
    /// root daemon, could carry an attacker-influenced `PATH` from whatever launched it). None of
    /// the four commands this runner exists for need `HOME` for their own behavior, but `/var/root`
    /// is supplied anyway so nothing inside them falls back to an unset-`HOME` surprise.
    private static let sanitizedEnvironment = ["PATH": "/usr/bin:/usr/sbin:/bin:/sbin", "HOME": "/var/root"]
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

        // Drain stdout and stderr concurrently, incrementally — never a single "read to EOF" call,
        // which is exactly what lets a child that never closes one stream wedge the read of the
        // other (see `PkgutilReceipts.ProcessRunner`'s doc comment for the precise deadlock).
        let stdoutReader = BoundedPipeReader(pipe: stdoutPipe, byteLimit: outputByteLimit)
        let stderrReader = BoundedPipeReader(pipe: stderrPipe, byteLimit: outputByteLimit)

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

/// Reads one pipe's output incrementally, stopping the moment either EOF is reached, `byteLimit`
/// is exceeded, or an external stop is requested.
private final class BoundedPipeReader: @unchecked Sendable {
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
