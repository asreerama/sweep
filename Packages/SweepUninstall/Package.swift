// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SweepUninstall",
    platforms: [.macOS(.v15)],
    products: [.library(name: "SweepUninstall", targets: ["SweepUninstall"])],
    
    targets: [
        .target(name: "SweepUninstall"),
        .testTarget(name: "SweepUninstallTests", dependencies: ["SweepUninstall"]),
    ]
)
