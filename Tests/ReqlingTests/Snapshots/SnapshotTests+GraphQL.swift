import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// GraphQL editing: the body editor with its schema row and the problems it underlines, the schema status, and the
/// completion list and hover card, rendered as their panels hold them but never shown.
extension SnapshotTests {
    /// A misspelled field underlined as an error and a deprecated one as a warning, with the problems menu above.
    func testGraphQLEditorChecksTheQueryAgainstItsSchemaFile() async throws {
        let editor = try await graphQLEditor(query: "query User($id: ID!) {\n  user(id: $id) {\n    name\n    nmae\n    nickname\n  }\n}")

        assertBothAppearances(RequestEditorPane(editor: editor, model: fixture.model), size: CGSize(width: 920, height: 380))
    }

    func testSchemaStatusLabelStates() {
        let states: [SchemaStatusLabel.State] = [
            .loading,
            .idle("Enter the URL to read its schema by introspection, or choose a schema file."),
            .ready("142 types, introspected 3 days ago", issue: nil),
            .ready("142 types, introspected 3 days ago", issue: "Refreshing failed, so this is the schema from before."),
            .failed("The server answered 401 Unauthorized: Bad token.")
        ]
        let view = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(states.enumerated()), id: \.offset) { _, state in
                SchemaStatusLabel(state: state).frame(width: 520, alignment: .leading)
            }
        }
        .padding(12)

        assertBothAppearances(view, size: CGSize(width: 544, height: 170))
    }

    func testCompletionList() {
        let model = CodeCompletionModel()
        model.items = [
            CodeCompletionItem(id: 0, label: "books", kind: .field, detail: "[Book!]!", summary: nil, isDeprecated: false, insertText: "books"),
            CodeCompletionItem(
                id: 1, label: "book", kind: .field, detail: "Book", summary: "One book, by ID or ISBN.", isDeprecated: false, insertText: "book"
            ),
            CodeCompletionItem(id: 2, label: "first", kind: .argument, detail: "Int = 20", summary: nil, isDeprecated: false, insertText: "first"),
            CodeCompletionItem(id: 3, label: "POETRY", kind: .enumValue, detail: "Genre", summary: nil, isDeprecated: false, insertText: "POETRY"),
            CodeCompletionItem(id: 4, label: "$id", kind: .variable, detail: "ID!", summary: nil, isDeprecated: false, insertText: "$id"),
            CodeCompletionItem(id: 5, label: "nickname", kind: .field, detail: "String", summary: nil, isDeprecated: true, insertText: "nickname")
        ]
        model.highlighted = 1

        assertBothAppearances(CodeCompletionListView(model: model).padding(8), size: CGSize(width: 396, height: 180))
    }

    func testHoverCard() {
        let content = CodeHoverCardContent(
            hover: CodeHoverContent(
                range: NSRange(location: 0, length: 8),
                signature: "Author.nickname: String",
                summary: "What readers call them.",
                deprecationReason: "Use `name`."
            ),
            diagnostics: [CodeDiagnostic(range: NSRange(location: 0, length: 8), message: "Deprecated.", severity: .warning)]
        )

        assertBothAppearances(CodeHoverCard(content: content).padding(8), size: CGSize(width: 300, height: 140))
    }

    // MARK: - Fixtures

    /// The snapshot project's Create user request as a GraphQL POST whose schema is a file in the project, with its
    /// schema loaded and its query checked.
    private func graphQLEditor(query: String) async throws -> RequestEditorViewModel {
        let project = try SnapshotProject.make(in: fixture)
        let folder = try XCTUnwrap(fixture.library.project(project.id)?.url)
        try """
            type Query { user(id: ID!): User }
            "Someone with an account."
            type User { name: String!, email: String, nickname: String @deprecated(reason: "Use name.") }
            """.write(to: folder.appendingPathComponent("users.graphql"), atomically: true, encoding: .utf8)
        let body = HTTPBody(mode: .graphQL, graphQL: GraphQLBody(
            query: query,
            variables: "{ \"id\": \"{{userId}}\" }",
            operationName: "User",
            schema: .file(.relative("users.graphql"))
        ))
        let editor = try project.editor(project.createUser, in: fixture, spec: HTTPRequestSpec(method: .post, url: "{{baseUrl}}/graphql", body: body))
        editor.tab = .body
        await editor.graphQL?.settled()
        return editor
    }
}
