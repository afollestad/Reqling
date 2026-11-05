import Foundation

/// The queries Reqling sends to read a server's schema, and how it reads their responses.
///
/// Servers support different parts of introspection, and asking for a field a server lacks fails the whole query.
/// So a small probe asks which of the newer fields exist, and the full query asks only for those. graphql-js's default
/// query is the conservative fallback, for servers that answer only the queries they expect.
///
/// Arguments and input fields ask for `deprecationReason` and never `isDeprecated`: servers built on GraphQLSwift
/// (Graphiti, Vapor) cannot resolve `__InputValue.isDeprecated`, and the reason says as much on its own.
public enum GraphQLIntrospection {
    /// What a server's introspection supports beyond graphql-js's default query.
    public struct Capabilities: Hashable, Sendable, Codable {
        /// `__Schema.description`.
        public var schemaDescription: Bool
        /// `__Type.specifiedByURL`, or `specifiedByUrl` from graphql-js 15.
        public var specifiedBy: SpecifiedBySpelling?
        /// `__Directive.isRepeatable`.
        public var directiveIsRepeatable: Bool
        /// Deprecated arguments and input fields: `includeDeprecated` on `args` and `inputFields`, and
        /// `__InputValue.deprecationReason`. Without it a deprecated argument is missing from the schema altogether.
        public var inputValueDeprecation: Bool
        /// `includeDeprecated` on `__Directive.args`, which graphql-js added after the rest.
        public var directiveArgumentDeprecation: Bool
        /// `__Type.isOneOf`.
        public var oneOf: Bool

        public init(
            schemaDescription: Bool = false,
            specifiedBy: SpecifiedBySpelling? = nil,
            directiveIsRepeatable: Bool = false,
            inputValueDeprecation: Bool = false,
            directiveArgumentDeprecation: Bool = false,
            oneOf: Bool = false
        ) {
            self.schemaDescription = schemaDescription
            self.specifiedBy = specifiedBy
            self.directiveIsRepeatable = directiveIsRepeatable
            self.inputValueDeprecation = inputValueDeprecation
            self.directiveArgumentDeprecation = directiveArgumentDeprecation
            self.oneOf = oneOf
        }

        /// graphql-js's default query: what every server answers.
        public static let conservative = Capabilities()
        /// Everything this query knows to ask for, as GraphQLSwift supports.
        public static let all = Capabilities(
            schemaDescription: true,
            specifiedBy: .url,
            directiveIsRepeatable: true,
            inputValueDeprecation: true,
            directiveArgumentDeprecation: true,
            oneOf: true
        )
    }

    /// How a server spells the field that links a custom scalar's specification.
    public enum SpecifiedBySpelling: String, Hashable, Sendable, Codable {
        case url = "specifiedByURL"
        /// graphql-js 15.
        case legacy = "specifiedByUrl"
    }

    /// The operation name every query here sends, so server logs show what Reqling asked.
    public static let operationName = "IntrospectionQuery"

    /// Above this a response is refused rather than parsed: decoding holds all of it in memory at once.
    public static let responseLimit = 64 * 1024 * 1024

    /// Asks which introspection fields and arguments the server has.
    public static let probeQuery = """
        query \(operationName) {
          schemaMeta: __type(name: "__Schema") { fields { name } }
          typeMeta: __type(name: "__Type") { fields { name args { name } } }
          fieldMeta: __type(name: "__Field") { fields { name args { name } } }
          directiveMeta: __type(name: "__Directive") { fields { name args { name } } }
          inputValueMeta: __type(name: "__InputValue") { fields { name } }
        }
        """

