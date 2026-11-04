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
        .package(url: "https://github.com/pointfreeco/swift-snapshot-testing.git", exact: "1.19.2")
    ],
    targets: [
        .target(
            name: "ReqlingKit"
        ),
        .executableTarget(
            name: "Reqling",
            dependencies: [
                "ReqlingKit",
                .product(name: "NeedleFoundation", package: "needle")
            ],
            exclude: guidanceFiles(in: "App", "DI", "Views", "ViewModels")
        ),
        .testTarget(
            name: "ReqlingKitTests",
            dependencies: ["ReqlingKit"]
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
