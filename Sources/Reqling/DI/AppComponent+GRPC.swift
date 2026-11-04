import Foundation
import ReqlingKit

/// gRPC tooling: finding and installing protoc, every project's compiled protos, and the schema service the editor
/// and runner share. An ephemeral (test) profile confines protoc discovery to its own `Tools` folder and turns off
/// file watching, so a test graph never runs the developer's Homebrew protoc or recompiles on their edits.
@MainActor
extension AppComponent {
    var protocLocator: ProtocLocator {
        shared {
            let tools = storageProfile.toolsDirectory
            if storageProfile.isEphemeral {
                return ProtocLocator(toolsDirectory: tools, fileSystem: ConfinedProtocFileSystem(root: tools), environment: [:])
            }
            return ProtocLocator(toolsDirectory: tools)
        }
    }

    var protocInstaller: ProtocInstaller {
        shared { ProtocInstaller(toolsDirectory: storageProfile.toolsDirectory) }
    }

    var protoWorkspaces: ProtoWorkspaceStore {
        shared { ProtoWorkspaceStore(environment: protoWorkspaceEnvironment) }
    }

    var grpcSchema: GRPCSchemaService {
        shared { GRPCSchemaService(workspaces: protoWorkspaces) }
    }

    var systemIntegration: any SystemIntegration {
        shared { AppKitSystemIntegration() as any SystemIntegration }
    }

    var protocTooling: ProtocToolingModel {
        shared {
            let workspaces = protoWorkspaces
            return ProtocToolingModel(
                locator: protocLocator,
                installer: protocInstaller,
                settings: settingsStore,
                system: systemIntegration,
                recompileWorkspaces: { workspaces.recompileAll() }
            )
        }
    }

    /// Reads the Settings override at each compile, so editing it needs only `recompileAll()`, never new workspaces.
    private var protoWorkspaceEnvironment: ProtoWorkspaceEnvironment {
        let settings = settingsStore
        let protocPath: @MainActor @Sendable () -> String? = { settings.settings.protocPath }
        guard storageProfile.isEphemeral else {
            return .live(
                toolsDirectory: storageProfile.toolsDirectory,
                cacheDirectory: storageProfile.protocCacheDirectory,
                protocPath: protocPath
            )
        }
        let locator = protocLocator
        return ProtoWorkspaceEnvironment(
            importer: ProtocImporter(cacheDirectory: storageProfile.protocCacheDirectory),
            locateProtoc: { try await locator.locate(overridePath: await protocPath()) },
            changes: { _ in AsyncStream { $0.finish() } }
        )
    }
}

/// The local file system, but blind outside `root`: an ephemeral graph's `ProtocLocator` then finds only a protoc
/// installed into its own `Tools` folder, never one at the fixed Homebrew paths it always checks.
struct ConfinedProtocFileSystem: ProtocFileSystem {
    let root: URL
    private let base = LocalProtocFileSystem()

    init(root: URL) {
        self.root = root
    }

    func isExecutableFile(atPath path: String) -> Bool {
        contains(path) && base.isExecutableFile(atPath: path)
    }

    func fileExists(atPath path: String) -> Bool {
        contains(path) && base.fileExists(atPath: path)
    }

    func contentsOfDirectory(atPath path: String) -> [String] {
        contains(path) ? base.contentsOfDirectory(atPath: path) : []
    }

    func resolvingSymlinks(inPath path: String) -> String {
        base.resolvingSymlinks(inPath: path)
    }

    private func contains(_ path: String) -> Bool {
        let rootPath = root.standardizedFileURL.path
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        return target == rootPath || target.hasPrefix(rootPath + "/")
    }
}
