import Foundation

/// Locates the `brew` executable by fixed absolute path — never a `PATH` lookup, never a shell.
///
/// PLAN §2 "Command execution": typed adapters only, fixed absolute executable paths. Two
/// candidates, Apple Silicon first (this machine's real layout), Intel second, so the module
/// still works on an Intel Mac without ever asking the shell to resolve `brew` for us.
enum BrewExecutable {
    static let appleSiliconPath = "/opt/homebrew/bin/brew"
    static let intelPath = "/usr/local/bin/brew"

    /// `nil` when neither fixed path is an executable regular file — the "brew missing" case the
    /// screen renders as a friendly empty state, never an error.
    static func locate(fileManager: FileManager = .default) -> String? {
        for candidate in [appleSiliconPath, intelPath] where fileManager.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}

/// Fixed-executable-path process runner for `brew` (and the `du`-equivalent sizing this module
/// does entirely in-process — see `DirectorySize.swift` — so `brew` is the only external tool
/// this file ever launches). Never interprets a shell string, never `sh -c`.
///
/// Deliberately mirrors the hardened pattern in `Packages/SweepUninstall/Sources/SweepUninstall/
/// PkgutilReceipts.swift` (concurrent bounded pipe draining, wall-clock timeout, per-stream byte
/// cap) rather than importing it: that type is `internal` to `SweepUninstall` and not reachable
/// from this target, and brew's own defaults differ enough (30 s timeout — brew subcommands touch
/// the network-adjacent formula/cask index and are not the "local, fast metadata read" pkgutil's
/// 10 s assumes; a sanitized `HOMEBREW_*`/`PATH` environment brew itself needs) that a shared type
/// would need a second config surface anyway.
enum BrewProcessRunner {
    enum RunError: Error, Sendable, Equatable {
        case brewNotFound
        case nonZeroExit(Int32, stderr: String)
        /// Neither exit nor either pipe reaching EOF within `timeout`.
        case timedOut
        /// One of the two streams exceeded `outputByteLimit` before the process finished.
        case outputLimitExceeded
    }

    /// PLAN task spec: 30 s. Longer than `pkgutil`'s 10 s (`PkgutilReceipts.ProcessRunner`) on
    /// purpose — `brew outdated`/`brew list` can touch a locally-cached formula/cask index that a
    /// pure metadata read never does, and 30 s is still well short of "hung."
    static let defaultTimeout: TimeInterval = 30
    static let defaultOutputByteLimit = 4 * 1024 * 1024

    /// Runs as the current user (a plain `Process` launch, never `sudo`/`AuthorizationExecuteWith
    /// Privileges`/AppleScript privilege escalation) — PLAN §2: "User-tool commands (`brew`,
    /// `xcrun`) run as user, never root."
    ///
    /// Environment is a fixed, explicit allowlist, never this process's inherited environment:
    /// a minimal `PATH` (brew shells out to `git`/`curl` for some subcommands and needs the
    /// standard tool locations, plus its own `bin` so it can find itself) and the `HOMEBREW_NO_*`
    /// flags that keep every call quiet and non-interactive (no auto-update network fetch, no
    /// analytics ping, no "hints" banner text mixed into output this module parses as JSON).
    private static func sanitizedEnvironment(brewPath: String) -> [String: String] {
        let brewBinDirectory = (brewPath as NSString).deletingLastPathComponent
        return [
            "PATH": "\(brewBinDirectory):/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": NSHomeDirectory(),
            "HOMEBREW_NO_AUTO_UPDATE": "1",
            "HOMEBREW_NO_ANALYTICS": "1",
            "HOMEBREW_NO_ENV_HINTS": "1",
            "HOMEBREW_NO_INSTALL_CLEANUP": "1",
        ]
    }

    @discardableResult
    static func run(
        brewPath: String,
        _ arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        outputByteLimit: Int = defaultOutputByteLimit
    ) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: brewPath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.environment = sanitizedEnvironment(brewPath: brewPath)
        // Brew reads/writes no working-directory-relative state for the subcommands this module
        // calls, but a fixed, non-writable cwd (never this process's own cwd) is the same
        // discipline `PkgutilReceipts.ProcessRunner` applies for the same reason: never hand a
        // child process an ambient path it did not ask for.
        process.currentDirectoryURL = URL(fileURLWithPath: "/private/var/empty")

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // Concurrent, incremental drain of both streams — see `PkgutilReceipts.ProcessRunner`'s
        // doc comment for the exact deadlock this avoids (a child whose stderr pipe buffer fills
        // while nothing is reading it yet blocks forever on its own `write()`, and a naive
        // "readDataToEndOfFile on stdout first" caller then blocks right alongside it).
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
/// is exceeded, or an external stop is requested. Byte-for-byte the same shape as
/// `PkgutilReceipts.BoundedPipeReader` (`private` there, so re-declared here rather than shared).
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
