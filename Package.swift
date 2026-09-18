// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "satz",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SatzKit", targets: ["SatzKit"]),
        .executable(name: "SatzMac", targets: ["SatzMac"]),
    ],
    targets: [
        .target(name: "SatzKit"),
        .executableTarget(name: "SatzMac", dependencies: ["SatzKit"]),
        .testTarget(name: "SatzKitTests", dependencies: ["SatzKit"]),
    ]
)
