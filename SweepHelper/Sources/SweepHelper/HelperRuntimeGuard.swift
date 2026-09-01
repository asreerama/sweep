import Darwin

/// PLAN §2 task spec: "Helper refuses if effective uid != 0 at runtime but must also build+test
/// its validation logic as a normal-user unit test." Kept as a pure, injectable predicate for
/// exactly that reason — `main.swift` calls it with the real `geteuid()`; the test target calls it
/// with fabricated values and needs no elevated privilege to do so.
enum HelperRuntimeGuard {
    static func isRunningAsRoot(effectiveUID: uid_t = geteuid()) -> Bool {
        effectiveUID == 0
    }
}
