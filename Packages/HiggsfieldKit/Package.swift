// swift-tools-version: 6.0
import PackageDescription

// The Higgsfield clients, apart from the app: Foundation only and no app types, so they build on Linux and can
// be updated against Higgsfield's changes without touching JutsuKit. JutsuKit's HiggsfieldProviders maps them to
// the app's GenerationProvider.
let package = Package(
    name: "HiggsfieldKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HiggsfieldCore", targets: ["HiggsfieldCore"]),
        .library(name: "HiggsfieldAPI", targets: ["HiggsfieldAPI"]),
        .library(name: "HiggsfieldMCP", targets: ["HiggsfieldMCP"]),
        // A stub HTTP host and MCP server, for tests of code built on these clients.
        .library(name: "HiggsfieldTestSupport", targets: ["HiggsfieldTestSupport"]),
    ],
    targets: [
        // The errors and job states both connections report, and the URLSession transport they share with the
        // app's downloader.
        .target(name: "HiggsfieldCore"),
        // REST API at api.higgsfield.ai, authorized with an API key.
        .target(name: "HiggsfieldAPI", dependencies: ["HiggsfieldCore"]),
        // MCP server at mcp.higgsfield.ai, authorized with an OAuth sign-in to a Higgsfield account.
        .target(name: "HiggsfieldMCP", dependencies: ["HiggsfieldCore"]),
        .target(name: "HiggsfieldTestSupport", dependencies: ["HiggsfieldMCP"], path: "Tests/HiggsfieldTestSupport"),
        .testTarget(name: "HiggsfieldCoreTests", dependencies: ["HiggsfieldCore"]),
        .testTarget(name: "HiggsfieldAPITests", dependencies: ["HiggsfieldAPI", "HiggsfieldTestSupport"]),
        .testTarget(name: "HiggsfieldMCPTests", dependencies: ["HiggsfieldMCP", "HiggsfieldTestSupport"]),
    ]
)
