import Foundation
import SweepPolicy

/// The half of `flushDNS` that never needs the helper. `dscacheutil -flushcache` runs fine as the
/// current user; the other half — `killall -HUP mDNSResponder`, signalling a daemon this process
/// does not own — needs root, which is exactly what makes it a helper-only step (PLAN §3 task
/// spec: "dscacheutil part works without root — run that path via user-level adapter when helper
/// unavailable, killall via helper only").
enum LocalDNSFlushAdapter {
    static func run() async -> MaintenanceOutcome {
        let command = MaintenanceCommandPlan.userLevelDNSFlushCommand
        do {
            _ = try await Task.detached(priority: .userInitiated) {
                try LocalProcessRunner.run(command.executablePath, command.arguments)
            }.value
            return .succeeded(
                detail: "\(command.commandLine)\n"
                    + "This only clears the local resolver cache. \u{201C}killall -HUP mDNSResponder\u{201D} "
                    + "needs the helper \u{2014} approve it above for a full flush."
            )
        } catch {
            return .failed(reason: "\(command.commandLine) failed: \(error)")
        }
    }
}
