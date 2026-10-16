// swift-tools-version: 6.0
import PackageDescription

// JutsuCore, HiggsfieldProviders, JobEngine and Presentation use Foundation only, so they also build on Linux:
// CI and Windows contributors (via Docker) run their tests without a Mac.
// Everything that needs Apple frameworks is added on macOS only.
var products: [Product] = [
    .library(name: "JutsuCore", targets: ["JutsuCore"]),
    .library(name: "HiggsfieldProviders", targets: ["HiggsfieldProviders"]),
    .library(name: "JobEngine", targets: ["JobEngine"]),
    .library(name: "Presentation", targets: ["Presentation"]),
]

var targets: [Target] = [
    .target(name: "JutsuCore", resources: [.process("Resources")]),
    // Both Higgsfield connections as GenerationProviders, over the clients in HiggsfieldKit.
    .target(
        name: "HiggsfieldProviders",
        dependencies: [
            "JutsuCore",
            .product(name: "HiggsfieldCore", package: "HiggsfieldKit"),
            .product(name: "HiggsfieldAPI", package: "HiggsfieldKit"),
            .product(name: "HiggsfieldMCP", package: "HiggsfieldKit"),
        ],
        resources: [.process("Resources")]),
    // HiggsfieldCore only for the shared URLSession transport, which keeps networking out of JutsuCore.
    .target(
        name: "JobEngine", dependencies: ["JutsuCore", .product(name: "HiggsfieldCore", package: "HiggsfieldKit")],
        resources: [.process("Resources")]),
    // eventually and Gate, shared by the test targets.
    .target(name: "JutsuTestSupport", path: "Tests/JutsuTestSupport"),
    .testTarget(name: "JutsuCoreTests", dependencies: ["JutsuCore"]),
    .testTarget(
        name: "HiggsfieldProvidersTests",
        dependencies: [
            "HiggsfieldProviders", "JutsuCore", "JutsuTestSupport",
            .product(name: "HiggsfieldCore", package: "HiggsfieldKit"),
            .product(name: "HiggsfieldAPI", package: "HiggsfieldKit"),
            .product(name: "HiggsfieldMCP", package: "HiggsfieldKit"),
            .product(name: "HiggsfieldTestSupport", package: "HiggsfieldKit"),
        ]),
    .testTarget(name: "JobEngineTests", dependencies: ["JobEngine", "JutsuCore", "JutsuTestSupport"]),
    .target(name: "Presentation", dependencies: ["JutsuCore"], resources: [.process("Resources")]),
    .testTarget(name: "PresentationTests", dependencies: ["Presentation", "JutsuCore", "JutsuTestSupport"]),
]

#if os(macOS)
    products += [
        .library(name: "Secrets", targets: ["Secrets"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "Persistence", targets: ["Persistence"]),
    ]

    targets += [
        .target(name: "Secrets", dependencies: ["JutsuCore"]),
        .target(name: "MediaKit", dependencies: ["JutsuCore"], resources: [.process("Resources")]),
        .target(name: "Persistence", dependencies: ["JutsuCore"]),
        .testTarget(name: "SecretsTests", dependencies: ["Secrets"]),
        .testTarget(name: "PersistenceTests", dependencies: ["Persistence"]),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit", "JutsuCore"]),
    ]
#endif

let package = Package(
    name: "JutsuKit",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: products,
    dependencies: [.package(path: "../HiggsfieldKit")],
    targets: targets
)
