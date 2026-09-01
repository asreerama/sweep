import Foundation
import SweepUninstall
import XCTest
@testable import SweepCore

/// Gate U fixture helpers: fake `.app` bundles + fake `~/Library` leftovers inside a disposable
/// ``FixtureHome`` — mirrors how `CleanAdapterPipelineTests`/`AuthorizedCleanPlanTests` build
/// fixture trees for Gate 1, and how `SweepUninstallTests/LeftoverFixture.swift` builds its own
/// `~/Library`-shaped tree for the matcher package itself.
extension FixtureHome {
    /// `<home>/Applications` — the fixture stand-in this suite always passes as
    /// `UninstallRequest`'s injected `applicationsDirectories`, never the real `/Applications`.
    var applicationsDirectory: URL { url("Applications") }

    /// Builds a real, readable `.app` bundle: `Contents/Info.plist` with the given identifier,
    /// plus a minimal executable so the bundle is fully bundle-shaped. Returns the bundle's URL.
    ///
    /// `codeSign`: Codex Gate-U finding #1 requires a `VerifiedBundle` (a full, live
    /// `SecStaticCodeCheckValidity` pass whose signing identifier agrees with the bundle id)
    /// before an `exactBundleID`/`receiptListed` leftover match may be auto-admitted, and before
    /// every leftover of an app is no longer capped at manual review. Pass `true` for any fixture
    /// whose test exercises that auto-admission path; ad-hoc signing (`codesign -s -`) needs no
    /// real certificate, so this is portable across any Mac with the Xcode command line tools.
    @discardableResult
    func makeAppBundle(
        name: String = "FixtureApp",
        bundleIdentifier: String,
        relativeDirectory: String = "Applications",
        codeSign: Bool = false
    ) throws -> URL {
        let bundleURL = url("\(relativeDirectory)/\(name).app")
        let contents = bundleURL.appending(path: "Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let infoPlist: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundleShortVersionString": "1.0",
            "CFBundleVersion": "1",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": name,
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: infoPlist, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))

        let macOS = contents.appending(path: "MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let executable = macOS.appending(path: name)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        if codeSign {
            try FixtureCodeSigning.adHocSign(bundleURL)
        }

        return bundleURL
    }

    /// A leftover directory under one of `SweepUninstall.SearchRoot`'s real relative locations,
    /// e.g. `makeLeftover(root: .applicationSupport, name: "com.example.fixture")` ->
    /// `<home>/Library/Application Support/com.example.fixture`.
    @discardableResult
    func makeLeftover(root: SearchRoot, name: String, systemLaunchDaemonsDirectory: URL? = nil) throws -> URL {
        let base = root.url(
            homeDirectory: self.root,
            systemLaunchDaemonsDirectory: systemLaunchDaemonsDirectory ?? url("LaunchDaemons")
        )
        let target = base.appending(path: name)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("leftover".utf8).write(to: target.appending(path: "data.bin"))
        return target
    }
}

/// Ad-hoc code-signing for fixture bundles (Codex Gate-U finding #1's `VerifiedBundle`).
enum FixtureCodeSigning {
    static func adHocSign(_ bundleURL: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["-s", "-", "--force", bundleURL.path]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw XCTSkip("codesign unavailable or failed in this environment: \(message)")
        }
    }
}

/// Probes whether `FileManager.trashItem` actually works in this environment, mirroring every
/// other real-Trash test in this codebase (`CleanServiceTests`, `CleanAdapterPipelineTests`):
/// skip rather than fail when it does not.
enum TrashAvailabilityProbe {
    static func skipIfUnavailable(near directory: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        let probeURL = directory.appending(path: "gateU-trash-probe-\(UUID().uuidString).txt")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("probe".utf8).write(to: probeURL)
        var probe: NSURL?
        do {
            try FileManager.default.trashItem(at: probeURL, resultingItemURL: &probe)
            if let probe = probe as URL? { try? FileManager.default.removeItem(at: probe) }
        } catch {
            try? FileManager.default.removeItem(at: probeURL)
            throw XCTSkip("FileManager.trashItem unavailable here: \(error.localizedDescription)")
        }
    }
}
