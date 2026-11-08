import ReqlingKit
import ReqlingScriptProtocol
import SwiftUI

/// Edits a request's, folder's, or project's scripts, one phase at a time: whether the owner runs the scripts around
/// it, which of those run first (each a link to its scripts), and the script itself, with completion, hover, and its
/// problems (`ScriptsEditorModel+Assistant`), and a menu of snippets to insert (`ScriptsPaneSnippetMenu`). Read-only,
/// the phases and links stay browsable; only the script, the snippets, and the toggle take no edits.
struct ScriptsPane: View {
    @Bindable var scripts: ScriptsEditorModel
    let isReadOnly: Bool
    /// The run whose response `rq.response.json()` completes from; `nil` for a folder's or the project's scripts.
    var latestExchange: RequestExchange?
    let open: (ScriptsChainLink) -> Void
    @State private var handle = CodeEditorHandle()

    var body: some View {
        let diagnostics = scripts.diagnostics
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SectionPicker("Phase", selection: $scripts.phase, options: ScriptPhase.allCases) { $0.title }
                ScriptsPaneSnippetMenu(scripts: scripts, handle: handle)
                    .disabled(isReadOnly)
                Spacer(minLength: 0)
                if diagnostics.text == scripts.source, !diagnostics.items.isEmpty {
                    CodeProblemsMenu(diagnostics: diagnostics.items, handle: handle, subject: "the script")
                }
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
                placeholder: Self.placeholder(for: scripts.phase, kind: scripts.requestKind),
                showsTemplateTokens: false,
                accessibilityLabel: "\(scripts.phase.title) script",
                handle: handle,
                diagnostics: diagnostics,
                assistant: scripts
            )
            .editorChrome()
            // A fresh editor per phase, so undo never crosses from one script into the other.
            .id(scripts.phase)
            .disabled(isReadOnly)
        }
        .task(id: latestExchange?.id) {
            await scripts.loadResponseShape(from: latestExchange)
        }
    }

    /// `kind` is the request's; `nil` for a folder's or the project's scripts, which run for every kind.
    static func placeholder(for phase: ScriptPhase, kind: RequestKind.Name?) -> String {
        switch phase {
        case .preRequest:
            """
            // Runs before the request is sent, after any inherited scripts.
            rq.request.headers.upsert("X-Request-Time", new Date().toISOString())
            """
        case .stream:
            streamPlaceholder(for: kind)
        case .postResponse:
            """
            // Runs once the response is in, after any inherited scripts.
            rq.test("is quick", () => rq.expect(rq.response.responseTime).to.be.below(1000))
            """
        }
    }

    private static func streamPlaceholder(for kind: RequestKind.Name?) -> String {
        switch kind {
        case .http:
            """
            // Runs when the response is an event stream, after any inherited scripts; handlers take each event.
            rq.onEvent(event => rq.test("is JSON", () => event.json()))
            """
        case .webSocket:
            """
            // Runs once the connection opens, after any inherited scripts; handlers take each message received.
            rq.onMessage(message => rq.test("is JSON", () => message.json()))
            """
        case .grpc:
            """
            // Runs once the server answers, after any inherited scripts; handlers take each message received.
            rq.onMessage(message => rq.test("is JSON", () => message.json()))
            """
        case nil:
            """
            // Runs when an event stream, WebSocket connection, or gRPC call opens, after any inherited scripts.
            rq.onEvent(event => console.log(event.data))
            rq.onMessage(message => console.log(message.json()))
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
