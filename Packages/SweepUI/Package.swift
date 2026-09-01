// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SweepUI",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SweepUI", targets: ["SweepUI"])],
    
    targets: [
        .target(name: "SweepUI"),
        .testTarget(name: "SweepUITests", dependencies: ["SweepUI"]),
    ]
)
