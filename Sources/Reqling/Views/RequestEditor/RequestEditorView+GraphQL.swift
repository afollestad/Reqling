import ReqlingKit
import SwiftUI

/// A GraphQL operation: where its schema comes from, the query with completion, hover, and checking against that
/// schema, and the variables, sent together as the JSON body GraphQL servers expect.
struct GraphQLBodyEditor: View {
    @Bindable var editor: RequestEditorViewModel

    var body: some View {
        let tokenContext = editor.tokenContext
        VStack(alignment: .leading, spacing: 8) {
            // "Operation name" would wrap in the label column; the field keeps the full name for VoiceOver.
            LabeledRow("Operation") {
                TemplateField(
                    text: $editor.spec.body.graphQL.operationName,
                    placeholder: "Optional",
                    tokenContext: tokenContext,
                    accessibilityLabel: "Operation name"
                )
                    .frame(maxWidth: 260)
            }
            if let graphQL = editor.graphQL {
                GraphQLSchemaRow(editor: editor, schema: graphQL.schema, source: editor.spec.body.graphQL.schema)
            }
            HSplitView {
                GraphQLQueryPane(query: $editor.spec.body.graphQL.query, tokenContext: tokenContext, model: editor.graphQL)
                    .padding(.trailing, AppMetrics.splitPaneGap)
                    .frame(minWidth: 200)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 4) {
                        Text("Variables")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        AppHoverInfoIcon(
                            systemImage: "questionmark.circle",
                            accessibilityLabel: "How GraphQL variables work",
                            summary: GraphQLVariablesHelp.summary
                        ) {
                            GraphQLVariablesHelp()
                        }
                    }
                    .frame(height: GraphQLQueryPane.headerHeight)
                    CodeEditor(
                        text: $editor.spec.body.graphQL.variables,
                        language: .json,
                        placeholder: #"{ "id": "{{id}}" }"#,
                        tokenContext: tokenContext,
                        accessibilityLabel: "GraphQL variables"
                    )
                        .editorChrome()
                }
                .padding(.leading, AppMetrics.splitPaneGap)
                .frame(minWidth: 160)
            }
        }
    }
}

/// The query editor, with what its schema offers, and a menu of the problems it underlines. Its own view, so a new
/// set of problems re-renders only this pane.
struct GraphQLQueryPane: View {
    /// Both panes' captions sit at this height, so the problems menu beside Query does not push it out of line.
    static let headerHeight: CGFloat = 20

    @Binding var query: String
    let tokenContext: TemplateTokenContext
    let model: GraphQLEditorModel?
    @State private var handle = CodeEditorHandle()

    var body: some View {
        let diagnostics = model?.diagnostics ?? .none
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Query").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                // The underlines are only drawn; this lists the same problems for keyboard and VoiceOver users.
                if diagnostics.text == query, !diagnostics.items.isEmpty {
                    GraphQLProblemsMenu(diagnostics: diagnostics.items, handle: handle)
                }
            }
            .frame(height: Self.headerHeight)
            CodeEditor(
                text: $query,
                language: .graphQL,
                placeholder: "query { viewer { login } }",
                tokenContext: tokenContext,
                accessibilityLabel: "GraphQL query",
                handle: handle,
                diagnostics: diagnostics,
                assistant: model
            )
                .editorChrome()
        }
    }
}

/// The Variables caption's help: how a query declares and uses a variable, and how this pane gives its value.
struct GraphQLVariablesHelp: View {
    static let summary = """
        Declare a variable after the operation name, as in query Book($id: ID!), use it in the query as $id, and give \
        its value here as JSON, as in { "id": "{{bookId}}" }. Values can use the environment's {{variables}}.
        """

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Declare a variable after the operation name, use it in the query as `$name`, and give its value here as JSON.")
                .fixedSize(horizontal: false, vertical: true)
            GraphQLHelpSample(title: "Query", code: "query Book($id: ID!) {\n  book(id: $id) { title }\n}")
            GraphQLHelpSample(title: "Variables", code: #"{ "id": "{{bookId}}" }"#)
            Text("Values can use the environment's `{{variables}}`.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.callout)
        .frame(width: 300, alignment: .leading)
        .padding(14)
    }
}

/// A captioned, fixed code sample. Static text, not a `CodeViewerPane`: it is three lines that never change.
private struct GraphQLHelpSample: View {
    let title: String
    let code: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(code)
                .font(.system(.callout, design: .monospaced))
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AppMetrics.inputCornerRadius, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.4))
                )
        }
    }
}

