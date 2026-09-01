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
enum ProcessRunner {
    enum RunError: Error, Sendable { case nonZeroExit(Int32, stderr: String) }

    @discardableResult
    static func run(_ executablePath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RunError.nonZeroExit(process.terminationStatus, stderr: String(data: errData, encoding: .utf8) ?? "")
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}
