import Foundation
import Observation
import ReqlingKit

/// Settings ▸ MCP: turning the server on, its port, its token, and the setup commands agents need.
@MainActor
@Observable
final class MCPSettingsModel {
    /// The port field's text, saved only by `commitPort()`, so a half-typed number never restarts the server.
    var portDraft: String
    var isTokenRevealed = false
    /// Why the token couldn't be read or replaced, shown under it.
    private(set) var tokenError: String?

    @ObservationIgnored let server: MCPServerController
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let system: any SystemIntegration

    init(server: MCPServerController, settings: SettingsStore, system: any SystemIntegration) {
        self.server = server
        self.settings = settings
        self.system = system
        portDraft = String(settings.settings.mcpPort)
    }

    var isEnabled: Bool {
        settings.settings.mcpEnabled
    }

    func setEnabled(_ enabled: Bool) {
        settings.update { $0.mcpEnabled = enabled }
        if enabled {
            loadToken()
        }
        server.sync()
    }

    /// Saves a valid port and restarts on it; anything else puts the saved port back in the field.
    func commitPort() {
        let trimmed = portDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(trimmed), AppSettings.mcpPortRange.contains(port) else {
            portDraft = String(settings.settings.mcpPort)
            return
        }
        portDraft = String(port)
        guard port != settings.settings.mcpPort else {
            return
        }
        settings.update { $0.mcpPort = port }
        server.sync()
    }

    // MARK: - Token

    func loadToken() {
        do {
            try server.loadToken()
            tokenError = nil
        } catch {
            tokenError = "Couldn't read the token from your Keychain: \(error.localizedDescription)"
        }
    }

    func regenerateToken() {
        do {
            try server.regenerateToken()
            tokenError = nil
        } catch {
            tokenError = "Couldn't save a new token to your Keychain: \(error.localizedDescription)"
        }
    }

    /// The token as the page shows it: masked until revealed.
    var shownToken: String {
        guard let token = server.token else {
            return ""
        }
        return isTokenRevealed ? token : String(repeating: "•", count: 12)
    }

    func copyToken() {
        if let token = server.token {
            system.copyToPasteboard(token)
        }
    }

    // MARK: - Setup commands

    /// `claude mcp add` for Claude Code, with the real token when copied and the shown one on the page.
    func claudeCommand(revealing: Bool) -> String {
        "claude mcp add --transport http \(MCPToolCatalog.serverName) \(endpoint) --header \"Authorization: Bearer \(token(revealing))\""
    }

    /// Codex reads the token from an environment variable rather than its config file, so the file holds no secret.
    func codexConfiguration(revealing: Bool) -> String {
        """
        # ~/.codex/config.toml
        [mcp_servers.\(MCPToolCatalog.serverName)]
        url = "\(endpoint)"
        bearer_token_env_var = "\(Self.codexTokenVariable)"

        # In the shell Codex runs from:
        export \(Self.codexTokenVariable)="\(token(revealing))"
        """
    }

    func copyClaudeCommand() {
        system.copyToPasteboard(claudeCommand(revealing: true))
    }

    func copyCodexConfiguration() {
        system.copyToPasteboard(codexConfiguration(revealing: true))
    }

    static let codexTokenVariable = "REQLING_MCP_TOKEN"

    private var endpoint: String {
        server.endpoint?.absoluteString ?? ""
    }

    private func token(_ revealing: Bool) -> String {
        revealing ? (server.token ?? "") : (server.token == nil ? "" : shownToken)
    }
}
