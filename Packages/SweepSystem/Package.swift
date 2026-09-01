// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SweepSystem",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SweepSystem", targets: ["SweepSystem"])],
    
    targets: [
        .target(name: "SweepSystem"),
        .testTarget(name: "SweepSystemTests", dependencies: ["SweepSystem"]),
    ]
)
