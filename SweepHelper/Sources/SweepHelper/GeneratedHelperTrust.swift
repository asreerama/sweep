/// Overwritten by `scripts/build-app.sh` immediately before it builds the release helper: the
/// signing cert's leaf-certificate SHA-1 hash and Sweep.app's own bundle identifier, both read
/// back from the just-signed app bundle via `codesign -d -r-` on a probe file / the app itself,
/// signed with the exact same identity that then signs both `SweepApp` and `SweepHelper`
/// (build order: extract hash -> regenerate this file -> `swift build` -> sign helper -> sign app,
/// so the values embedded here are always the ones the shipped binaries actually carry).
///
/// `designatedRequirementAppIdentifier` is Sweep.app's identifier — never the helper binary's own
/// (a bare Mach-O executable's inferred identifier defaults to its filename, `SweepHelper`, which
/// is exactly the wrong thing to trust: see `HelperTrust.designatedRequirement`'s doc comment,
/// Codex finding #1).
///
/// Checked in with placeholders that `HelperTrust.isValidLeafHash`/`isValidAppIdentifier` always
/// reject, so a helper built any other way — a plain `swift build`, CI, `swift test` — refuses to
/// start (`main.swift`'s very first gates) rather than stand up an `NSXPCListener` trusting
/// nothing, or worse, trusting everything.
enum GeneratedHelperTrust {
    static let designatedRequirementLeafHash = "UNSET-PLACEHOLDER-REPLACED-BY-scripts-build-app-sh"
    static let designatedRequirementAppIdentifier = "UNSET PLACEHOLDER - REPLACED BY scripts/build-app.sh"
}
