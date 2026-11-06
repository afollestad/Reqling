/// Everything needed to build one HTTP request, with `{{variables}}` still unresolved. Its URL and query follow
/// `QueryAddressed`.
public struct HTTPRequestSpec: Hashable, Sendable, Codable, QueryAddressed {
    public var method: HTTPMethod
    public var url: String
    public var queryParameters: [KeyValuePair]
    public var headers: [KeyValuePair]
    /// Lower-cased names of automatic headers (such as `user-agent`) the user turned off.
    public var disabledAutoHeaders: [String]
    public var body: HTTPBody
    public var auth: HTTPAuth
    public var options: HTTPRequestOptions

    public init(
        method: HTTPMethod = .get,
        url: String = "",
        queryParameters: [KeyValuePair] = [],
        headers: [KeyValuePair] = [],
        disabledAutoHeaders: [String] = [],
        body: HTTPBody = HTTPBody(),
        auth: HTTPAuth = .inherit,
        options: HTTPRequestOptions = HTTPRequestOptions()
    ) {
        self.method = method
        self.url = url
        self.queryParameters = queryParameters
        self.headers = headers
        self.disabledAutoHeaders = disabledAutoHeaders
        self.body = body
        self.auth = auth
        self.options = options
    }

    private enum CodingKeys: String, CodingKey {
        case method
        case url
        case queryParameters
        case headers
        case disabledAutoHeaders
        case body
        case auth
        case options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        method = try container.decodeIfPresent(HTTPMethod.self, forKey: .method) ?? .get
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        queryParameters = try container.decodeRowsIfPresent([KeyValuePair].self, forKey: .queryParameters) ?? []
        headers = try container.decodeRowsIfPresent([KeyValuePair].self, forKey: .headers) ?? []
        disabledAutoHeaders = try container.decodeIfPresent([String].self, forKey: .disabledAutoHeaders) ?? []
        body = try container.decodeIfPresent(HTTPBody.self, forKey: .body) ?? HTTPBody()
        auth = try container.decodeIfPresent(HTTPAuth.self, forKey: .auth) ?? .inherit
        options = try container.decodeIfPresent(HTTPRequestOptions.self, forKey: .options) ?? HTTPRequestOptions()
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(method, forKey: .method)
        try container.encode(url, forKey: .url)
        try container.encode(queryParameters, forKey: .queryParameters)
        try container.encode(headers, forKey: .headers)
        if !disabledAutoHeaders.isEmpty {
            try container.encode(disabledAutoHeaders, forKey: .disabledAutoHeaders)
        }
        try container.encode(body, forKey: .body)
        try container.encode(auth, forKey: .auth)
        if options != HTTPRequestOptions() {
            try container.encode(options, forKey: .options)
        }
    }
}

/// Per-request overrides; `nil` uses the app default from Settings → Requests.
public struct HTTPRequestOptions: Hashable, Sendable, Codable {
    public var timeoutSeconds: Double?
    public var followRedirects: Bool?
    public var verifyTLS: Bool?

    public init(timeoutSeconds: Double? = nil, followRedirects: Bool? = nil, verifyTLS: Bool? = nil) {
        self.timeoutSeconds = timeoutSeconds
        self.followRedirects = followRedirects
        self.verifyTLS = verifyTLS
    }
}
