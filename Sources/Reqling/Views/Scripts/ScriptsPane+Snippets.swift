import ReqlingKit
import SwiftUI

/// The icon menu beside the phase picker that inserts a snippet fitting the shown phase and the owner's kind
/// (`ScriptsEditorModel.snippetMenu`) at the editor's cursor. A folder's or the project's scripts list what differs by
/// protocol in a submenu per protocol.
struct ScriptsPaneSnippetMenu: View, Equatable {
    let scripts: ScriptsEditorModel
    let handle: CodeEditorHandle

    var body: some View {
        let menu = scripts.snippetMenu
        Menu {
            ForEach(menu.sections) { section in
                Section(section.group.title) {
                    snippetButtons(section.snippets)
                }
            }
            if !menu.byProtocol.isEmpty {
                Divider()
                ForEach(menu.byProtocol) { section in
                    Menu(section.kind.title) {
                        snippetButtons(section.snippets)
                    }
                }
            }
        } label: {
            Image(systemName: "text.badge.plus")
                .accessibilityLabel("Insert a snippet")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Insert a snippet")
        .accessibilityLabel("Insert a snippet")
        .iconButtonChrome()
    }

    private func snippetButtons(_ snippets: [ScriptSnippet]) -> some View {
        ForEach(snippets) { snippet in
            Button(snippet.title) {
                insert(snippet)
            }
        }
    }

    /// Writes the model only when there is no editor yet, as Beautify does; an editor that refuses must not be bypassed.
    private func insert(_ snippet: ScriptSnippet) {
        if !handle.insertLines(snippet.code, placeholder: snippet.placeholder, actionName: "Insert Snippet") {
            scripts.appendSnippet(snippet)
        }
    }

    /// Compares identities: the menu is read from `scripts` in `body`, so observation re-renders it when the phase
    /// changes, and another request's model or editor is a different object.
    nonisolated static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.scripts === rhs.scripts && lhs.handle === rhs.handle
    }
}
