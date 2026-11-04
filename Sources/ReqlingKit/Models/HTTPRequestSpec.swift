/// Everything needed to build one HTTP request, with `{{variables}}` still unresolved.
///
/// `url` never carries a query string: `queryParameters` is the single source of truth, including disabled rows, and
/// the editor shows the two joined. `normalized()` moves a pasted or externally written query into the table.
public struct HTTPRequestSpec: Hashable, Sendable, Codable {
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

    /// Splits a query string out of `url` and appends its items to `queryParameters` as enabled rows. Item text is
    /// kept as written, percent-escapes included, so encoding happens once, when the request is built; only `+` is
    /// read as a space, as form-encoded queries mean it (`?q=a+b` searches for "a b").
    ///
    /// The new rows' IDs derive from their positions and text, so normalizing the same spec twice yields equal specs:
    /// editors normalize every stored spec they read, and a random ID would make each read look like a change elsewhere.
    public func normalized() -> HTTPRequestSpec {
        guard let (path, query) = Self.splitQuery(url) else {
            return self
        }
        var copy = self
        copy.url = path
        copy.queryParameters += Self.parseQuery(query)
        copy.queryParameters.deriveIDs(at: queryParameters.count..<copy.queryParameters.count, name: Self.queryRowName)
        return copy
    }

    /// The text the URL bar shows: `url` plus the enabled query rows, unencoded except where `applyDisplayURL` would
    /// read the text back differently: `+` (a space there), `#` (the fragment), `&` (the next row), and `=` in a name
    /// show percent-encoded. Each is one the builder escapes anyway, so the bytes sent never change.
    public var displayURL: String {
        let enabled = queryParameters.filter(\.isEnabled)
        guard !enabled.isEmpty else {
            return url
        }
        func shown(_ text: String, isName: Bool) -> String {
            var result = ""
            for character in text {
                switch character {
                case "+": result += "%2B"
                case "#": result += "%23"
                case "&": result += "%26"
                case "=" where isName: result += "%3D"
                default: result.append(character)
                }
            }
            return result
        }
        let query = enabled.map { row in
            row.value.isEmpty ? shown(row.key, isName: true) : "\(shown(row.key, isName: true))=\(shown(row.value, isName: false))"
        }
        return "\(url)?\(query.joined(separator: "&"))"
    }

    /// Applies URL-bar text: the query becomes the enabled rows, and disabled rows the bar cannot show are kept.
    ///
    /// Rows the text still describes keep their IDs (`carryingIDs(into:reserving:name:)`), so typing in the bar edits
    /// rows rather than replacing them, and a merge with a change made elsewhere meanwhile keeps that change.
    public mutating func applyDisplayURL(_ text: String) {
        let enabled = queryParameters.filter(\.isEnabled)
        let disabled = queryParameters.filter { !$0.isEnabled }
        let (path, query) = Self.splitQuery(text) ?? (text, "")
        url = path
        let parsed = enabled.carryingIDs(into: Self.parseQuery(query), reserving: Set(disabled.map(\.id)), name: Self.queryRowName)
        queryParameters = parsed + disabled
    }

    /// `url` before its `?`, and the query after it up to any `#fragment`; `nil` when there is no `?`.
    private static func splitQuery(_ url: String) -> (path: String, query: String)? {
        guard let questionMark = url.firstIndex(of: "?") else {
            return nil
        }
        var query = url[url.index(after: questionMark)...]
        if let fragment = query.firstIndex(of: "#") {
            query = query[..<fragment]
        }
        return (String(url[..<questionMark]), String(query))
    }

    /// What a query row parsed from text derives its ID from (`deriveIDs`).
    private static func queryRowName(_ index: Int, _ row: KeyValuePair) -> String {
        "query/\(index)/\(row.key)=\(row.value)"
    }

    static func parseQuery(_ query: String) -> [KeyValuePair] {
        func text(_ part: Substring) -> String {
            part.replacingOccurrences(of: "+", with: " ")
        }
        return query.split(separator: "&", omittingEmptySubsequences: true).map { item in
            if let equals = item.firstIndex(of: "=") {
                return KeyValuePair(key: text(item[..<equals]), value: text(item[item.index(after: equals)...]))
            }
            return KeyValuePair(key: text(item), value: "")
        }
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