    /// Reads the probe's `data`. A server that answers without some meta-type is taken not to support what it adds.
    public static func capabilities(fromProbe data: [String: Any]) -> Capabilities {
        func fields(_ key: String) -> [String: Set<String>] {
            let list = (data[key] as? [String: Any])?["fields"] as? [[String: Any]] ?? []
            var fields: [String: Set<String>] = [:]
            for field in list {
                if let name = field["name"] as? String {
                    fields[name] = Set((field["args"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String })
                }
            }
            return fields
        }
        let schema = fields("schemaMeta")
        let type = fields("typeMeta")
        let field = fields("fieldMeta")
        let directive = fields("directiveMeta")
        let inputValue = fields("inputValueMeta")
        let specifiedBy: SpecifiedBySpelling? = if type["specifiedByURL"] != nil {
            .url
        } else if type["specifiedByUrl"] != nil {
            .legacy
        } else {
            nil
        }
        let inputValueDeprecation = inputValue["deprecationReason"] != nil
            && field["args"]?.contains("includeDeprecated") == true
            && type["inputFields"]?.contains("includeDeprecated") == true
        return Capabilities(
            schemaDescription: schema["description"] != nil,
            specifiedBy: specifiedBy,
            directiveIsRepeatable: directive["isRepeatable"] != nil,
            inputValueDeprecation: inputValueDeprecation,
            directiveArgumentDeprecation: inputValueDeprecation && directive["args"]?.contains("includeDeprecated") == true,
            oneOf: type["isOneOf"] != nil
        )
    }

    /// The full schema query for a server with `capabilities`. Type references nest as deep as graphql-js 16 reads
    /// them, which covers any type a real schema declares (`[[String!]!]!` is five deep).
    public static func query(_ capabilities: Capabilities) -> String {
        let deprecatedInputs = capabilities.inputValueDeprecation ? "(includeDeprecated: true)" : ""
        let directiveArgs = capabilities.directiveArgumentDeprecation ? "(includeDeprecated: true)" : ""
        var schemaFields = ["queryType { name }", "mutationType { name }", "subscriptionType { name }", "types { ...FullType }"]
        if capabilities.schemaDescription {
            schemaFields.insert("description", at: 0)
        }
        var directiveFields = ["name", "description", "locations", "args\(directiveArgs) { ...InputValue }"]
        if capabilities.directiveIsRepeatable {
            directiveFields.insert("isRepeatable", at: 2)
        }
        schemaFields.append("directives { \(directiveFields.joined(separator: " ")) }")
        var typeFields = ["kind", "name", "description"]
        if let spelling = capabilities.specifiedBy {
            typeFields.append(spelling.rawValue)
        }
        if capabilities.oneOf {
            typeFields.append("isOneOf")
        }
        typeFields += [
            "fields(includeDeprecated: true) { name description args\(deprecatedInputs) { ...InputValue } type { ...TypeRef }"
                + " isDeprecated deprecationReason }",
            "inputFields\(deprecatedInputs) { ...InputValue }",
            "interfaces { ...TypeRef }",
            "enumValues(includeDeprecated: true) { name description isDeprecated deprecationReason }",
            "possibleTypes { ...TypeRef }"
        ]
        var inputValueFields = ["name", "description", "type { ...TypeRef }", "defaultValue"]
        if capabilities.inputValueDeprecation {
            inputValueFields.append("deprecationReason")
        }
        var typeRef = "kind name"
        for _ in 0..<7 {
            typeRef = "kind name ofType { \(typeRef) }"
        }
        return """
            query \(operationName) {
              __schema { \(schemaFields.joined(separator: " ")) }
            }
            fragment FullType on __Type { \(typeFields.joined(separator: " ")) }
            fragment InputValue on __InputValue { \(inputValueFields.joined(separator: " ")) }
            fragment TypeRef on __Type { \(typeRef) }
            """
    }

    /// What an introspection response says, whatever its status: GraphQL over HTTP sends GraphQL errors with 4xx too,
    /// so the body is read first.
    public enum Outcome: Sendable {
        /// The response's `data`, as JSON, and any errors it also carried.
        case data(Data, errors: [String])
        /// Errors and no data: the server refused the query, as one with introspection turned off does.
        case refused([String])
        case failed(GraphQLIntrospectionFailure)
    }

    public static func classify(_ response: HTTPResponseRecord) -> Outcome {
        guard response.body.count <= responseLimit else {
            return .failed(.tooLarge(response.body.count))
        }
        let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        let errors = (object?["errors"] as? [Any])?.map(errorMessage) ?? []
        if let data = object?["data"] as? [String: Any], let json = try? JSONSerialization.data(withJSONObject: data) {
            return .data(json, errors: errors)
        }
        if object?["errors"] != nil {
            return .refused(errors.isEmpty ? ["The server reported an error without a message."] : errors)
        }
        guard (200..<300).contains(response.statusCode) else {
            return .failed(.http(status: response.statusCode, snippet: snippet(response.body)))
        }
        let contentType = response.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
        return .failed(.notGraphQL(contentType: contentType, redirected: response.redirectCount > 0))
    }

    private static func errorMessage(_ error: Any) -> String {
        if let message = (error as? [String: Any])?["message"] as? String, !message.isEmpty {
            return message
        }
        return (error as? String) ?? "The server reported an error without a message."
    }

    /// The start of a body, on one line, to show with an HTTP failure.
    private static func snippet(_ body: Data) -> String? {
        guard let text = String(data: body.prefix(512), encoding: .utf8) else {
            return nil
        }
        let flattened = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !flattened.isEmpty else {
            return nil
        }
        return flattened.count > 200 ? String(flattened.prefix(200)) + "…" : flattened
    }
}

/// Why an introspection response holds no schema.
public enum GraphQLIntrospectionFailure: Error, Hashable, Sendable, LocalizedError {
    case http(status: Int, snippet: String?)
    /// A successful status with a body that is not a GraphQL response, such as a login page.
    case notGraphQL(contentType: String?, redirected: Bool)
    case tooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .http(let status, let snippet):
            let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
            return "The server answered \(status) \(reason)" + (snippet.map { ": \($0)" } ?? ".")
        case .notGraphQL(let contentType, let redirected):
            let kind = contentType.map { " (\($0))" } ?? ""
            let redirect = redirected
                ? " It redirected first, which turns a POST into a GET; use the URL it redirects to."
                : ""
            return "The response\(kind) is not a GraphQL response.\(redirect)"
        case .tooLarge(let bytes):
            let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
            return "The schema is \(size), more than Reqling reads."
        }
    }
}
