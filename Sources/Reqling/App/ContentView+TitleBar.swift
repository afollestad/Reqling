import ReqlingKit
import SwiftUI

/// The window's visible title, in the toolbar's leading slot: the shown detail's name, renamed in place, and for a
/// request its protocol. Detail screens therefore carry no title of their own.
struct DetailTitleBar: View {
    /// macOS already insets a `.navigation` item this far from the detail column's edge; the rest of
    /// `AppMetrics.detailPaneInset` is padding, so the title lines up with the request editor below it.
    private static let systemLeadingInset: CGFloat = 5

    let model: AppModel

    var body: some View {
        let title = model.detailTitle
        HStack(spacing: 10) {
            InlineRenameTitle(title: title.text, isRenamable: title.isRenamable) { [subject = title.subject] name in
                model.rename(subject, to: name)
            }
            // A new subject starts with a fresh label; an edit in progress commits to its own subject as it goes.
            .id(title.subject)
            if let editor = model.editor?.editing, title.subject == .node(editor.projectID, editor.requestID) {
                RequestProtocolPicker(editor: editor, model: model)
                if editor.isReadOnly {
                    Label("Read-only", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(editor.unavailableNote == nil
                            ? "This project was saved by a newer version of Reqling."
                            : "This project isn't available right now.")
                }
            }
        }
        .padding(.leading, AppMetrics.detailPaneInset - Self.systemLeadingInset)
    }
}

/// Switches the request between its protocols; `AppModel.changeKind(of:in:to:)` asks first when that discards anything.
///
/// A menu picker takes its widest option's width, which left "HTTP" trailed by room for "WebSocket". So a hidden copy
/// holding only the shown protocol sets the size, and the real picker fills it.
private struct RequestProtocolPicker: View {
    let editor: any RequestEditing
    let model: AppModel

    var body: some View {
        picker(of: [editor.kind])
            .fixedSize()
            .hidden()
            .overlay {
                picker(of: RequestKind.Name.allCases)
            }
            .disabled(editor.isReadOnly || editor.isSending)
            .help(editor.isSending ? "Wait for the request to finish, or cancel it, to change its protocol" : "The protocol this request speaks")
    }

    private func picker(of kinds: [RequestKind.Name]) -> some View {
        Picker("Protocol", selection: Binding(
            get: { editor.kind },
            set: { model.changeKind(of: editor.requestID, in: editor.projectID, to: $0) }
        )) {
            ForEach(kinds, id: \.self) { kind in
                Text(kind.title)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}