/// "2 problems": each one, chosen, selects what it marks.
private struct GraphQLProblemsMenu: View {
    let diagnostics: [CodeDiagnostic]
    let handle: CodeEditorHandle

    var body: some View {
        let errors = diagnostics.filter { $0.severity == .error }.count
        let title = "\(diagnostics.count) problem\(diagnostics.count == 1 ? "" : "s")"
        Menu {
            ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                Button(diagnostic.message) {
                    handle.reveal(diagnostic.range)
                }
            }
        } label: {
            Label(title, systemImage: errors > 0 ? "xmark.octagon" : "exclamationmark.triangle")
        }
        .controlSize(.small)
        .fixedSize()
        .help("Show a problem in the query")
        .accessibilityLabel(title)
    }
}

/// Where the schema comes from, how loading it went, and a reload. `source` is passed in rather than read from
/// `editor.spec`, which every keystroke in the query changes.
private struct GraphQLSchemaRow: View {
    let editor: RequestEditorViewModel
    let schema: GraphQLSchemaLoader
    let source: GraphQLSchemaSource

    var body: some View {
        LabeledRow("Schema") {
            HStack(spacing: 8) {
                GraphQLSchemaSourceMenu(editor: editor)
                SchemaStatusLabel(state: Self.state(schema.status))
                Spacer(minLength: 0)
                Button {
                    editor.refreshGraphQLSchema()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(IconButtonStyle())
                .help(Self.reloadHelp(source))
                .accessibilityLabel("Reload the schema")
                Toggle(isOn: Binding(get: { editor.isShowingGraphQLSchema }, set: { editor.isShowingGraphQLSchema = $0 })) {
                    // Not `sidebar.trailing`: that is the toolbar's inspector toggle, which keeps the open panel.
                    Image(systemName: "list.bullet.rectangle")
                }
                .toggleStyle(IconToggleStyle())
                .help("Browse the schema in the inspector (⌥⌘0)")
                .accessibilityLabel("Browse the schema")
            }
        }
    }

    private static func reloadHelp(_ source: GraphQLSchemaSource) -> String {
        switch source {
        case .introspection: "Ask the server for its schema again"
        case .file: "Read the schema file again"
        }
    }

    static func state(_ status: GraphQLSchemaLoader.Status) -> SchemaStatusLabel.State {
        switch status {
        case .loading:
            return .loading
        case .idle(let message):
            return .idle(message)
        case .failed(let message):
            return .failed(message)
        case .ready(let source, let typeCount, let issue):
            let types = "\(typeCount) type\(typeCount == 1 ? "" : "s")"
            let summary = switch source {
            case .introspection(_, let fetchedAt): "\(types), introspected \(fetchedAt.formatted(.relative(presentation: .named)))"
            case .file(let name): "\(types) from \(name)"
            }
            return .ready(summary, issue: issue)
        }
    }
}

/// Introspection, or one schema file.
private struct GraphQLSchemaSourceMenu: View {
    let editor: RequestEditorViewModel

    var body: some View {
        let title = editor.graphQLSchemaSourceTitle
        Menu {
            Button {
                editor.setGraphQLSchemaSource(.introspection)
            } label: {
                if case .introspection = editor.spec.body.graphQL.schema {
                    Label("Introspection", systemImage: "checkmark")
                } else {
                    Text("Introspection")
                }
            }
            Divider()
            if case .file = editor.spec.body.graphQL.schema {
                Label(title, systemImage: "checkmark")
                Button("Choose Another Schema File…") { editor.chooseGraphQLSchemaFile() }
            } else {
                Button("Schema File…") { editor.chooseGraphQLSchemaFile() }
            }
        } label: {
            Text(title)
        }
        .fixedSize()
        .help("Where completion and checking read the schema: the server, by introspection, or a .graphql or .json file")
        .accessibilityLabel("Schema source")
        .accessibilityValue(title)
    }
}
