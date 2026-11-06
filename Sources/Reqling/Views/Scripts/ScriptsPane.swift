import ReqlingKit
import ReqlingScriptProtocol
import SwiftUI

/// Edits a request's, folder's, or project's scripts, one phase at a time: whether the owner runs the scripts around
/// it, which of those run first (each a link to its scripts), and the script itself. Read-only, the phases and links
/// stay browsable; only the script and the toggle take no edits.
struct ScriptsPane: View {
    @Bindable var scripts: ScriptsEditorModel
    let isReadOnly: Bool
    let open: (ScriptsChainLink) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SectionPicker("Phase", selection: $scripts.phase, options: ScriptPhase.allCases) { $0.title }
                Spacer(minLength: 0)
                if scripts.canInherit {
                    ScriptsPaneInheritToggle(scripts: scripts)
                        .disabled(isReadOnly)
                }
            }
            let links = scripts.alsoRuns
            if !links.isEmpty {
                ScriptsPaneAlsoRuns(links: links, open: open)
            }
            CodeEditor(
                text: $scripts.source,
                language: .javascript,
                placeholder: Self.placeholder(for: scripts.phase),
                showsTemplateTokens: false,
                accessibilityLabel: "\(scripts.phase.title) script"
            )
            .editorChrome()
            // A fresh editor per phase, so undo never crosses from one script into the other.
            .id(scripts.phase)
            .disabled(isReadOnly)
        }
    }

    static func placeholder(for phase: ScriptPhase) -> String {
        switch phase {
        case .preRequest:
            """
            // Runs before the request is sent, after any inherited scripts.
            rq.request.headers.upsert("X-Request-Time", new Date().toISOString())
            """
        case .postResponse:
            """
            // Runs once the response is in, after any inherited scripts.
            rq.test("is quick", () => rq.expect(rq.response.responseTime).to.be.below(1000))
            """
        }
    }
}

/// Whether the owner runs the project's and its folders' scripts first.
private struct ScriptsPaneInheritToggle: View {
    let scripts: ScriptsEditorModel

    var body: some View {
        HStack(spacing: 4) {
            Toggle("Run inherited scripts", isOn: Binding(
                get: { scripts.runsInheritedScripts },
                set: { scripts.setRunsInheritedScripts($0) }
            ))
            .toggleStyle(.checkbox)
            AppHoverInfoIcon(text: help)
        }
        .fixedSize()
    }

    private var help: String {
        if case .folder = scripts.owner {
            return "Runs the project's and enclosing folders' scripts before this folder's. Off, requests inside run this "
                + "folder's scripts and those below it, but none above."
        }
        return "Runs the project's and enclosing folders' scripts before this request's. Off, only its own run."
    }
}
