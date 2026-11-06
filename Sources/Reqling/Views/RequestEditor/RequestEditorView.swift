import ReqlingKit
import SwiftUI

/// The selected request: its editor above its latest response, or the run picked in its history.
struct RequestEditorView: View {
    let editor: RequestEditorViewModel
    let model: AppModel

    var body: some View {
        VSplitView {
            RequestEditorPane(editor: editor, model: model)
                .frame(minHeight: 240, idealHeight: 360)
            ResponseView(response: editor.response, model: model)
                .frame(minHeight: 180)
        }
        .modifier(RunHistoryPresentations(history: editor.history))
    }
}

struct RequestEditorPane: View {
    @Bindable var editor: RequestEditorViewModel
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RequestEditorURLBar(editor: editor)
                .disabled(editor.isReadOnly)
            if let note = editor.unavailableNote {
                RequestEditorNotice(text: note, systemImage: "exclamationmark.triangle", onDismiss: nil)
            }
            if let notice = editor.notice {
                RequestEditorNotice(text: notice, systemImage: "info.circle") { editor.notice = nil }
            }
            VStack(alignment: .leading, spacing: AppMetrics.sectionTabsSpacing) {
                // Left enabled, so a read-only request's sections stay browsable.
                SectionPicker("Section", selection: $editor.tab, options: RequestEditorTab.allCases, collapsesToMenu: true, label: \.rawValue)
                RequestEditorTabContent(editor: editor, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .disabled(editor.isReadOnly)
            }
        }
        .padding(.horizontal, AppMetrics.detailPaneInset)
        .padding(.vertical, AppMetrics.paneInset)
    }
}

/// A note above the request's sections; `onDismiss` is `nil` for one that lasts as long as its cause.
struct RequestEditorNotice: View {
    let text: String
    let systemImage: String
    let onDismiss: (() -> Void)?

    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(text)
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onDismiss {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(IconButtonStyle())
                .help("Dismiss")
                .accessibilityLabel("Dismiss")
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: AppMetrics.containerCornerRadius, style: .continuous).fill(Color.secondary.opacity(0.1)))
    }
}

/// The method menu, the URL, and Send. Pasting a cURL command into the URL replaces the whole request.
struct RequestEditorURLBar: View {
    @Bindable var editor: RequestEditorViewModel
    @State private var isEditingCustomMethod = false
    @State private var customMethod = ""

    var body: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(HTTPMethod.standard, id: \.self) { method in
                    Button(method.rawValue) { editor.setMethod(method) }
                }
                Divider()
                Button("Custom Method…") {
                    customMethod = editor.spec.method.isStandard ? "" : editor.spec.method.rawValue
                    isEditingCustomMethod = true
                }
            } label: {
                MethodBadge(method: editor.spec.method)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("HTTP method")
            .accessibilityLabel("HTTP method, \(editor.spec.method.rawValue)")
            .popover(isPresented: $isEditingCustomMethod) {
                CustomMethodPopover(method: $customMethod) {
                    editor.setMethod(HTTPMethod(rawValue: customMethod.trimmingCharacters(in: .whitespaces)))
                    isEditingCustomMethod = false
                }
            }

            TemplateField(
                text: $editor.urlText,
                placeholder: "https://api.example.com/{{path}}",
                tokenContext: editor.tokenContext,
                accessibilityLabel: "URL",
                onSubmit: { editor.send() },
                onPaste: { editor.importCurl($0) }
            )

            if editor.isSending {
                Button(editor.isStreaming ? "Stop" : "Cancel", role: .cancel) { editor.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button("Send") { editor.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .buttonStyle(.borderedProminent)
            }
        }
    }
}

private struct CustomMethodPopover: View {
    @Binding var method: String
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Custom method")
                .font(.headline)
            TextField("PURGE", text: $method)
                .textFieldStyle(.roundedBorder)
                .frame(width: 180)
                .onSubmit(commit)
            if !method.isEmpty, !HTTPMethod(rawValue: method).isValid {
                Text("Use letters, digits, and !#$%&'*+-.^_`|~ only.")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Use Method", action: commit)
                    .disabled(!HTTPMethod(rawValue: method).isValid)
            }
        }
        .padding(12)
    }

    private func commit() {
        if HTTPMethod(rawValue: method).isValid {
            onDone()
        }
    }
}
