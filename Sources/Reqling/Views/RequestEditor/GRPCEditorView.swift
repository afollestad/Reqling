import ReqlingKit
import SwiftUI

/// The selected gRPC request: its editor above its latest call.
struct GRPCEditorView: View {
    let editor: GRPCEditorViewModel
    let model: AppModel

    var body: some View {
        VSplitView {
            GRPCEditorPane(editor: editor, model: model)
                .frame(minHeight: 300, idealHeight: 400)
            GRPCResponseView(response: editor.response)
                .frame(minHeight: 180)
        }
    }
}

struct GRPCEditorPane: View {
    @Bindable var editor: GRPCEditorViewModel
    let model: AppModel

    var body: some View {
        let listsMessages = editor.listsMessages
        VStack(alignment: .leading, spacing: 12) {
            // Disables its own editing parts: an open call's Cancel must work in a read-only project.
            GRPCTargetBar(editor: editor)
            GRPCMethodRows(editor: editor)
                .disabled(editor.isReadOnly)
            if let note = editor.unavailableNote {
                RequestEditorNotice(text: note, systemImage: "exclamationmark.triangle", onDismiss: nil)
            }
            VStack(alignment: .leading, spacing: AppMetrics.sectionTabsSpacing) {
                // Left enabled, so a read-only request's sections stay browsable.
                SectionPicker("Section", selection: $editor.tab, options: GRPCEditorTab.allCases) { tab in
                    Self.title(for: tab, listsMessages: listsMessages)
                }
                // Disables its own editing parts: an open call's composer must work in a read-only project.
                GRPCEditorTabContent(editor: editor, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, AppMetrics.detailPaneInset)
        .padding(.vertical, AppMetrics.paneInset)
    }

    static func title(for tab: GRPCEditorTab, listsMessages: Bool) -> String {
        switch tab {
        case .messages: listsMessages ? "Messages" : "Message"
        case .metadata: "Metadata"
        case .auth: "Auth"
        case .options: "Options"
        }
    }
}

/// TLS, the target, and Send. The target is a template, so it can come from an environment (`{{grpcHost}}`). A
/// read-only request disables all but Cancel, which an open call still needs.
struct GRPCTargetBar: View {
    @Bindable var editor: GRPCEditorViewModel

    var body: some View {
        let usesTLS = editor.spec.security == .tls
        let isReadOnly = editor.isReadOnly
        HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { usesTLS }, set: { editor.setTLS($0) })) {
                Label("TLS", systemImage: usesTLS ? "lock.fill" : "lock.open")
            }
            .toggleStyle(.button)
            .fixedSize()
            .help(usesTLS ? "Connects with TLS; turn off to connect in plaintext" : "Connects in plaintext; turn on to use TLS")
            .accessibilityLabel("TLS")
            .accessibilityValue(usesTLS ? "On" : "Off")
            .disabled(isReadOnly)

            TemplateField(
                text: $editor.spec.target,
                placeholder: "localhost:50051",
                tokenContext: editor.tokenContext,
                accessibilityLabel: "Target",
                onSubmit: { editor.send() }
            )
            .disabled(isReadOnly)

            if editor.isSending {
                Button("Cancel", role: .cancel) { editor.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Send") { editor.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(isReadOnly)
            }
        }
    }
}
