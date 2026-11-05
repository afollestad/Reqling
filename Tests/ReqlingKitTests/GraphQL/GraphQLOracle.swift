import Foundation
import GraphQL
import GraphQLFixtureServer
import ReqlingKit

/// GraphQLSwift, the Swift port of graphql-js, run in process: the reference the GraphQL suites check Reqling against.
enum GraphQLOracle {
    static let fixtureSDL = GraphQLFixtureSchema.sdl

    static func schema(_ sdl: String = fixtureSDL) throws -> GraphQLSchema {
        try buildSchema(source: sdl)
    }

    /// Parses, validates, and executes `query`, as a server would.
    static func run(_ query: String, on sdl: String = fixtureSDL) async throws -> GraphQLResult {
        try await graphql(schema: schema(sdl), request: query)
    }

    /// The response JSON a server built on `sdl` sends for `query`.
    static func response(to query: String, on sdl: String = fixtureSDL) async throws -> Data {
        try GraphQLJSONEncoder().encode(try await run(query, on: sdl))
    }

    /// The response JSON a server built on `sdl` sends for the introspection query Reqling builds for `capabilities`.
    static func introspectionResponse(
        of sdl: String = fixtureSDL,
        capabilities: GraphQLIntrospection.Capabilities = .all
    ) async throws -> Data {
        let result = try await run(GraphQLIntrospection.query(capabilities), on: sdl)
        return try GraphQLJSONEncoder().encode(result)
    }

    /// What Reqling makes of that response.
    static func decoded(
        _ sdl: String = fixtureSDL,
        capabilities: GraphQLIntrospection.Capabilities = .all
    ) async throws -> GraphQLTypeSystem.Decoded {
        try GraphQLTypeSystem.decoding(introspection: try await introspectionResponse(of: sdl, capabilities: capabilities))
    }

    /// Everything introspection reports about `schema`, keyed so it compares regardless of order: types and directives
    /// by name, and the roots. Comparing two schemas this way checks every description, default, deprecation, and
    /// wrapper introspection can see, which printing them would only check in declaration order.
    static func described(_ schema: GraphQLSchema, capabilities: GraphQLIntrospection.Capabilities = .all) async throws -> NSDictionary {
        let result = try await graphql(schema: schema, request: GraphQLIntrospection.query(capabilities))
        let response = try object(GraphQLJSONEncoder().encode(result))
        let described = (response["data"] as? [String: Any])?["__schema"] as? [String: Any] ?? [:]
        var keyed = canonicalDefaults(described) as? [String: Any] ?? [:]
        for key in ["types", "directives"] {
            let entries = keyed[key] as? [[String: Any]] ?? []
            keyed[key] = Dictionary(uniqueKeysWithValues: entries.map { ($0["name"] as? String ?? "", $0) })
        }
        return keyed as NSDictionary
    }

    /// Every `defaultValue` with its input objects' fields sorted by name. GraphQLSwift prints a default's fields in
    /// the order its input type declares them, and its introspection reorders those declarations, so equal defaults
    /// otherwise read differently once a schema has been through introspection.
    private static func canonicalDefaults(_ value: Any) -> Any {
        if let object = value as? [String: Any] {
            var result = object.mapValues(canonicalDefaults)
            if let literal = object["defaultValue"] as? String,
               let document = try? parse(source: Source(body: "query($v: Int = \(literal)) { a }")),
               let defaultValue = (document.definitions.first as? OperationDefinition)?.variableDefinitions.first?.defaultValue {
                result["defaultValue"] = canonical(defaultValue)
            }
            return result
        }
        if let array = value as? [Any] {
            return array.map(canonicalDefaults)
        }
        return value
    }

    private static func canonical(_ value: Value) -> String {
        if let object = value as? ObjectValue {
            let fields = object.fields.sorted { $0.name.value < $1.name.value }.map { "\($0.name.value): \(canonical($0.value))" }
            return "{" + fields.joined(separator: ", ") + "}"
        }
        if let list = value as? ListValue {
            return "[" + list.values.map(canonical).joined(separator: ", ") + "]"
        }
        return print(ast: value)
    }

    /// The JSON object tree of `data`, to edit into what an older server would send.
    static func object(_ data: Data) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
    }

    static func data(_ object: Any) throws -> Data {
        try JSONSerialization.data(withJSONObject: object)
    }
}
