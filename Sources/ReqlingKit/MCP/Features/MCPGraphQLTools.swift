import Foundation
import MCP

/// A GraphQL request's schema, read through the request as the editor reads it (its schema file, or introspection
/// with the request's own URL, headers, and auth, cached), and checking queries against it.
@MainActor
struct MCPGraphQLTools {
    let context: MCPToolContext

    var tools: [MCPTool] {
        [listTypes, describeType, validate]
    }

    private static let requestSchema = MCPSchema.string(
        "A GraphQL request's ID, from list_requests; its schema source decides where the schema comes from."
    )

    private var listTypes: MCPTool {
        MCPTool(
            "graphql_list_types",
            title: "List GraphQL types",
            description: "The types of a GraphQL request's schema and its root types. Filter by kind or name; filtered lists "
                + "include descriptions. The schema is cached; refresh asks the server again.",
            properties: [
                "project": MCPSchema.project,
                "request": Self.requestSchema,
                "kind": MCPSchema.enumeration(GraphQLTypeSystem.Kind.allKeywords, "Only types of this kind."),
                "query": MCPSchema.string("Only types whose names match, as completion matches them."),
                "refresh": MCPSchema.boolean("Ask the server again even when the schema is cached.")
            ],
            required: ["project", "request"],
            annotations: .networkRead,
            timeout: .seconds(120)
        ) { arguments in
            let (snapshot, mask) = try await schema(arguments, refresh: try arguments.bool("refresh", default: false))
            let kind = try arguments.optionalString("kind")
            let query = try arguments.optionalString("query") ?? ""
            let filtered = kind != nil || !query.isEmpty
            let types = GraphQLCompletionRanking.rank(snapshot.typeSystem.browsableTypes, by: query, name: \.name, isDeprecated: { _ in false })
                .filter { kind == nil || $0.kind.keyword == kind }
            var description = Self.describe(snapshot, mask: mask)
            description["types"] = .array(types.map { type in
                var entry: [String: Value] = ["name": .string(type.name), "kind": .string(type.kind.keyword)]
                if filtered, let text = type.description {
                    entry["description"] = .string(mask(text))
                }
                return .object(entry)
            })
            return .object(description)
        }
    }

    private var describeType: MCPTool {
        MCPTool(
            "graphql_describe_type",
            title: "Describe GraphQL type",
            description: "One type of a GraphQL request's schema as SDL, with the types implementing it and the fields and "
                + "arguments that use it. Name a directive as @name. graphql_list_types lists the names.",
            properties: [
                "project": MCPSchema.project,
                "request": Self.requestSchema,
                "name": MCPSchema.string("A type's name, or a directive's as @name.")
            ],
            required: ["project", "request", "name"],
            annotations: .networkRead,
            timeout: .seconds(120)
        ) { arguments in
            let (snapshot, mask) = try await schema(arguments, refresh: false)
            let name = try arguments.string("name").trimmingCharacters(in: .whitespaces)
            let typeSystem = snapshot.typeSystem
            if name.hasPrefix("@") {
                guard let sdl = typeSystem.sdl(forDirective: String(name.dropFirst())) else {
                    throw MCPToolError("The schema has no directive \(name).")
                }
                return .object(["sdl": .string(mask(sdl))])
            }
            guard let sdl = typeSystem.sdl(forType: name) else {
                throw MCPToolError("The schema has no type \(name); graphql_list_types lists them.")
            }
            return .object([
                "sdl": .string(mask(sdl)),
                "implementedBy": .array(typeSystem.implementations(of: name).map { .string($0.name) }),
                "possibleTypes": .array((typeSystem.type(named: name)?.possibleTypes ?? []).map { .string($0) }),
                "usedBy": .array(typeSystem.references(to: name).map { .string($0.path) })
            ])
        }
    }

    private var validate: MCPTool {
        MCPTool(
            "graphql_validate",
            title: "Check GraphQL query",
            description: "Checks a query against a GraphQL request's schema as the editor does: syntax, unknown fields and "
                + "arguments, missing required arguments, wrong values, and deprecated use. Defaults to the request's own "
                + "query and operation name. Lines and columns are 1-based.",
            properties: [
                "project": MCPSchema.project,
                "request": Self.requestSchema,
                "query": MCPSchema.string("A query to check in place of the request's own; {{variables}} stand for their values."),
                "operationName": MCPSchema.string("The operation to run, when the query has several.")
            ],
            required: ["project", "request"],
            annotations: .networkRead,
            timeout: .seconds(120)
        ) { arguments in
            let (snapshot, mask) = try await schema(arguments, refresh: false)
            let (_, document) = try context.document(try arguments.string("project"))
            let request = try context.request(try arguments.string("request"), in: document)
            let body = request.kind.httpSpec?.body.graphQL
            let query = try arguments.optionalString("query") ?? body?.query ?? ""
            let operationName = try arguments.optionalString("operationName") ?? body?.operationName
            let validator = snapshot.validator
            let diagnostics = await Task.detached { validator.diagnostics(for: query, operationName: operationName) }.value
            return .object([
                "valid": .bool(!diagnostics.contains { $0.severity == .error }),
                "diagnostics": .array(diagnostics.map { Self.describe($0, in: query, mask: mask) })
            ])
        }
    }

    // MARK: - Support

    private func schema(_ arguments: MCPArguments, refresh: Bool) async throws -> (GraphQLSchemaSnapshot, @Sendable (String) -> String) {
        let (project, document) = try context.document(try arguments.string("project"))
        let request = try context.request(try arguments.string("request"), in: document)
        let mask = context.runner.maskingSecrets(in: project.id)
        do {
            let snapshot = try await context.runner.graphQLSchema(
                for: request.id,
                in: project.id,
                refresh: refresh,
                options: RunOptions(allowUnresolved: true)
            )
            return (snapshot, mask)
        } catch {
            throw MCPToolError(mask(error.message))
        }
    }

    private static func describe(_ snapshot: GraphQLSchemaSnapshot, mask: (String) -> String) -> [String: Value] {
        let source: Value = switch snapshot.source {
        case .introspection(let url, let fetchedAt):
            .object(["introspection": .string(url), "fetchedAt": .string(ISO8601DateFormatter().string(from: fetchedAt))])
        case .file(let name):
            .object(["file": .string(name)])
        }
        var roots: [String: Value] = [:]
        for (operation, name) in snapshot.typeSystem.rootTypes {
            roots[operation.rawValue] = .string(name)
        }
        var description: [String: Value] = ["source": source, "roots": .object(roots)]
        if !snapshot.issues.isEmpty {
            description["issues"] = .array(snapshot.issues.map { .string(mask($0)) })
        }
        return description
    }

    private static func describe(_ diagnostic: GraphQLDiagnostic, in query: String, mask: (String) -> String) -> Value {
        let units = Array(query.utf16)
        let before = units.prefix(diagnostic.range.location)
        let line = before.filter { $0 == 0x0A }.count + 1
        let column = before.count - (before.lastIndex(of: 0x0A).map { $0 + 1 } ?? 0) + 1
        let text = String(decoding: units[diagnostic.range.location..<min(units.count, NSMaxRange(diagnostic.range))], as: UTF16.self)
        return .object([
            "severity": .string(diagnostic.severity == .error ? "error" : "warning"),
            "message": .string(mask(diagnostic.message)),
            "line": .int(line),
            "column": .int(column),
            "text": .string(mask(text))
        ])
    }
}

extension GraphQLTypeSystem.Kind {
    /// The SDL keywords of every kind, as `graphql_list_types` filters by them.
    static let allKeywords = ["scalar", "type", "interface", "union", "enum", "input"]
}
