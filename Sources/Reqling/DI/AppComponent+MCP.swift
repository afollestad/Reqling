import ReqlingKit

/// The built-in MCP server. Its tools act through the same stores as the window; an ephemeral (test) profile keeps
/// the token in memory and binds port 0, so a test graph never touches the Keychain or a fixed port.
@MainActor
extension AppComponent {
    var mcpTokenStore: any MCPTokenStore {
        shared {
            if storageProfile.isEphemeral {
                return InMemoryMCPTokenStore() as any MCPTokenStore
            }
            #if DEBUG
            if let harness {
                return InMemoryMCPTokenStore(token: harness.token) as any MCPTokenStore
            }
            #endif
            return KeychainMCPTokenStore(service: "\(keychainNamespace).mcp")
        }
    }

    var mcpServer: MCPServerController {
        shared {
            let context = MCPToolContext(
                library: projectLibrary,
                workspace: workspaceState,
                runner: requestRunner,
                batches: batchRunner,
                settings: settingsStore,
                protoWorkspaces: protoWorkspaces,
                appInfo: appInfo
            )
            context.updates = appUpdates
            context.sync = librarySync
            #if DEBUG
            if harness != nil {
                context.probe = CloudKitProbe(containerIdentifier: SyncAvailability.containerIdentifier)
                if let librarySync {
                    context.sharingHarness = SharingHarness(
                        containerIdentifier: SyncAvailability.containerIdentifier,
                        sync: librarySync,
                        library: projectLibrary
                    )
                }
            }
            #endif
            return MCPServerController(
                context: context,
                settings: settingsStore,
                tokenStore: mcpTokenStore,
                bindPort: storageProfile.isEphemeral ? { _ in 0 } : { $0 }
            )
        }
    }
}
