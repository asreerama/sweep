import Foundation

/// Read-only access to `pkgutil` receipts. Only ever invokes `pkgutil --pkgs` and
/// `pkgutil --files <id>` — pure queries. This package never calls `pkgutil --forget` or any
/// other mutating pkgutil subcommand; forgetting a receipt is a deletion-adjacent decision
/// that belongs to `SweepCore`'s `DeletionCoordinator`, not the discovery layer.
public protocol PkgutilReceiptsProviding: Sendable {
    /// All installed package identifiers (`pkgutil --pkgs`).
    func packageIdentifiers() -> [String]
    /// File paths (relative to `/`) a package installed (`pkgutil --files <id>`).
    func files(forPackageID id: String) -> [String]
}

/// Real `pkgutil` CLI-backed implementation, via a fixed-path `Process` invocation (never a
/// shell), per PLAN.md §2 "Command execution: typed adapters only".
public struct PkgutilReceiptsProvider: PkgutilReceiptsProviding {
    private static let pkgutilPath = "/usr/sbin/pkgutil"

    public init() {}

    public func packageIdentifiers() -> [String] {
        lines(from: try? ProcessRunner.run(Self.pkgutilPath, ["--pkgs"]))
    }

    public func files(forPackageID id: String) -> [String] {
        lines(from: try? ProcessRunner.run(Self.pkgutilPath, ["--files", id]))
    }

    private func lines(from output: String?) -> [String] {
        guard let output else { return [] }
        return output.split(separator: "\n").map(String.init)
    }
}

/// A provider that returns nothing, useful for callers that want receipt evidence disabled
/// entirely (e.g. sandboxed/offline test runs) without special-casing `nil`.
public struct EmptyPkgutilReceiptsProvider: PkgutilReceiptsProviding {
    public init() {}
    public func packageIdentifiers() -> [String] { [] }
    public func files(forPackageID id: String) -> [String] { [] }
}

/// Fixed-executable-path process runner. Never interprets a shell string, never a `sh -c`.
///
/// Hardened per finding #17 in the adversarial review: the previous implementation drained
/// stdout completely (`readDataToEndOfFile()`) before even starting to read stderr, with no
/// timeout and no output cap. A child that fills stderr's pipe buffer (64 KB on Darwin) while
/// keeping stdout open blocks on its own `write()` to stderr forever, and since nothing is
/// reading stderr yet, that child never exits — `readDataToEndOfFile()` on stdout then also
/// blocks forever waiting for a close that will never happen. Both streams are now drained
/// concurrently, and a hung or runaway child is bounded by both a wall-clock timeout and a
/// per-stream byte cap.
enum ProcessRunner {
    enum RunError: Error, Sendable, Equatable {
        case nonZeroExit(Int32, stderr: String)
        /// Neither exit nor either pipe reaching EOF within `timeout`.
        case timedOut
        /// One of the two streams exceeded `outputByteLimit` before the process finished.
        case outputLimitExceeded
    }

    /// Production default: `pkgutil` queries are local, fast metadata reads — anything still
    /// running after this long is treated as hung, not merely slow.
    static let defaultTimeout: TimeInterval = 10
    /// Production default: hard ceiling on how many bytes are retained from EITHER stream. A
    /// stream that keeps producing past this is killed rather than drained forever.
    static let defaultOutputByteLimit = 4 * 1024 * 1024

    /// Minimal, explicit environment for the child process — never inherits this process's full
    /// environment, which could carry an attacker-influenced `PATH`, locale, or proxy/debug
    /// variable that changes `pkgutil`'s behavior.
    private static let sanitizedEnvironment = ["PATH": "/usr/bin:/bin"]
    /// Fixed, always-present, non-writable working directory — never inherits this process's cwd.
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

        // Drain stdout and stderr concurrently, each on its own dedicated queue, incrementally
        // (never a single "read to EOF" call) so a child that never closes one stream can't wedge
        // the read of the other. See the type-level doc comment for the exact deadlock this
        // replaces.
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
            // Bounded cleanup wait only — never load-bearing for correctness, since every branch
            // below only inspects state that is already safe to read (the readers' locked
            // buffers, and `terminationStatus`, which is only consulted on the non-overflow,
            // non-timeout success path).
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

/// Reads one pipe's output incrementally on the caller's (background) queue, stopping the moment
/// either EOF is reached, `byteLimit` is exceeded, or an external stop is requested — never
/// blocking on a single "read to EOF" call the way `readDataToEndOfFile()` does, which is exactly
/// what let a child that never closes this pipe (because it's still writing to the *other* one)
/// hang the read forever.
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

    /// Ask the read loop to stop at its next opportunity — used once the sibling stream has
    /// already overflowed or the caller has decided to give up and terminate the process.
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

    /// Blocks the calling (background) queue, but only ever on a single chunk read at a time —
    /// `FileHandle.availableData` returns as soon as at least one byte is available or the
    /// writer end closes (empty `Data` = EOF), never waiting for the full stream to finish.
    func readToLimitOrEOF() {
        while !shouldStop {
            let chunk = handle.availableData
            if chunk.isEmpty { return } // EOF: writer end closed.
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
