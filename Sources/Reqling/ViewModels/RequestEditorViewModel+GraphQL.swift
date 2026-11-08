import Foundation
import ReqlingKit
import UniformTypeIdentifiers

/// The GraphQL body's schema and checking, which exist only while the request sends a GraphQL body: GraphQL mode, with
/// a method whose body policy allows one. The schema reloads only when what is asked, or how, changes; typing in the
/// query only checks it again.
extension RequestEditorViewModel {
    /// Creates or drops `graphQL` to match `spec`, and passes it what changed since `old` (nil from `init`).
    ///
    /// From `spec`'s own observer, a new model waits out a pause before loading: loading saves the draft first, and a
    /// save assigns `spec`, which inside its own observer would skip that observer.
    func syncGraphQL(from old: HTTPRequestSpec?) {
        guard spec.body.mode == .graphQL, spec.method.bodyPolicy.allowsBody else {
            graphQL = nil
            return
        }
        guard let graphQL else {
            let model = GraphQLEditorModel(projectID: projectID, requestID: requestID, app: app)
            model.schema.prepare = { [weak self] in
                self?.flush()
            }
            graphQL = model
            model.bodyDidChange(spec.body.graphQL)
            if old == nil {
                model.schema.start()
            } else {
                model.schema.startAfterPause()
            }
            return
        }
        if let old, Self.changesGraphQLSchema(from: old, to: spec) {
            graphQL.schema.scheduleReload()
        }
        graphQL.bodyDidChange(spec.body.graphQL)
    }

    /// Whether `new` asks for its schema differently from `old`: another URL, parameters, headers, auth, TLS policy,
    /// method, body mode, or schema source. Never the query, its variables, or its operation name.
    static func changesGraphQLSchema(from old: HTTPRequestSpec, to new: HTTPRequestSpec) -> Bool {
        old.url != new.url
            || old.queryParameters != new.queryParameters
            || old.pathVariables != new.pathVariables
            || old.headers != new.headers
            || old.auth != new.auth
            || old.options.verifyTLS != new.options.verifyTLS
            || old.method != new.method
            || old.body.mode != new.body.mode
            || old.body.graphQL.schema != new.body.graphQL.schema
    }

    var graphQLSchemaSourceTitle: String {
        switch spec.body.graphQL.schema {
        case .introspection: "Introspection"
        case .file(let reference): app.pathResolver(for: projectID)?.url(for: reference)?.lastPathComponent ?? "Schema file"
        }
    }

    func setGraphQLSchemaSource(_ source: GraphQLSchemaSource) {
        spec.body.graphQL.schema = source
    }

    /// Picks an SDL schema (`.graphql`, `.graphqls`, `.gql`) or a saved introspection result (`.json`).
    func chooseGraphQLSchemaFile() {
        let types = ["graphql", "graphqls", "gql", "json"].compactMap { UTType(filenameExtension: $0) }
        guard let url = app.system.chooseFile(prompt: "Use Schema", allowedTypes: types),
              let reference = app.reference(for: url, in: projectID) else {
            return
        }
        spec.body.graphQL.schema = .file(reference)
    }

    /// Whether the inspector shows this request's schema; setting it opens the inspector on the schema or closes it.
    var isShowingGraphQLSchema: Bool {
        get { app.showsGraphQLSchema }
        set {
            if newValue != app.showsGraphQLSchema {
                app.toggleGraphQLSchema()
            }
        }
    }

    /// Asks the server again; the cached schema stays until a new one arrives.
    func refreshGraphQLSchema() {
        graphQL?.schema.refresh()
    }
}
