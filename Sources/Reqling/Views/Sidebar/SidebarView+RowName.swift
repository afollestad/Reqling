import AppKit
import SwiftUI

/// A sidebar row's name, renamed in place: while `AppModel.renaming` names the row, a field stands in for the label.
/// Return or clicking away saves, and Escape cancels. On the selected row, Return starts it.
struct SidebarRowName: View {
    let item: SidebarItem
    let name: String
    /// Semibold, as a project's name is.
    var isEmphasized = false
    let model: AppModel

    var body: some View {
        if model.renaming == item {
            SidebarRenameField(item: item, original: name, isEmphasized: isEmphasized, model: model)
                .id(model.renameSession)
        } else {
            Text(name)
                .fontWeight(isEmphasized ? .semibold : nil)
                .lineLimit(1)
                .background {
                    // Selection first, so only the selected row reads the library.
                    if model.selection == item, model.canRename(item) {
                        SidebarRenameKeyMonitor { model.beginRename(item) }
                    }
                }
        }
    }
}

/// Mounted fresh for each rename (`AppModel.renameSession`), so `draft` starts from the name even when SwiftUI rebuilds
/// the row mid-edit. Reports its end once, whichever comes first: Return, Escape, a click away, or the field going
/// (another rename began, or the row left the list).
private struct SidebarRenameField: View {
    /// How far the field's box reaches past its text, which stays where the label's was.
    private static let chromeInset: CGFloat = 4

    let item: SidebarItem
    let original: String
    let isEmphasized: Bool
    let model: AppModel
    @State private var draft: String
    @State private var hasEnded = false

    init(item: SidebarItem, original: String, isEmphasized: Bool, model: AppModel) {
        self.item = item
        self.original = original
        self.isEmphasized = isEmphasized
        self.model = model
        _draft = State(initialValue: original)
    }

    var body: some View {
        InlineRenameField(
            text: $draft,
            font: font,
            sizing: .fillsWidth,
            accessibilityLabel: "Name",
            onCommit: commit,
            onCancel: cancel
        )
        .padding(.horizontal, Self.chromeInset)
        .modifier(InlineRenameChrome())
        .padding(.leading, -Self.chromeInset)
        // Ahead of a project or folder row's spacer, so the field takes the width and the count stays put.
        .layoutPriority(1)
        // A field that goes mid-edit keeps what was typed, as clicking away does.
        .onDisappear(perform: commit)
    }

    /// The label's font, so the name does not shift as editing starts.
    private var font: NSFont {
        NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .body).pointSize, weight: isEmphasized ? .semibold : .regular)
    }

    private func commit() {
        end(with: InlineRenameField.committedName(draft, replacing: original))
    }

    private func cancel() {
        end(with: nil)
    }

    private func end(with name: String?) {
        guard !hasEnded else {
            return
        }
        hasEnded = true
        model.endRename(item, to: name)
    }
}
