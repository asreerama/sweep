import Foundation
import SweepPolicy

/// The one call site that turns a decoded, validated ``MaintenanceOperation`` into real commands.
/// Nothing upstream of this (the XPC layer, the decoder) ever runs a process; nothing downstream
/// of it (``HelperProcessRunner``) knows what a `MaintenanceOperation` is.
enum MaintenanceExecutor {
    /// `SWEEP_HELPER_DRYRUN=1` — task spec: "prints command instead of executing". Reading the
    /// environment is the one non-pure part; the flag itself is threaded through as an explicit
    /// parameter everywhere else so the dry-run path is exercised directly in tests without ever
    /// setting process-wide environment state.
    static func isDryRunRequested(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["SWEEP_HELPER_DRYRUN"] == "1"
    }

    /// `mountedVolumes` defaults to the real live list (`FileManager`, via ``MountedVolumes``) but
    /// is overridable so validation-against-mounted-volumes is testable without a real disk
    /// layout. Validation always runs — dry run only skips the part that would spawn a process.
    static func execute(
        _ operation: MaintenanceOperation,
        mountedVolumes: [String] = MountedVolumes.currentPaths(),
        dryRun: Bool
    ) -> MaintenanceOutcome {
        if let validationError = MaintenanceValidation.validate(operation, mountedVolumes: mountedVolumes) {
            return .failed(reason: validationError.description)
        }

        let commands = MaintenanceCommandPlan.commands(for: operation)

        if dryRun {
            return .succeeded(detail: "DRY RUN \u{2014} nothing executed:\n" + commands.map(\.commandLine).joined(separator: "\n"))
        }

        for command in commands {
            do {
                _ = try HelperProcessRunner.run(command.executablePath, command.arguments)
            } catch {
                return .failed(reason: "\(command.commandLine) failed: \(error)")
            }
        }
        return .succeeded(detail: commands.map(\.commandLine).joined(separator: "\n"))
    }
}

/// The live mounted-volume list, sourced from `FileManager` — never from anything an XPC client
/// asserts. The one call site ``MaintenanceExecutor`` uses by default; tests inject their own list.
enum MountedVolumes {
    static func currentPaths(fileManager: FileManager = .default) -> [String] {
        (fileManager.mountedVolumeURLs(includingResourceValuesForKeys: nil, options: [.skipHiddenVolumes]) ?? [])
            .map(\.path)
    }
}
