/// A request body. Every mode keeps its own content, so switching between modes (or to a method whose body policy
/// hides the body) never loses what was typed; only `mode` decides what is sent.
public struct HTTPBody: Hashable, Sendable, Codable {
    public var mode: HTTPBodyMode
    public var raw: RawBody
    public var formData: [MultipartField]
    public var urlEncoded: [KeyValuePair]
    public var binary: BinaryBody
    public var graphQL: GraphQLBody

    public init(
        mode: HTTPBodyMode = .none,
        raw: RawBody = RawBody(),
        formData: [MultipartField] = [],
        urlEncoded: [KeyValuePair] = [],
        binary: BinaryBody = BinaryBody(),
        graphQL: GraphQLBody = GraphQLBody()
    ) {
        self.mode = mode
        self.raw = raw
        self.formData = formData
        self.urlEncoded = urlEncoded
        self.binary = binary
        self.graphQL = graphQL
    }

    public static func raw(_ text: String, contentType: String = RawBody.defaultContentType) -> HTTPBody {
        HTTPBody(mode: .raw, raw: RawBody(text: text, contentType: contentType))
    }

    private enum CodingKeys: String, CodingKey {
        case mode
        case raw
        case formData = "form-data"
        case urlEncoded = "x-www-form-urlencoded"
        case binary
        case graphQL = "graphql"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = (try? container.decodeIfPresent(HTTPBodyMode.self, forKey: .mode)) ?? .none
        raw = try container.decodeIfPresent(RawBody.self, forKey: .raw) ?? RawBody()
        formData = try container.decodeRowsIfPresent([MultipartField].self, forKey: .formData) ?? []
        urlEncoded = try container.decodeRowsIfPresent([KeyValuePair].self, forKey: .urlEncoded) ?? []
        binary = try container.decodeIfPresent(BinaryBody.self, forKey: .binary) ?? BinaryBody()
        graphQL = try container.decodeIfPresent(GraphQLBody.self, forKey: .graphQL) ?? GraphQLBody()
    }

    /// Empty sections are left out of the file, so a request that never used a mode carries no trace of it.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mode, forKey: .mode)
        if raw != RawBody() {
            try container.encode(raw, forKey: .raw)
        }
        if !formData.isEmpty {
            try container.encode(formData, forKey: .formData)
        }
        if !urlEncoded.isEmpty {
            try container.encode(urlEncoded, forKey: .urlEncoded)
        }
        if binary != BinaryBody() {
            try container.encode(binary, forKey: .binary)
        }
        if graphQL != GraphQLBody() {
            try container.encode(graphQL, forKey: .graphQL)
        }
    }
}

public enum HTTPBodyMode: String, Hashable, Sendable, Codable, CaseIterable {
    case none
    case raw
    case formData = "form-data"
    case urlEncoded = "x-www-form-urlencoded"
    case binary
    case graphQL = "graphql"
}

public struct RawBody: Hashable, Sendable, Codable {
    public static let defaultContentType = "application/json"
    public static let contentTypePresets = [
        "application/json",
        "application/xml",
        "text/plain",
        "text/html",
        "application/javascript",
        "application/yaml"
    ]

    public var text: String
    public var contentType: String

    public init(text: String = "", contentType: String = RawBody.defaultContentType) {
        self.text = text
        self.contentType = contentType
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType) ?? Self.defaultContentType
    }

    private enum CodingKeys: String, CodingKey {
        case text
        case contentType
    }
}

/// One part of a `multipart/form-data` body. The `id` is stored with the row; `ListRow` explains why.
public struct MultipartField: ListRow, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case text
        case file
    }

    public var id: MultipartFieldID
    public var key: String
    public var kind: Kind
    /// The text part's value; unused for file parts.
    public var value: String
    /// The file part's file; unused for text parts.
    public var file: ProjectPathReference?
    /// Overrides the part's `Content-Type`; file parts otherwise guess one from the file extension.
    public var contentType: String?
    public var isEnabled: Bool

    public init(
        id: MultipartFieldID = MultipartFieldID(),
        key: String,
        kind: Kind = .text,
        value: String = "",
        file: ProjectPathReference? = nil,
        contentType: String? = nil,
        isEnabled: Bool = true
    ) {
        self.id = id
        self.key = key
        self.kind = kind
        self.value = value
        self.file = file
        self.contentType = contentType
        self.isEnabled = isEnabled
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case key
        case kind
        case value
        case file
        case contentType
        case isEnabled = "enabled"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(MultipartFieldID.self, forKey: .id)) ?? Self.derivedID(at: decoder.codingPath)
        key = try container.decodeIfPresent(String.self, forKey: .key) ?? ""
        kind = (try? container.decodeIfPresent(Kind.self, forKey: .kind)) ?? .text
        value = try container.decodeIfPresent(String.self, forKey: .value) ?? ""
        file = try container.decodeIfPresent(ProjectPathReference.self, forKey: .file)
        contentType = try container.decodeIfPresent(String.self, forKey: .contentType)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
    }
}

public struct BinaryBody: Hashable, Sendable, Codable {
    public var file: ProjectPathReference?
    /// Overrides the guess made from the file extension.
    public var contentType: String?

    public init(file: ProjectPathReference? = nil, contentType: String? = nil) {
        self.file = file
        self.contentType = contentType
    }
}

/// A GraphQL operation, sent as the JSON body `{"query", "variables", "operationName"}` that GraphQL servers expect.
public struct GraphQLBody: Hashable, Sendable, Codable {
    public var query: String
    /// JSON object text; empty sends no `variables`.
    public var variables: String
    /// Empty sends no `operationName`.
    public var operationName: String

    public init(query: String = "", variables: String = "", operationName: String = "") {
        self.query = query
        self.variables = variables
        self.operationName = operationName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        query = try container.decodeIfPresent(String.self, forKey: .query) ?? ""
        variables = try container.decodeIfPresent(String.self, forKey: .variables) ?? ""
        operationName = try container.decodeIfPresent(String.self, forKey: .operationName) ?? ""
    }

    private enum CodingKeys: String, CodingKey {
        case query
        case variables
        case operationName
    }
}
