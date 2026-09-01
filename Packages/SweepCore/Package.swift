// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SweepCore",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SweepCore", targets: ["SweepCore"])],
    dependencies: [.package(path: "../SweepPolicy")],
    targets: [
        .target(name: "SweepCore", dependencies: [.product(name: "SweepPolicy", package: "SweepPolicy")]),
        .testTarget(name: "SweepCoreTests", dependencies: ["SweepCore"]),
    ]
)
