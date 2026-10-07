// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "satz",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "SatzKit", targets: ["SatzKit"]),
        .executable(name: "SatzMac", targets: ["SatzMac"]),
    ],
    dependencies: [
        // Whisper on the Mac's own chip, for the provider "Lokal".
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", exact: "1.1.0"),
    ],
    targets: [
        .target(name: "SatzKit"),
        .executableTarget(name: "SatzMac", dependencies: [
            "SatzKit",
            .product(name: "WhisperKit", package: "WhisperKit"),
        ]),
        .testTarget(name: "SatzKitTests", dependencies: ["SatzKit"]),
    ]
)
