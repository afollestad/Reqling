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
        .executable(name: "Reqling", targets: ["Reqling"])
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
        // NIO and its TLS are used by the gRPC transport; tests also use them for loopback HTTP(S) servers, with
        // certificates minted at runtime.
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3"),
        // The built-in MCP server: protocol types, the server, and a stateless Streamable HTTP transport.
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", exact: "0.12.1")
    ],
    targets: [
        .target(
            name: "ReqlingKit",
            dependencies: [
                .product(name: "GRPCCore", package: "grpc-swift-2"),
                .product(name: "GRPCNIOTransportHTTP2", package: "grpc-swift-nio-transport"),
                .product(name: "GRPCProtobuf", package: "grpc-swift-protobuf"),
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
                // The gRPC executor's TLS hooks (trust callback, `SecKey`-backed private key) are NIOSSL types.
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            exclude: guidanceFiles(in: "Storage", "Templating", "HTTP", "TLS", "GRPC", "MCP")
        ),
        .executableTarget(
            name: "Reqling",
            dependencies: [
                "ReqlingKit",
                .product(name: "NeedleFoundation", package: "needle")
            ],
            exclude: guidanceFiles(in: "App", "DI", "Views", "Views/Settings", "ViewModels")
        ),
        .testTarget(
            name: "ReqlingKitTests",
            dependencies: [
                "ReqlingKit",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
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
                .product(name: "MCP", package: "swift-sdk")
            ],
            resources: [.copy("GRPC/Fixtures")]
        ),
        .testTarget(
            name: "ReqlingTests",
            dependencies: [
                "Reqling",
                "ReqlingKit",
                .product(name: "SnapshotTesting", package: "swift-snapshot-testing")
            ],
            exclude: guidanceFiles(in: "Snapshots") + ["Snapshots/__Snapshots__"]
        )
    ]
)
