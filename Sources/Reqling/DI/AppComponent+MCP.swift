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
            MCPServerController(
                context: MCPToolContext(
                    library: projectLibrary,
                    workspace: workspaceState,
                    runner: requestRunner,
                    settings: settingsStore,
                    protoWorkspaces: protoWorkspaces,
                    appInfo: appInfo
                ),
                settings: settingsStore,
                tokenStore: mcpTokenStore,
                bindPort: storageProfile.isEphemeral ? { _ in 0 } : { $0 }
            )
        }
    }
}
