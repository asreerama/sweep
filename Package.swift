// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sweep",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(path: "Packages/SweepPolicy"),
        .package(path: "Packages/SweepCore"),
        .package(path: "Packages/SweepSystem"),
        .package(path: "Packages/SweepUninstall"),
        .package(path: "Packages/SweepUI"),
    ],
    targets: [
        .executableTarget(
            name: "SweepApp",
            dependencies: [
                .product(name: "SweepPolicy", package: "SweepPolicy"),
                .product(name: "SweepCore", package: "SweepCore"),
                .product(name: "SweepSystem", package: "SweepSystem"),
                .product(name: "SweepUninstall", package: "SweepUninstall"),
                .product(name: "SweepUI", package: "SweepUI"),
            ],
            path: "Sources/SweepApp"
        ),
        .testTarget(
            name: "SweepAppTests",
            dependencies: [
                "SweepApp",
                // Codex G1 finding #8: the CleanAdapter-level execution test needs `@testable
                // import SweepCore` to reach `CleanService.runPipeline` (the internal test seam)
                // and the write-once bundled-catalog test hooks, without ever flipping
                // `gate1Open`.
                .product(name: "SweepCore", package: "SweepCore"),
            ],
            path: "Tests/SweepAppTests"
        ),
        // Privileged helper daemon (PLAN §2, §3 module 8, Appendix B). A separate executable
        // target, not a library `SweepApp` links against — the two communicate only over XPC
        // (`SweepPolicy`'s `SweepHelperXPCProtocol`), never by importing each other's code, which
        // is exactly the process boundary a privileged helper is supposed to have.
        .executableTarget(
            name: "SweepHelper",
            dependencies: [
                .product(name: "SweepPolicy", package: "SweepPolicy"),
            ],
            path: "SweepHelper/Sources/SweepHelper"
        ),
        .testTarget(
            name: "SweepHelperTests",
            dependencies: [
                "SweepHelper",
                .product(name: "SweepPolicy", package: "SweepPolicy"),
            ],
            path: "SweepHelper/Tests/SweepHelperTests"
        ),
    ]
)
