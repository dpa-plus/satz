// swift-tools-version: 6.2
import PackageDescription

/// sherpa-onnx's libraries, fetched by `make sherpa` (see the Makefile).
let sherpaLibraries = Context.packageDirectory + "/vendor/sherpa-onnx/lib"

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
        // Ultra uses CoreML. The optional speech-synthesis normalizer is unused.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.3", traits: []),
    ],
    targets: [
        .target(name: "SatzKit"),
        // Parakeet, Canary, Moonshine and SenseVoice for "Lokal", through
        // sherpa-onnx's C API on ONNX Runtime.
        .systemLibrary(name: "CSherpaOnnx"),
        .executableTarget(
            name: "SatzMac",
            dependencies: [
                "SatzKit",
                "CSherpaOnnx",
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            // The libraries sit in satz.app/Contents/Frameworks (make bundle).
            linkerSettings: [.unsafeFlags(["-L", sherpaLibraries, "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .testTarget(name: "SatzKitTests", dependencies: ["SatzKit"]),
        // The app's own logic (paste, card, media): built from the app's
        // code, so it links sherpa-onnx too, found where make sherpa puts it.
        .testTarget(
            name: "SatzMacTests",
            dependencies: ["SatzMac"],
            linkerSettings: [.unsafeFlags(["-L", sherpaLibraries, "-Xlinker", "-rpath", "-Xlinker", sherpaLibraries])]
        ),
    ]
)
