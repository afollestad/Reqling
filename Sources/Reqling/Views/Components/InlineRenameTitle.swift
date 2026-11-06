import AppKit
import SwiftUI

/// A title that renames in place, Finder-style: the pencil or a double-click swaps in a field, Return or clicking away
/// commits, and Escape cancels. An empty or unchanged name keeps the old one.
struct InlineRenameTitle: View {
    private static let font = Font.title3.weight(.semibold)
    /// `font` in AppKit's terms, for the field, so the name does not shift as editing starts.
    private static let fieldFont = NSFont.systemFont(ofSize: NSFont.preferredFont(forTextStyle: .title3).pointSize, weight: .semibold)
    private static let maxTitleWidth: CGFloat = 360

    let title: String
    let isRenamable: Bool
    let onRename: (String) -> Void

    /// The edit in progress; `nil` while not editing.
    @State private var editing: Editing?

    var body: some View {
        HStack(spacing: 6) {
            if editing != nil {
                field
            } else {
                label
                if isRenamable {
                    Button(action: beginEditing) {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(IconButtonStyle())
                    .help("Rename")
                    .accessibilityLabel("Rename \(title)")
                }
            }
        }
        .onDisappear(perform: commit)
    }

    private var label: some View {
        Text(title)
            .font(Self.font)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: Self.maxTitleWidth, alignment: .leading)
            .fixedSize(horizontal: true, vertical: false)
            .onTapGesture(count: 2) {
                if isRenamable {
                    beginEditing()
                }
            }
            .accessibilityAddTraits(.isHeader)
    }

    private var field: some View {
        InlineRenameField(
            text: Binding(get: { editing?.draft ?? "" }, set: { editing?.draft = $0 }),
            font: Self.fieldFont,
            accessibilityLabel: "Name",
            onCommit: commit,
            onCancel: cancel
        )
        .padding(.horizontal, 4)
        .modifier(InlineRenameChrome())
    }

    private func beginEditing() {
        editing = Editing(original: title, draft: title, onRename: onRename)
    }

    private func commit() {
        guard let editing else {
            return
        }
        self.editing = nil
        if let name = InlineRenameField.committedName(editing.draft, replacing: editing.original) {
            editing.onRename(name)
        }
    }

    private func cancel() {
        editing = nil
    }
}

/// The name and rename action as they were when editing began. The parent rebuilds `onRename` for whatever it shows
/// now, and an edit committed by clicking elsewhere (another sidebar item, say) must rename what it started on.
private struct Editing {
    let original: String
    var draft: String
    let onRename: (String) -> Void
}
