// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SweepPolicy",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SweepPolicy", targets: ["SweepPolicy"])],
    targets: [
        .target(name: "SweepPolicy"),
        .testTarget(name: "SweepPolicyTests", dependencies: ["SweepPolicy"]),
    ]
)
