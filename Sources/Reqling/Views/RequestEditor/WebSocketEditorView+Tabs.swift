import ReqlingKit
import SwiftUI

/// The selected section. Each disables its own editing for a read-only request, so the Messages tab keeps an open
/// connection's composer and Send buttons working.
struct WebSocketEditorTabContent: View {
    @Bindable var editor: WebSocketEditorViewModel
    let model: AppModel

    var body: some View {
        switch editor.tab {
        case .messages:
            WebSocketMessagesTab(editor: editor)
        case .params:
            ScrollView {
                KeyValueTable(rows: $editor.spec.queryParameters, rowName: "parameter", tokenContext: editor.tokenContext)
            }
            .detailPaneScrollMargins()
            .disabled(editor.isReadOnly)
        case .headers:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    KeyValueTable(rows: $editor.spec.headers, keyPlaceholder: "Header", rowName: "header", tokenContext: editor.tokenContext)
                    AutoHeadersList(
                        headers: editor.autoHeaders,
                        typedHeaders: editor.spec.headers,
                        isEnabled: { editor.spec.sends($0) },
                        onToggle: { editor.toggleAutoHeader($0, enabled: $1) },
                        ignoresTyped: { WebSocketRequestSpec.connectionHeaders.contains($0.key) },
                        fixedSetter: "the connection"
                    )
                }
            }
            .detailPaneScrollMargins()
            .disabled(editor.isReadOnly)
        case .auth:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    AuthEditor(
                        auth: $editor.spec.auth,
                        inheritedDescription: AuthEditor.inheritedDescription(for: editor.requestID, in: editor.projectID, model: model),
                        tokenContext: editor.tokenContext
                    )
                    LabeledRowNote(text: "Auth goes with the handshake, as an HTTP request's would; an API key can go in the query.")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(editor.isReadOnly)
        case .scripts:
            ScriptsPane(scripts: editor.scriptsEditor, isReadOnly: editor.isReadOnly) { link in
                model.openScripts(link, phase: editor.scriptsEditor.phase, in: editor.projectID)
            }
        case .options:
            WebSocketOptionsEditor(editor: editor, defaults: model.settings.settings.requestDefaults)
                .disabled(editor.isReadOnly)
        }
    }
}

/// The saved messages, and while the connection is open, the composer above them.
private struct WebSocketMessagesTab: View {
    @Bindable var editor: WebSocketEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if editor.isOpen {
                WebSocketLiveComposer(editor: editor)
                    .frame(minHeight: 150, maxHeight: 220)
            }
            WebSocketMessageList(editor: editor)
        }
    }
}

/// Every saved message, in the order the checked ones go out on connect; each can be sent while the connection is
/// open. Messages carry IDs, so rows write through `IdentifiedRowWriter`.
private struct WebSocketMessageList: View {
    @Bindable var editor: WebSocketEditorViewModel
    @State private var checkboxRange = CheckboxRange<WebSocketMessageID>()

    var body: some View {
        let messages = editor.spec.messages
        let isOpen = editor.isOpen
        let isReadOnly = editor.isReadOnly
        let tokenContext = editor.tokenContext
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if messages.isEmpty {
                    Text(isOpen ? "No saved messages. Save one from above to send it again later." : "No messages. Add one to send it on connect.")
                        .foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 8) {
                        Text("Send on connect:")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        CheckboxSelectionBar(rows: $editor.spec.messages, isOn: \.sendsOnConnect)
                            .disabled(isReadOnly)
                    }
                }
                ForEach(Array(messages.enumerated()), id: \.element.id) { index, message in
                    WebSocketMessageCard(
                        writer: IdentifiedRowWriter(rows: $editor.spec.messages, shown: message),
                        number: index + 1,
                        count: messages.count,
                        isOpen: isOpen,
                        isReadOnly: isReadOnly,
                        tokenContext: tokenContext,
                        onToggle: { checkboxRange.click(\.sendsOnConnect, to: $0, at: message.id, in: $editor.spec.messages) },
                        onSend: { editor.sendSaved(message) }
                    )
                }
                Button {
                    editor.addMessage()
                } label: {
                    Label("Add Message", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .disabled(isReadOnly)
                .help("Add a message to send after the others")
            }
        }
        .detailPaneScrollMargins()
    }
}

private struct WebSocketMessageCard: View {
    let writer: IdentifiedRowWriter<WebSocketMessage>
    let number: Int
    let count: Int
    let isOpen: Bool
    let isReadOnly: Bool
    let tokenContext: TemplateTokenContext
    /// Goes through the list rather than `writer`, since a Shift-click sets a range of messages.
    let onToggle: @MainActor (Bool) -> Void
    let onSend: () -> Void

