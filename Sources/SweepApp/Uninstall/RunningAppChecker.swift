import AppKit
import SweepUninstall

/// "Running apps show quit first state (NSRunningApplication check)" — PLAN §3 module 5.
///
/// Matches by bundle URL first (exact, works even for a `nil` bundle identifier), falling back
/// to bundle identifier for the case a running instance's `bundleURL` has been resolved through
/// a different-but-equivalent path (a symlink, a cryptex-relocated system app — see
/// `AppInventory`'s own comments on that).
enum RunningAppChecker {
    static func isRunning(
        _ app: InstalledApp,
        runningApplications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> Bool {
        matching(app, in: runningApplications) != nil
    }

    /// Asks the app to quit normally (`NSRunningApplication.terminate()` — a graceful request,
    /// not a force-kill). This is process preflight, not deletion: PLAN §3 module 5 lists "quit
    /// app + bootout its agents before bundle removal" as a legitimate step this build may take,
    /// distinct from the Gate U removal itself, which stays fully locked.
    @discardableResult
    static func quit(
        _ app: InstalledApp,
        runningApplications: [NSRunningApplication] = NSWorkspace.shared.runningApplications
    ) -> Bool {
        guard let running = matching(app, in: runningApplications) else { return false }
        return running.terminate()
    }

    private static func matching(_ app: InstalledApp, in runningApplications: [NSRunningApplication]) -> NSRunningApplication? {
        // `.path` string equality, never raw `URL ==`: `NSRunningApplication.bundleURL` and
        // `AppInventory`'s enumerated `bundlePath` can carry different directory-hint metadata
        // for the identical location and compare unequal under `URL.==` despite an identical
        // `.path` (see the matching fix + comment in `UninstallModel.selectDroppedApp`, found via
        // this exact class of bug against a real cryptex-relocated system app on this machine).
        let standardizedBundlePath = app.bundlePath.standardizedFileURL.path
        return runningApplications.first { candidate in
            if candidate.bundleURL?.standardizedFileURL.path == standardizedBundlePath { return true }
            if let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty {
                return candidate.bundleIdentifier == bundleIdentifier
            }
            return false
        }
    }
}
