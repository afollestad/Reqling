import ReqlingKit
import SwiftUI

/// The selected WebSocket request: its editor above its connection, live while it is open, or the run picked in its
/// history.
struct WebSocketEditorView: View {
    let editor: WebSocketEditorViewModel
    let model: AppModel

    var body: some View {
        VSplitView {
            WebSocketEditorPane(editor: editor, model: model)
                .frame(minHeight: 300, idealHeight: 400)
            WebSocketResponseView(response: editor.response)
                .frame(minHeight: 180)
        }
        .modifier(RunHistoryPresentations(history: editor.history))
    }
}

struct WebSocketEditorPane: View {
    @Bindable var editor: WebSocketEditorViewModel
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Disables its own editing parts: Disconnect and Ping must work in a read-only project.
            WebSocketURLBar(editor: editor)
            if let note = editor.unavailableNote {
                RequestEditorNotice(text: note, systemImage: "exclamationmark.triangle", onDismiss: nil)
            }
            if let notice = editor.notice {
                RequestEditorNotice(text: notice, systemImage: "info.circle") { editor.notice = nil }
            }
            VStack(alignment: .leading, spacing: AppMetrics.sectionTabsSpacing) {
                // Left enabled, so a read-only request's sections stay browsable.
                SectionPicker("Section", selection: $editor.tab, options: WebSocketEditorTab.allCases, collapsesToMenu: true) { $0.rawValue }
                // Disables its own editing parts: an open connection's composer must work in a read-only project.
                WebSocketEditorTabContent(editor: editor, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, AppMetrics.detailPaneInset)
        .padding(.vertical, AppMetrics.paneInset)
    }
}

/// The URL and Connect, which reads Disconnect while the connection is open and Cancel while it connects or closes. An
/// edit made while connected applies to the next connection. A read-only request disables the URL and Connect, never
/// Disconnect.
struct WebSocketURLBar: View {
    @Bindable var editor: WebSocketEditorViewModel

    var body: some View {
        HStack(spacing: 8) {
            WebSocketBadge()
                .padding(.horizontal, 4)
            TemplateField(
                text: $editor.urlText,
                placeholder: "wss://echo.example.com/{{path}}",
                tokenContext: editor.tokenContext,
                accessibilityLabel: "URL",
                onSubmit: { editor.send() }
            )
            .disabled(editor.isReadOnly)

            if editor.isSending {
                Button(editor.isOpen ? "Disconnect" : "Cancel", role: .cancel) { editor.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
                    .help(editor.isOpen ? "Close the connection with 1000 Normal Closure" : "Stop connecting")
            } else {
                Button("Connect") { editor.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
                    .disabled(editor.isReadOnly)
            }
        }
    }
}
