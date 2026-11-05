import Foundation
import Observation
import ReqlingKit

/// The GraphQL body's editor state: its schema, and the problems in its query. It exists while the request sends a
/// GraphQL body (`RequestEditorViewModel.graphQL`).
///
/// Checking takes a moment on a large schema, so it waits for typing to pause (`validationDelay`) and runs off the
/// main actor. A newer check supersedes an older one, and each result is stamped with the query it checked, which the
/// editor shows only while that is still its text. Without a schema, only syntax is checked.
@MainActor
@Observable
final class GraphQLEditorModel {
    static let validationDelay: Duration = .milliseconds(300)

    let schema: GraphQLSchemaLoader
    /// The schema browser's place, kept per request.
    let browser = GraphQLSchemaBrowserModel()
    private(set) var diagnostics: CodeDiagnosticSet = .none

    @ObservationIgnored private unowned let app: AppModel
    @ObservationIgnored private var body = GraphQLBody()
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var validationTask: Task<Void, Never>?

    init(projectID: ProjectID, requestID: RequestNodeID, app: AppModel) {
        self.app = app
        schema = GraphQLSchemaLoader(projectID: projectID, requestID: requestID, app: app)
        schema.onLoad = { [weak self] _ in
            self?.validate(after: nil)
        }
    }

    isolated deinit {
        validationTask?.cancel()
    }

    /// The query or operation name changed: check again once typing pauses.
    func bodyDidChange(_ body: GraphQLBody) {
        guard body.query != self.body.query || body.operationName != self.body.operationName else {
            return
        }
        self.body = body
        validate(after: Self.validationDelay)
    }

    /// Waits for the schema to settle and the newest check to finish, for tests: both run off the main actor.
    func settled() async {
        await schema.settled()
        await validationTask?.value
    }

    /// The type system completion and hover read; nil until a schema loads.
    var typeSystem: GraphQLTypeSystem? {
        schema.snapshot?.typeSystem
    }

    private func validate(after delay: Duration?) {
        validationTask?.cancel()
        generation += 1
        let generation = generation
        let query = body.query
        let operationName = body.operationName
        let validator = schema.snapshot?.validator ?? .syntaxOnly
        let sleep = app.sleep
        validationTask = Task { [weak self] in
            if let delay {
                try? await sleep(delay)
            }
            guard !Task.isCancelled else {
                return
            }
            let found = await Task.detached { validator.diagnostics(for: query, operationName: operationName) }.value
            guard let self, generation == self.generation else {
                return
            }
            diagnostics = CodeDiagnosticSet(text: query, items: found.map { diagnostic in
                CodeDiagnostic(range: diagnostic.range, message: diagnostic.message, severity: diagnostic.severity == .error ? .error : .warning)
            })
        }
    }
}

/// Completion and hover from the loaded schema; with none loaded yet, the editor offers neither. The only place
/// ReqlingKit's GraphQL results become the editor's `Code*` types.
extension GraphQLEditorModel: CodeEditorAssistant {
    func completions(in text: String, cursor: Int) -> CodeCompletionList? {
        guard let typeSystem, let list = GraphQLDocumentAnalyzer(text: text, typeSystem: typeSystem).completions(at: cursor) else {
            return nil
        }
        let items = list.items.enumerated().map { index, item in
            CodeCompletionItem(
                id: index,
                label: item.label,
                kind: Self.kind(item.kind),
                detail: item.detail,
                summary: item.documentation,
                isDeprecated: item.isDeprecated,
                insertText: item.insertText
            )
        }
        return CodeCompletionList(replacementRange: list.replacementRange, items: items)
    }

    func hover(in text: String, at offset: Int) -> CodeHoverContent? {
        guard let typeSystem, let hover = GraphQLDocumentAnalyzer(text: text, typeSystem: typeSystem).hover(at: offset) else {
            return nil
        }
        return CodeHoverContent(
            range: hover.range,
            signature: hover.signature,
            summary: hover.description,
            deprecationReason: hover.deprecationReason
        )
    }

    private static func kind(_ kind: GraphQLCompletionItem.Kind) -> CodeSymbolKind {
        switch kind {
        case .field: .field
        case .argument: .argument
        case .inputField: .inputField
        case .enumValue: .enumValue
        case .variable: .variable
        case .directive: .directive
        case .type: .type
        case .fragment: .fragment
        case .keyword: .keyword
        }
    }
}
