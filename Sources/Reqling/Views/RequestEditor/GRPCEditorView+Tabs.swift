import ReqlingKit
import SwiftUI

/// The selected section. Each disables its own editing for a read-only request, so the Messages tab can keep an open
/// call's composer working.
struct GRPCEditorTabContent: View {
    @Bindable var editor: GRPCEditorViewModel
    let model: AppModel

    var body: some View {
        if editor.tab == .messages {
            GRPCMessagesEditor(editor: editor)
        } else {
            GRPCEditorSettingsTab(editor: editor, model: model)
                .disabled(editor.isReadOnly)
        }
    }
}

/// Metadata, Auth, and Options.
private struct GRPCEditorSettingsTab: View {
    @Bindable var editor: GRPCEditorViewModel
    let model: AppModel

    var body: some View {
        switch editor.tab {
        case .messages:
            EmptyView()
        case .metadata:
            ScrollView {
                KeyValueTable(rows: $editor.spec.metadata, rowName: "metadata", tokenContext: editor.tokenContext)
            }
            .detailPaneScrollMargins()
        case .auth:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    AuthEditor(
                        auth: $editor.spec.auth,
                        inheritedDescription: AuthEditor.inheritedDescription(for: editor.requestID, in: editor.projectID, model: model),
                        tokenContext: editor.tokenContext
                    )
                    LabeledRowNote(text: "gRPC sends credentials as metadata, so an API key must go in a header.")
                        .font(.caption)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .options:
            GRPCOptionsEditor(
                deadlineSeconds: $editor.spec.deadlineSeconds,
                verifyTLS: $editor.spec.verifyTLS,
                defaults: model.settings.settings,
                usesTLS: editor.spec.security == .tls,
                isInteractive: editor.isInteractive
            )
        }
    }
}

/// The message a call sends, or, when the method streams from the client, every message in order. An open call shows
/// only its composer instead: the saved messages were already sent, and stacking both overflows the editor pane. The
/// composer stays usable in a read-only request, so an open call can still be finished.
private struct GRPCMessagesEditor: View {
    @Bindable var editor: GRPCEditorViewModel

    var body: some View {
        if editor.isStreamOpen {
            GRPCLiveMessageComposer(editor: editor)
        } else if editor.listsMessages {
            GRPCMessageList(editor: editor)
                .disabled(editor.isReadOnly)
        } else {
            GRPCSingleMessageEditor(editor: editor)
                .disabled(editor.isReadOnly)
        }
    }
}

private struct GRPCSingleMessageEditor: View {
    @Bindable var editor: GRPCEditorViewModel
    @State private var handle = CodeEditorHandle()

    var body: some View {
        let example = editor.exampleMessage
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(editor.selectedMethod.map { "\($0.inputType) as proto3 JSON" } ?? "The request message as proto3 JSON")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                GRPCExampleButton(example: example, handle: handle) { editor.fillExample(at: 0) }
            }
            CodeEditor(
                text: $editor.firstMessage,
                language: .json,
                placeholder: #"{ "name": "{{name}}" }"#,
                tokenContext: editor.tokenContext,
                accessibilityLabel: "Request message",
                handle: handle
            )
            .editorChrome()
        }
    }
}

/// Every message a client-streaming or bidirectional call sends, in order. Messages have no identity of their own, so
/// rows are keyed by view-local `RowIdentities` and write through `IndexedRowWriter`.
private struct GRPCMessageList: View {
    @Bindable var editor: GRPCEditorViewModel
    @State private var identities = RowIdentities()

    var body: some View {
        let messages = editor.spec.messages
        let example = editor.exampleMessage
        let tokenContext = editor.tokenContext
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(IdentifiedRow.rows(identities.ids(count: messages.count))) { slot in
                    GRPCMessageCard(
                        writer: IndexedRowWriter(rows: $editor.spec.messages, index: slot.index, shown: messages[slot.index], identities: identities),
                        number: slot.index + 1,
                        canRemove: messages.count > 1,
                        example: example,
                        tokenContext: tokenContext
                    )
                }
                Button {
                    identities.rowWasAppended()
                    editor.addMessage()
                } label: {
                    Label("Add Message", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .help("Add a message to send after the others")
            }
        }
        .detailPaneScrollMargins()
    }
}

