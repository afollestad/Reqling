import Foundation
import ReqlingKit

/// The snippet menu above the script: what fits the shown phase and the owner's kind, as completion offers the API.
extension ScriptsEditorModel {
    var snippetMenu: ScriptSnippetMenu {
        ScriptSnippets.menu(for: phase, kind: requestKind)
    }

    /// Adds `snippet` on its own line after the script, for when no editor is there to insert it at the cursor
    /// (`CodeEditorHandle.insertLines`), as Beautify writes the model then.
    func appendSnippet(_ snippet: ScriptSnippet) {
        let end = NSRange(location: (source as NSString).length, length: 0)
        let insertion = CodeIndent.insertion(of: snippet.code, placeholder: snippet.placeholder, in: source, selection: end, language: .javascript)
        source = (source as NSString).replacingCharacters(in: insertion.range, with: insertion.replacement)
    }
}
