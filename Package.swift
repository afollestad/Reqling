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
        // Test-only: loopback HTTP(S) servers and runtime-minted certificates for the TLS suites.
        .package(url: "https://github.com/apple/swift-nio.git", exact: "2.104.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", exact: "2.37.5"),
        .package(url: "https://github.com/apple/swift-certificates.git", exact: "1.21.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", exact: "5.0.3"),
        .package(url: "https://github.com/apple/swift-asn1.git", exact: "1.7.3")
    ],
    targets: [
        .target(
            name: "ReqlingKit",
            exclude: guidanceFiles(in: "Storage", "Templating", "HTTP", "TLS")
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
                .product(name: "SwiftASN1", package: "swift-asn1")
            ]
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
