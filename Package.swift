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
        // Standalone menubar process (PLAN §3 module 7, the P4-B decision-gate split): the in-app
        // `MenuBarExtra` measured 92.6 MB idle against a 50 MB budget — the floor is SwiftUI
        // window/Scene machinery the main app also needs for its real window, not anything this
        // process requires. `SweepMenu` depends on nothing from `SweepApp`/`SweepCore`/
        // `SweepPolicy`/`SweepUninstall` — only the two packages it actually needs to show live
        // stats — so it can never grow the deletion/XPC/rules surface `SweepApp` carries.
        .executableTarget(
            name: "SweepMenu",
            dependencies: [
                .product(name: "SweepSystem", package: "SweepSystem"),
                .product(name: "SweepUI", package: "SweepUI"),
            ],
            path: "Sources/SweepMenu"
        ),
        .testTarget(
            name: "SweepMenuTests",
            dependencies: ["SweepMenu"],
            path: "Tests/SweepMenuTests"
        ),
    ]
)
