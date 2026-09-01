import Foundation
import SystemConfiguration

/// Who is logged into the GUI (Aqua) console session right now — the one system call
/// `HelperTrust.isAuthorizedCaller`'s UID check needs. Kept in its own tiny file so that function
/// itself stays pure and testable without `SystemConfiguration` or a real console session (see
/// `SweepPolicyTests/HelperTrustTests.swift`).
enum ConsoleUser {
    static func currentConsoleUID() -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard let name = SCDynamicStoreCopyConsoleUser(nil, &uid, &gid) as String?, !name.isEmpty else {
            return nil
        }
        return uid
    }
}
