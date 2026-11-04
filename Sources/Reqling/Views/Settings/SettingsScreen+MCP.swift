import ReqlingKit
import SwiftUI

/// The built-in MCP server: on or off, where it listens, its token, and how to connect Claude Code and Codex.
struct MCPSettingsPage: View {
    @Bindable var model: MCPSettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsScreenLayout.settingsSectionSpacing) {
            SettingsFormSection("Server") {
                SettingsToggleRow(
                    "Built-in MCP server",
                    helpText: "Agents connect over HTTP on this Mac only (127.0.0.1) and must send the token.",
                    isOn: Binding(get: { model.isEnabled }, set: { model.setEnabled($0) })
                )
                SettingsFormRow {
                    SettingsResponsiveControlRow("Status") {
                        MCPServerStatusView(status: model.server.status)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
                SettingsFormRow(showsDivider: false) {
                    SettingsResponsiveControlRow("Port", helpText: Self.portHelp, horizontalControlSizing: .intrinsic) {
                        MCPPortField(model: model)
                    }
                }
            }
            SettingsFormSection("Token") {
                SettingsFormRow(showsDivider: false) {
                    SettingsResponsiveControlRow("Bearer token", helpText: Self.tokenHelp) {
                        MCPTokenControls(model: model)
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                }
            }
            SettingsFormSection("Connect an agent") {
                SettingsFormRow {
                    MCPSetupSnippet(title: "Claude Code", text: model.claudeCommand(revealing: model.isTokenRevealed)) {
                        model.copyClaudeCommand()
                    }
                }
                SettingsFormRow(showsDivider: false) {
                    MCPSetupSnippet(title: "Codex", text: model.codexConfiguration(revealing: model.isTokenRevealed)) {
                        model.copyCodexConfiguration()
                    }
                }
            }
        }
        .task { model.loadToken() }
    }

    private static let portHelp =
        "\(AppSettings.mcpPortRange.lowerBound)–\(AppSettings.mcpPortRange.upperBound). Clients need the new URL after a change."

    private static let tokenHelp = "Every request must send it. Regenerating it disconnects agents until they use the new one."
}

private struct MCPServerStatusView: View {
    let status: MCPServerController.Status

    var body: some View {
        switch status {
        case .stopped:
            Text("Off")
                .foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 6) {
                ProgressView()
                    .controlSize(.small)
                Text("Starting…")
                    .foregroundStyle(.secondary)
            }
        case .running(let port):
            Label("Running on 127.0.0.1:\(String(port))", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .textSelection(.enabled)
        case .failed(let message):
            SettingsErrorLabel(message)
        }
    }
}

/// Saves on Return or when focus leaves, so a half-typed port never restarts the server.
private struct MCPPortField: View {
    @Bindable var model: MCPSettingsModel
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField("Port", text: $model.portDraft)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .monospacedDigit()
            .frame(width: 80)
            .focused($isFocused)
            .onSubmit { model.commitPort() }
            .onChange(of: isFocused) { _, focused in
                if !focused {
                    model.commitPort()
                }
            }
    }
}

private struct MCPTokenControls: View {
    @Bindable var model: MCPSettingsModel
    @State private var isConfirmingRegeneration = false

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 8) {
                Text(model.shownToken)
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                // The buttons keep their labels; only the token gives way when the row is narrow.
                Group {
                    Button(model.isTokenRevealed ? "Hide" : "Reveal") { model.isTokenRevealed.toggle() }
                    Button("Copy") { model.copyToken() }
                    Button("Regenerate…") { isConfirmingRegeneration = true }
                }
                .fixedSize()
            }
            .disabled(model.server.token == nil)
            if let error = model.tokenError {
                SettingsErrorLabel(error)
            }
        }
        .confirmationDialog("Regenerate the MCP token?", isPresented: $isConfirmingRegeneration) {
            Button("Regenerate", role: .destructive) { model.regenerateToken() }
        } message: {
            Text("Agents using the current token stop working until you give them the new one.")
        }
    }
}

private struct MCPSetupSnippet: View {
    let title: String
    let text: String
    let copy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Button("Copy", action: copy)
                    .help("Copy with the real token")
            }
            Text(text)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor))
                )
        }
    }
}
