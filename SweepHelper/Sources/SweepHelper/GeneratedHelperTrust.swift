/// Overwritten by `scripts/build-app.sh` immediately before it builds the release helper: the
/// signing cert's leaf-certificate SHA-1 hash, extracted via `codesign -d -r-` on a probe file
/// signed with the exact same identity that then signs both `SweepApp` and `SweepHelper`
/// (build order: extract hash -> regenerate this file -> `swift build` -> sign helper -> sign app,
/// so the hash embedded here is always the one both binaries actually carry).
///
/// Checked in with a placeholder that `HelperTrust.isValidLeafHash` always rejects, so a helper
/// built any other way — a plain `swift build`, CI, `swift test` — refuses to start
/// (`main.swift`'s very first gate) rather than stand up an `NSXPCListener` trusting nothing, or
/// worse, trusting everything.
enum GeneratedHelperTrust {
    static let designatedRequirementLeafHash = "UNSET-PLACEHOLDER-REPLACED-BY-scripts-build-app-sh"
}