private struct GRPCMessageCard: View {
    let writer: IndexedRowWriter<String>
    let number: Int
    let canRemove: Bool
    let example: String?
    let tokenContext: TemplateTokenContext
    @State private var handle = CodeEditorHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Message \(number)")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                GRPCExampleButton(example: example, handle: handle) {
                    if let example {
                        writer.edit { $0 = example }
                    }
                }
                Button(action: writer.remove) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(IconButtonStyle())
                .disabled(!canRemove)
                .help("Remove this message")
                .accessibilityLabel("Remove message \(number)")
            }
            CodeEditor(
                text: writer.binding(\.self),
                language: .json,
                placeholder: "{}",
                tokenContext: tokenContext,
                accessibilityLabel: "Message \(number)",
                handle: handle
            )
            .editorChrome()
            .frame(height: 96)
        }
    }
}

/// More messages for an open call, then End Stream to let the server finish.
private struct GRPCLiveMessageComposer: View {
    @Bindable var editor: GRPCEditorViewModel
    @State private var handle = CodeEditorHandle()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Stream open", systemImage: "dot.radiowaves.left.and.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GRPCBadge.color)
                Text("Messages sent here aren't saved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                GRPCExampleButton(example: editor.exampleMessage, handle: handle) {
                    if let example = editor.exampleMessage {
                        editor.liveMessage = example
                    }
                }
                Button("End Stream") { editor.endStream() }
                    .help("Close the request stream, so the server can finish the call")
                // The menu's Send routes here too while the stream is open, so ⌘Return never restarts the call.
                Button("Send Message") { editor.sendLiveMessage() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
            CodeEditor(
                text: $editor.liveMessage,
                language: .json,
                placeholder: "{}",
                tokenContext: editor.tokenContext,
                accessibilityLabel: "Next message",
                handle: handle
            )
            .editorChrome()
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
                .fill(GRPCBadge.color.opacity(0.08))
        )
    }
}

/// Replaces a message with the method's Example as one undoable edit; `fallback` writes the model when the editor has
/// no text view yet.
private struct GRPCExampleButton: View {
    let example: String?
    let handle: CodeEditorHandle
    let fallback: () -> Void

    var body: some View {
        Button("Example") {
            if let example, !handle.replaceAll(with: example, actionName: "Example") {
                fallback()
            }
        }
        .disabled(example == nil)
        .help(example == nil ? "Choose a method to fill in its message" : "Replace this message with every field at a placeholder value")
    }
}

/// Per-request overrides of the gRPC defaults in Settings.
private struct GRPCOptionsEditor: View {
    @Binding var deadlineSeconds: Double?
    @Binding var verifyTLS: Bool?
    let defaults: AppSettings
    let usesTLS: Bool
    /// The picked method streams from the client, so a call sent from here stays open and gets no default deadline.
    let isInteractive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledRow("Deadline") {
                SecondsField(
                    title: "Deadline",
                    seconds: $deadlineSeconds,
                    range: AppSettings.timeoutRange,
                    step: 5,
                    start: defaults.grpcDeadlineSeconds,
                    prompt: isInteractive ? "None" : "Default (\(Int(defaults.grpcDeadlineSeconds)))"
                )
            }
            if isInteractive {
                LabeledRowNote(text: "The stream stays open until you end it, so the Settings default doesn't apply; set seconds to add one.")
                    .font(.caption)
            }
            LabeledRow("TLS") {
                Picker("Verify TLS certificates", selection: $verifyTLS) {
                    Text("Default (\(defaults.verifyTLS ? "Verify" : "Don't verify"))").tag(Bool?.none)
                    Text("Verify").tag(Bool?.some(true))
                    Text("Don't verify").tag(Bool?.some(false))
                }
                .labelsHidden()
                .fixedSize()
            }
            if !usesTLS {
                LabeledRowNote(text: "Applies only when TLS is on.")
                    .font(.caption)
            }
        }
        .frame(maxWidth: 520, alignment: .leading)
    }
}
