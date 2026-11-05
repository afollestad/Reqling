import Foundation
@_implementationOnly import GraphQL

/// GraphQLSwift, the Swift port of graphql-js, behind plain Foundation types: building schemas from SDL, and later
/// parsing and validating documents. ReqlingKit wraps it in its own types.
///
/// It is a module of its own, importing `GraphQL` implementation-only, because GraphQLSwift's declarations change how
/// unrelated code type-checks in any module that can see them: in ReqlingKit, `[Int?].compactMap { $0.map(String.init) }`
/// stopped compiling. A plain or `internal import` still lets clients load the module transitively;
/// `@_implementationOnly` does not, and `CheckImplementationOnly` (`Package.swift`) verifies nothing public needs it.
public enum GraphQLEngine {
    /// Introspects an SDL schema with the query `introspectionQuery` names, so a schema file decodes through the same
    /// path as a server's response. Returns the response JSON and anything worth noting about the schema.
    ///
    /// A schema with problems that SDL validation catches (an undefined directive, say) is still read, with an issue.
    /// It runs the query through `execute`, not `graphql()`: the latter refuses any schema that fails `validateSchema`,
    /// such as one without a query type, which the caller can then report more clearly.
    public static func introspection(
        ofSDL sdl: String,
        query introspectionQuery: String
    ) async throws(GraphQLEngineError) -> (json: Data, issues: [String]) {
        var issues: [String] = []
        let schema: GraphQLSchema
        do {
            schema = try buildSchema(source: sdl)
        } catch {
            do {
                schema = try buildSchema(source: sdl, assumeValid: true, assumeValidSDL: true)
                issues.append("The schema has problems, so some checks may be off: \(describe(error, in: sdl))")
            } catch {
                throw GraphQLEngineError("The schema could not be read: \(describe(error, in: sdl))")
            }
        }
        guard schema.queryType != nil else {
            throw GraphQLEngineError("The schema has no query type: define `type Query`, or name one in a `schema { query: … }` block.")
        }
        let result: GraphQLResult
        do {
            let document = try parse(source: Source(body: introspectionQuery))
            result = try await execute(schema: schema, documentAST: document, rootValue: (), context: ())
        } catch {
            throw GraphQLEngineError("The schema could not be introspected: \(describe(error, in: introspectionQuery))")
        }
        issues += result.errors.map { "Introspection reported: \(cleanMessage($0.message))" }
        do {
            return (withInputFieldDefaults(try GraphQLJSONEncoder().encode(result), from: schema), issues)
        } catch {
            throw GraphQLEngineError("The schema could not be introspected: \(error.localizedDescription)")
        }
    }

    /// GraphQLSwift's introspection reports no default for an input object's fields (its `__InputValue.defaultValue`
    /// resolver reads only arguments), so `limit: Int! = 10` would read as required. The schema still has each field's
    /// definition, whose default prints as the literal introspection would have sent.
    private static func withInputFieldDefaults(_ json: Data, from schema: GraphQLSchema) -> Data {
        guard var response = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              var data = response["data"] as? [String: Any],
              var schemaObject = data["__schema"] as? [String: Any],
              let types = schemaObject["types"] as? [[String: Any]] else {
            return json
        }
        schemaObject["types"] = types.map { type -> [String: Any] in
            guard type["kind"] as? String == "INPUT_OBJECT",
                  let name = type["name"] as? String,
                  let definitions = try? (schema.getType(name: name) as? GraphQLInputObjectType)?.fields(),
                  let inputFields = type["inputFields"] as? [[String: Any]] else {
                return type
            }
            var type = type
            type["inputFields"] = inputFields.map { field -> [String: Any] in
                guard field["defaultValue"] is NSNull || field["defaultValue"] == nil,
                      let fieldName = field["name"] as? String,
                      let literal = definitions[fieldName]?.astNode?.defaultValue else {
                    return field
                }
                var field = field
                field["defaultValue"] = GraphQL.print(ast: literal)
                return field
            }
            return type
        }
        data["__schema"] = schemaObject
        response["data"] = data
        return (try? JSONSerialization.data(withJSONObject: response)) ?? json
    }
}

/// A failure, in a sentence fit to show.
public struct GraphQLEngineError: Error, Hashable, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }
}
