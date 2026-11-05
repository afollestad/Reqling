// swift-tools-version: 6.2
import PackageDescription

/// A loopback GraphQL server for Reqling's tests and for trying GraphQL features by hand (`scripts/graphql-server.sh`).
/// It lives in its own package so `scripts/build.sh`, which builds every root product, never builds or ships it. Pins
/// match the root package's exactly; a mismatch fails resolution of the root.
let package = Package(
    name: "GraphQLFixtureServer",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "GraphQLFixtureServer", targets: ["GraphQLFixtureServer"]),
        .executable(name: "graphql-fixture-server", targets: ["GraphQLFixtureServerTool"])
    ],
    dependencies: [
        .package(url: "https://github.com/GraphQLSwift/GraphQL.git", exact: "4.3.0"),
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5")
    ],
    targets: [
        .target(
            name: "GraphQLFixtureServer",
            dependencies: [
                .product(name: "GraphQL", package: "GraphQL"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl")
            ]
        ),
        .executableTarget(name: "GraphQLFixtureServerTool", dependencies: ["GraphQLFixtureServer"])
    ]
)
