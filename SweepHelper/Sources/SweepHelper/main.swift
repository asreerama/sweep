import Foundation
import Security
import SweepPolicy

// SweepHelper entry point. Every gate below is fail-closed and ordered so there is no code path
// that ever creates an `NSXPCListener` before every one of them has passed:
//
//   1. Real root (PLAN §2: "Helper refuses if effective uid != 0 at runtime").
//   2. A build-time-injected, correctly-shaped signing-cert hash AND app bundle identifier (never
//      the checked-in placeholders — see `GeneratedHelperTrust`). Both are required in the
//      designated requirement (Codex finding #1: a certificate-only requirement is satisfied by
//      any binary this machine's signing cert has signed, not just Sweep.app).
//   3. A requirement string `SecRequirementCreateWithString` actually accepts. Apple's own doc
//      comment on `setConnectionCodeSigningRequirement` says a malformed requirement throws an
//      Objective-C exception — uncatchable from Swift — so this is validated proactively with a
//      clear diagnostic instead of letting that call crash the daemon.
//
// Only after all three pass does the listener exist at all, and it is handed the requirement
// before `resume()` — nothing is ever briefly listening without one.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("SweepHelper: refusing to start: \(message)\n".utf8))
    exit(code)
}

guard HelperRuntimeGuard.isRunningAsRoot() else {
    fail("effective uid is not 0", code: EX_NOPERM)
}

guard HelperTrust.isValidLeafHash(GeneratedHelperTrust.designatedRequirementLeafHash) else {
    fail("no valid signing-cert hash was injected at build time (see scripts/build-app.sh)", code: EX_CONFIG)
}

guard HelperTrust.isValidAppIdentifier(GeneratedHelperTrust.designatedRequirementAppIdentifier) else {
    fail("no valid app bundle identifier was injected at build time (see scripts/build-app.sh)", code: EX_CONFIG)
}

let requirementString: String
do {
    requirementString = try HelperTrust.designatedRequirement(
        appIdentifier: GeneratedHelperTrust.designatedRequirementAppIdentifier,
        leafHash: GeneratedHelperTrust.designatedRequirementLeafHash
    )
} catch {
    fail("\(error)", code: EX_CONFIG)
}

var probeRequirement: SecRequirement?
let requirementStatus = SecRequirementCreateWithString(requirementString as CFString, [], &probeRequirement)
guard requirementStatus == errSecSuccess, probeRequirement != nil else {
    fail("SecRequirementCreateWithString rejected the generated requirement (status \(requirementStatus))", code: EX_CONFIG)
}

// `NSXPCListener.delegate` is `weak` — it must be held strongly somewhere for the life of the
// process, or the delegate is deallocated the instant it is assigned and every connection is
// then rejected (Apple's own doc comment: "If no delegate is set, all new connections will be
// rejected"). A silent, permanent refusal-to-serve is not the fail-closed behavior this file is
// otherwise all about; that failure mode belongs to the trust checks above, not to an ARC accident.
let listenerDelegate = HelperListenerDelegate()

let listener = NSXPCListener(machServiceName: HelperIdentity.machServiceName)
listener.delegate = listenerDelegate
listener.setConnectionCodeSigningRequirement(requirementString)
listener.resume()

RunLoop.main.run()
