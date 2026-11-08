// swift-tools-version: 6.2
import PackageDescription

/// Every scoped folder carries an `AGENTS.md` plus its `CLAUDE.md` symlink. SwiftPM warns about
/// unhandled files inside a target, so each folder that has them is listed here.
func guidanceFiles(in folders: String...) -> [String] {
    folders.flatMap { folder in
        let prefix = folder.isEmpty ? "" : "\(folder)/"
        return ["\(prefix)AGENTS.md", "\(prefix)CLAUDE.md"]
    }
}

let package = Package(
    name: "Reqling",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Reqling", targets: ["Reqling"]),
        // Bundled beside the app: opens PKCS#12 files in a throwaway process first (`HelperPKCS12ImportProbe`).
        .executable(name: "ReqlingPKCS12Probe", targets: ["ReqlingPKCS12Probe"]),
        // Bundled beside the app: runs pre-request and post-response scripts in JavaScriptCore, killed at its time limit
        // (`HelperScriptRunner`).
        .executable(name: "ReqlingScriptRunner", targets: ["ReqlingScriptRunner"])
    ],
    dependencies: [
        .package(url: "https://github.com/uber/needle.git", revision: "69f7a889d2736f2621c6083ac29e0a75d158f249"),
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", exact: "1.19.2"),
        // gRPC: the core client, its HTTP/2 transport, protobuf serializers, and the descriptor types the codec reads.
        .package(url: "https://github.com/grpc/grpc-swift-2.git", exact: "2.4.4"),
        .package(url: "https://github.com/grpc/grpc-swift-nio-transport.git", exact: "2.12.0"),
        .package(url: "https://github.com/grpc/grpc-swift-protobuf.git", exact: "2.5.0"),
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.39.0"),
        // Test-only: a reflection server for the gRPC integration suite.
        .package(url: "https://github.com/grpc/grpc-swift-extras.git", exact: "2.2.2"),
        // NIO and its TLS carry the gRPC transport and WebSocket connections; tests also use them for loopback HTTP(S)
        // and WebSocket servers, with certificates minted at runtime.
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3"),
        // The built-in MCP server: protocol types, the server, and a stateless Streamable HTTP transport.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1"),
        // GraphQL: SDL schemas, parsing, and spec validation (GraphQLSwift, a port of graphql-js).
        .package(url: "https://github.com/GraphQLSwift/GraphQL.git", exact: "4.3.0"),
        // YAML: libyaml through Yams, for YAML responses and OpenAPI documents.
        .package(url: "https://github.com/jpsim/Yams.git", exact: "6.2.2"),
        // Test-only: a loopback GraphQL server. A separate package, so `scripts/build.sh`, which builds every root
        // product, never builds its executable; its pins must match these.
        .package(path: "Tools/GraphQLFixtureServer")
    ],
    targets: [
        .target(
            name: "ReqlingKit",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                // The gRPC executor's TLS hooks (trust callback, `SecKey`-backed private key) are NIOSSL types, and
                // NIOSSL reads PEM client keys into the in-memory PKCS#12 that `PEMIdentityImporter` builds.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                // WebSocket connections: a Posix client bootstrap, the HTTP/1.1 upgrade, frames, and TLS's handshake event.
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOTLS", package: "swift-nio"),
                .product(name: "MCP", package: "swift-sdk"),
                "ReqlingGraphQLEngine",
                "ReqlingYAML",
                "ReqlingTemplating",
                "ReqlingScriptProtocol"
            ],
            exclude: guidanceFiles(in: "Storage", "Templating", "HTTP", "TLS", "GRPC", "MCP", "Updates", "History", "GraphQL", "Scripting")
        ),
        // `{{variable}}` parsing, expansion, and precedence, Foundation only, so the script runner resolves templates
        // with the same code a run does.
        .target(name: "ReqlingTemplating", exclude: guidanceFiles(in: "")),
        // What the app and the script runner exchange, Foundation only like the runner itself.
        .target(name: "ReqlingScriptProtocol", dependencies: ["ReqlingTemplating"], exclude: guidanceFiles(in: "")),
        // GraphQLSwift behind Foundation types, imported implementation-only so its declarations never reach ReqlingKit
        // (`GraphQLEngine`); the feature has the compiler check that nothing public exposes them.
        .target(
            name: "ReqlingGraphQLEngine",
            dependencies: [.product(name: "GraphQL", package: "GraphQL")],
            swiftSettings: [.enableExperimentalFeature("CheckImplementationOnly")]
        ),
        // Yams behind Foundation types, imported implementation-only like `ReqlingGraphQLEngine`, so its extensions on
        // Foundation and standard library types never change how ReqlingKit type-checks.
        .target(
            name: "ReqlingYAML",
            dependencies: [.product(name: "Yams", package: "Yams")],
            swiftSettings: [.enableExperimentalFeature("CheckImplementationOnly")]
        ),
        .executableTarget(
            name: "Reqling",
            dependencies: [
                "ReqlingKit",
                "ReqlingTemplating",
                "ReqlingScriptProtocol",
                .product(name: "NeedleFoundation", package: "needle")
            ],
            exclude: guidanceFiles(in: "App", "DI", "Views", "Views/Settings", "ViewModels")
        ),
        // Foundation and Security only, so each launch stays fast.
        .executableTarget(name: "ReqlingPKCS12Probe"),
        // Foundation, JavaScriptCore, and CryptoKit only, so each launch stays fast. Its JavaScript runtime is copied
        // into the app by `scripts/build.sh` and read by path, not built as SwiftPM resources.
        .executableTarget(name: "ReqlingScriptRunner", dependencies: ["ReqlingScriptProtocol"], exclude: guidanceFiles(in: "") + ["Runtime"]),
        .testTarget(
            name: "ReqlingKitTests",
            dependencies: [
                "ReqlingKit",
                "ReqlingTemplating",
                "ReqlingScriptProtocol",
                "ReqlingYAML",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "CryptoExtras", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1"),
                .product(name: "GRPCReflectionService", package: "grpc-swift-extras"),
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                .product(name: "MCP", package: "swift-sdk"),
                // The oracle GraphQL suites check Reqling's analysis against.
                .product(name: "GraphQL", package: "GraphQL"),
                .product(name: "GraphQLFixtureServer", package: "GraphQLFixtureServer")
            ],
            resources: [.copy("GRPC/Fixtures"), .copy("GraphQL/GraphQLFixtures"), .copy("Import/PostmanFixtures")]
        ),
        .testTarget(
            name: "ReqlingTests",
            dependencies: [
                "Reqling",
                "ReqlingKit",
                "ReqlingTemplating",
                "ReqlingScriptProtocol",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            exclude: guidanceFiles(in: "Snapshots") + ["Snapshots/__Snapshots__"]
        )
    ]
)
