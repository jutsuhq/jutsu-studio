// swift-tools-version: 6.2
// Parakeet Ultra on-device through FluidAudio, for the app target only: JutsuKit's packages and tests never build it.
// Tools 6.2 for package traits: FluidAudio's `NemoTextProcessing` trait links a prebuilt binary for text
// normalization, which the subtitles don't use, so every trait is off and nothing prebuilt is linked.
import PackageDescription

let package = Package(
    name: "ParakeetKit",
    platforms: [.macOS(.v14)],
    products: [.library(name: "ParakeetKit", targets: ["ParakeetKit"])],
    dependencies: [
        .package(path: "../JutsuKit"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.7", traits: []),
    ],
    targets: [
        .target(
            name: "ParakeetKit",
            dependencies: [
                .product(name: "JutsuCore", package: "JutsuKit"),
                .product(name: "FluidAudio", package: "FluidAudio"),
            ])
    ]
)
