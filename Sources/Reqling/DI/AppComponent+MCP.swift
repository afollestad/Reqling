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
            return KeychainMCPTokenStore(service: "\(appInfo.bundleIdentifier).mcp")
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
            return MCPServerController(
                context: context,
                settings: settingsStore,
                tokenStore: mcpTokenStore,
                bindPort: storageProfile.isEphemeral ? { _ in 0 } : { $0 }
            )
        }
    }
}