    var body: some View {
        let message = writer.shown
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle("Send on connect", isOn: Binding(get: { message.sendsOnConnect }, set: { onToggle($0) }))
                    .toggleStyle(.checkbox)
                    .help("Send this message as soon as the connection opens, after the checked ones above it")
                    .disabled(isReadOnly)
                Text("Message \(number)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                WebSocketFormatPicker(format: writer.binding(\.format))
                    .disabled(isReadOnly)
                Spacer()
                Group {
                    Button { writer.move(by: -1) } label: { Image(systemName: "arrow.up") }
                        .help("Move this message up")
                        .accessibilityLabel("Move message \(number) up")
                        .disabled(number == 1)
                    Button { writer.move(by: 1) } label: { Image(systemName: "arrow.down") }
                        .help("Move this message down")
                        .accessibilityLabel("Move message \(number) down")
                        .disabled(number == count)
                    Button(action: writer.remove) { Image(systemName: "minus.circle") }
                        .help("Remove this message")
                        .accessibilityLabel("Remove message \(number)")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(isReadOnly)
                if isOpen {
                    Button("Send", action: onSend)
                        .help("Send this message on the open connection")
                }
            }
            WebSocketMessageEditor(
                message: writer.binding(\.text),
                format: message.format,
                tokenContext: tokenContext,
                accessibilityLabel: "Message \(number)"
            )
            .frame(height: 80)
            .disabled(isReadOnly)
        }
    }
}

/// A message's text, or for binary its base64; text that looks like JSON is highlighted as JSON.
private struct WebSocketMessageEditor: View {
    @Binding var message: String
    let format: WebSocketMessageFormat
    let tokenContext: TemplateTokenContext
    let accessibilityLabel: String
    @State private var handle = CodeEditorHandle()

    var body: some View {
        CodeEditor(
            text: $message,
            language: format == .text && Self.looksLikeJSON(message) ? .json : .plainText,
            placeholder: format == .text ? #"{"type": "subscribe", "channel": "{{channel}}"}"# : "Base64, such as aGVsbG8=",
            tokenContext: tokenContext,
            accessibilityLabel: accessibilityLabel,
            handle: handle
        )
        .editorChrome()
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        let first = text.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.contains($0) }
        return first == "{" || first == "["
    }
}

private struct WebSocketFormatPicker: View {
    @Binding var format: WebSocketMessageFormat

    var body: some View {
        Picker("Format", selection: $format) {
            Text("Text").tag(WebSocketMessageFormat.text)
            Text("Binary (base64)").tag(WebSocketMessageFormat.binary)
        }
        .labelsHidden()
        .fixedSize()
        .help("Text goes as UTF-8; binary is written as base64 and sent as its bytes")
    }
}

/// The next message for the open connection, then Ping, Save, and Send, which ⌘Return also does.
private struct WebSocketLiveComposer: View {
    @Bindable var editor: WebSocketEditorViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Connected", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(WebSocketBadge.color)
                WebSocketFormatPicker(format: $editor.liveMessage.format)
                Spacer()
                Button("Ping") { editor.ping() }
                    .help("Send a ping; its pong shows on the timeline with the round trip")
                Button("Save") { editor.saveLiveMessage() }
                    .disabled(editor.isReadOnly)
                    .help("Add this message to the request's saved messages")
                // The menu's Send routes here too while the connection is open, so ⌘Return never reconnects.
                Button("Send Message") { editor.sendLiveMessage() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            WebSocketMessageEditor(
                message: $editor.liveMessage.text,
                format: editor.liveMessage.format,
                tokenContext: editor.tokenContext,
                accessibilityLabel: "Next message"
            )
            .frame(minHeight: 48, maxHeight: .infinity)
            if let error = editor.liveError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius, style: .continuous)
                .fill(WebSocketBadge.color.opacity(0.08))
        )
    }
}

/// Subprotocols and per-request overrides of the defaults in Settings → Requests.
private struct WebSocketOptionsEditor: View {
    @Bindable var editor: WebSocketEditorViewModel
    let defaults: HTTPRequestDefaults

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledRow("Subprotocols") {
                TemplateField(
                    text: $editor.subprotocolsText,
                    placeholder: "chat, superchat",
                    tokenContext: editor.tokenContext,
                    accessibilityLabel: "Subprotocols"
                )
                .frame(maxWidth: 320)
            }
            LabeledRowNote(text: "Offered in order as Sec-WebSocket-Protocol; the server picks one or none.")
                .font(.caption)
            LabeledRow("Timeout") {
                SecondsField(
                    title: "Timeout",
                    seconds: $editor.spec.options.timeoutSeconds,
                    range: AppSettings.timeoutRange,
                    step: 5,
                    start: defaults.timeoutSeconds,
                    prompt: "Default (\(Int(defaults.timeoutSeconds)))"
                )
            }
            LabeledRowNote(text: "How long connecting may take. An open connection never times out.")
                .font(.caption)
            LabeledRow("Keepalive") {
                // The arrows start at 30 s, under the 60 s idle timeout common to proxies and load balancers.
                SecondsField(
                    title: "Keepalive",
                    seconds: $editor.spec.options.keepaliveSeconds,
                    range: WebSocketRequestOptions.keepaliveRange,
                    step: 5,
                    start: 30,
                    prompt: "Off"
                )
            }
            LabeledRowNote(text: "Seconds of silence before a ping, applied live to an open connection. A ping unanswered by the next ends it.")
                .font(.caption)
            LabeledRow("TLS") {
                Picker("Verify TLS certificates", selection: $editor.spec.options.verifyTLS) {
                    Text("Default (\(defaults.verifyTLS ? "Verify" : "Don't verify"))").tag(Bool?.none)
                    Text("Verify").tag(Bool?.some(true))
                    Text("Don't verify").tag(Bool?.some(false))
                }
                .labelsHidden()
                .fixedSize()
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}
