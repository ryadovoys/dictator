// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dictator",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "Dictator", targets: ["Dictator"])
    ],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.15.5")],
    targets: [
        // Microphone capture, kept separate from the UI.
        .target(name: "DictationKit"),
        .executableTarget(name: "Dictator", dependencies: [
            "DictationKit", .product(name: "FluidAudio", package: "FluidAudio")
        ]),
        .testTarget(name: "DictatorTests", dependencies: [
            "Dictator", "DictationKit", .product(name: "FluidAudio", package: "FluidAudio")
        ])
    ],
    swiftLanguageModes: [.v5]
)
