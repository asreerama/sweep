// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SweepCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SweepCore", targets: ["SweepCore"])],
    dependencies: [
        .package(path: "../SweepPolicy"),
        // Gate U (uninstall execution, PLAN §3 module 5): the authorization layer re-derives
        // leftover ownership evidence itself rather than trusting a caller-supplied match, via
        // SweepUninstall's `AppInventory`/`LeftoverMatcher`/`OwnershipEvidence`. SweepUninstall
        // has no dependencies of its own, so this adds no cycle risk.
        .package(path: "../SweepUninstall"),
    ],
    targets: [
        .target(name: "SweepCore", dependencies: [
            .product(name: "SweepPolicy", package: "SweepPolicy"),
            .product(name: "SweepUninstall", package: "SweepUninstall"),
        ]),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore", "SweepUninstall"]),
    ]
)
