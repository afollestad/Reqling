import Foundation
import GraphQL

/// How the server answers one request: the override, then the path, the bearer token, the GraphQL-over-HTTP request
/// shape (POST JSON or GET query parameters), and finally GraphQLSwift's parse, validate, and execute.
extension GraphQLFixtureServer {
    func reply(to request: RecordedRequest) async -> Reply {
        if let override = options.override, let reply = override(request) {
            return reply
        }
        let components = URLComponents(string: request.uri)
        guard components?.path == options.path else {
            return Self.errors(["No GraphQL endpoint at \(components?.path ?? request.uri)."], status: 404)
        }
        if let token = options.requiredBearerToken, request.header("Authorization") != "Bearer \(token)" {
            return Self.errors(["Unauthorized."], status: 401)
        }
        let graphQLRequest: GraphQLRequest
        switch request.method {
        case "POST":
            guard let decoded = try? JSONDecoder().decode(GraphQLRequest.self, from: request.body) else {
                return Self.errors(["The body must be a JSON object with a \"query\" string."], status: 400)
            }
            graphQLRequest = decoded
        case "GET":
            guard let decoded = Self.request(from: Self.formItems(components?.percentEncodedQuery ?? "")) else {
                return Self.errors(["A GET request needs a \"query\" parameter, and \"variables\" must be a JSON object."], status: 400)
            }
            graphQLRequest = decoded
        default:
            return Self.errors(["Use POST or GET."], status: 405)
        }
        return await execute(graphQLRequest)
    }

    private func execute(_ request: GraphQLRequest) async -> Reply {
        let document: Document
        do {
            document = try parse(source: Source(body: request.query, name: "GraphQL request"))
        } catch let error as GraphQLError {
            return Self.result(GraphQLResult(errors: [error]), status: 200)
        } catch {
            return Self.errors([String(describing: error)], status: 400)
        }
        if case .disabled(let status) = options.introspection {
            let refused = validate(schema: schema, ast: document, rules: [NoSchemaIntrospectionCustomRule])
            if !refused.isEmpty {
                return Self.result(GraphQLResult(errors: refused), status: status)
            }
        }
        let invalid = validate(schema: schema, ast: document)
        guard invalid.isEmpty else {
            return Self.result(GraphQLResult(errors: invalid), status: 200)
        }
        do {
            let result = try await GraphQL.execute(
                schema: schema,
                documentAST: document,
                rootValue: GraphQLFixtureSchema.rootValue,
                context: (),
                variableValues: request.variables,
                operationName: request.operationName
            )
            return Self.result(result, status: 200)
        } catch let error as GraphQLError {
            return Self.result(GraphQLResult(errors: [error]), status: 200)
        } catch {
            return Self.errors([String(describing: error)], status: 500)
        }
    }

    /// Query parameters decoded as HTML forms send them, with `+` for a space; `URLComponents.queryItems` keeps `+`.
    private static func formItems(_ query: String) -> [String: String] {
        var items: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let decode = { (text: Substring) in String(text).replacingOccurrences(of: "+", with: " ").removingPercentEncoding }
            if let name = parts.first.flatMap(decode), items[name] == nil {
                items[name] = parts.count > 1 ? decode(parts[1]) ?? "" : ""
            }
        }
        return items
    }

    private static func request(from items: [String: String]) -> GraphQLRequest? {
        func value(_ name: String) -> String? {
            items[name]
        }
        guard let query = value("query") else {
            return nil
        }
        var variables: [String: Map] = [:]
        if let text = value("variables"), !text.isEmpty {
            guard let decoded = try? JSONDecoder().decode([String: Map].self, from: Data(text.utf8)) else {
                return nil
            }
            variables = decoded
        }
        return GraphQLRequest(query: query, operationName: value("operationName"), variables: variables)
    }

    static func errors(_ messages: [String], status: Int) -> Reply {
        result(GraphQLResult(errors: messages.map { GraphQLError(message: $0) }), status: status)
    }

    private static func result(_ result: GraphQLResult, status: Int) -> Reply {
        let body = (try? GraphQLJSONEncoder().encode(result)) ?? Data(#"{"errors":[{"message":"Encoding failed."}]}"#.utf8)
        return .respond(status: status, headers: [("Content-Type", "application/json")], body: body)
    }
}
