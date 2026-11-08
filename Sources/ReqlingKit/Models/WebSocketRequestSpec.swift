/// Everything needed to open one WebSocket connection, with `{{variables}}` still unresolved. Its URL, query, and
/// path variables follow `URLAddressed`, and its handshake is an HTTP GET (`handshake`), so auth, headers, and
/// automatic headers behave as an HTTP request's do.
public struct WebSocketRequestSpec: Hashable, Sendable, Codable, URLAddressed {
    /// `ws://` or `wss://`. `http(s)://` maps to `ws(s)://`, and a URL with no scheme is `ws://`, as browsers allow.
    public var url: String
    public var queryParameters: [KeyValuePair]
    public var pathVariables: [KeyValuePair]
    public var headers: [KeyValuePair]
    /// Lower-cased names of on-by-default automatic headers (such as `user-agent`) the user turned off.
    public var disabledAutoHeaders: [String]
    /// Lower-cased names of off-by-default automatic headers the user turned on; only `origin` is one.
    public var enabledAutoHeaders: [String]
    /// Offered as `Sec-WebSocket-Protocol`, in preference order, unless a header sets it.
    public var subprotocols: [String]
    /// In order; those that send on connect go out as soon as the connection opens, and any can be sent while it is.
    public var messages: [WebSocketMessage]
    public var auth: HTTPAuth
    public var options: WebSocketRequestOptions

    public init(
        url: String = "",
        queryParameters: [KeyValuePair] = [],
        pathVariables: [KeyValuePair] = [],
        headers: [KeyValuePair] = [],
        disabledAutoHeaders: [String] = [],
        enabledAutoHeaders: [String] = [],
        subprotocols: [String] = [],
        messages: [WebSocketMessage] = [],
        auth: HTTPAuth = .inherit,
        options: WebSocketRequestOptions = WebSocketRequestOptions()
    ) {
        self.url = url
        self.queryParameters = queryParameters
        self.pathVariables = pathVariables
        self.headers = headers
        self.disabledAutoHeaders = disabledAutoHeaders
        self.enabledAutoHeaders = enabledAutoHeaders
        self.subprotocols = subprotocols
        self.messages = messages
        self.auth = auth
        self.options = options
    }

    /// The messages a connection sends as soon as it opens, in order.
    public var onConnectMessages: [WebSocketMessage] {
        messages.filter(\.sendsOnConnect)
    }

    private enum CodingKeys: String, CodingKey {
        case url, queryParameters, pathVariables, headers, disabledAutoHeaders, enabledAutoHeaders, subprotocols, messages, auth, options
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        queryParameters = try container.decodeRowsIfPresent([KeyValuePair].self, forKey: .queryParameters) ?? []
        pathVariables = try container.decodeRowsIfPresent([KeyValuePair].self, forKey: .pathVariables) ?? []
        headers = try container.decodeRowsIfPresent([KeyValuePair].self, forKey: .headers) ?? []
        disabledAutoHeaders = try container.decodeIfPresent([String].self, forKey: .disabledAutoHeaders) ?? []
        enabledAutoHeaders = try container.decodeIfPresent([String].self, forKey: .enabledAutoHeaders) ?? []
        subprotocols = try container.decodeIfPresent([String].self, forKey: .subprotocols) ?? []
        messages = try container.decodeRowsIfPresent([WebSocketMessage].self, forKey: .messages) ?? []
        auth = try container.decodeIfPresent(HTTPAuth.self, forKey: .auth) ?? .inherit
        options = try container.decodeIfPresent(WebSocketRequestOptions.self, forKey: .options) ?? WebSocketRequestOptions()
    }

    /// Leaves out what is empty or default, as `HTTPRequestSpec` does, so request files stay short.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(url, forKey: .url)
        try container.encode(queryParameters, forKey: .queryParameters)
        if !pathVariables.isEmpty {
            try container.encode(pathVariables, forKey: .pathVariables)
        }
        try container.encode(headers, forKey: .headers)
        if !disabledAutoHeaders.isEmpty {
            try container.encode(disabledAutoHeaders, forKey: .disabledAutoHeaders)
        }
        if !enabledAutoHeaders.isEmpty {
            try container.encode(enabledAutoHeaders, forKey: .enabledAutoHeaders)
        }
        if !subprotocols.isEmpty {
            try container.encode(subprotocols, forKey: .subprotocols)
        }
        try container.encode(messages, forKey: .messages)
        try container.encode(auth, forKey: .auth)
        if options != WebSocketRequestOptions() {
            try container.encode(options, forKey: .options)
        }
    }
}

/// One saved message of a WebSocket request. The `id` is stored with it, as every list row's is (`ListRow`), so a draft
/// and a change made elsewhere merge message by message.
public struct WebSocketMessage: ListRow, Codable {
    public var id: WebSocketMessageID
    public var format: WebSocketMessageFormat
    /// The text to send, or for a binary message its bytes as base64; `{{variables}}` resolve in either.
    public var text: String
    public var sendsOnConnect: Bool

    public init(
        id: WebSocketMessageID = WebSocketMessageID(),
        format: WebSocketMessageFormat = .text,
        text: String = "",
        sendsOnConnect: Bool = true
    ) {
        self.id = id
        self.format = format
        self.text = text
        self.sendsOnConnect = sendsOnConnect
    }

    private enum CodingKeys: String, CodingKey {
        case id, format, text
        case sendsOnConnect = "sendOnConnect"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decodeIfPresent(WebSocketMessageID.self, forKey: .id)) ?? Self.derivedID(at: decoder.codingPath)
        format = (try? container.decodeIfPresent(WebSocketMessageFormat.self, forKey: .format)) ?? .text
        text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
        sendsOnConnect = try container.decodeIfPresent(Bool.self, forKey: .sendsOnConnect) ?? true
    }
}

/// Per-request overrides; `nil` uses the app default from Settings → Requests.
public struct WebSocketRequestOptions: Hashable, Sendable, Codable {
    /// Bounds connecting, TLS, and the server's answer to the handshake. An open connection never times out on its own.
    public var timeoutSeconds: Double?
    public var verifyTLS: Bool?
    /// Ping after this many seconds without a frame either way; `nil` never pings unasked, as browsers don't. A
    /// connection holds it to `keepaliveRange`.
    public var keepaliveSeconds: Double?

    /// The keepalive intervals a connection uses. A stored value outside is moved to the nearer end, so a value an agent
    /// or a hand edit gives can't overflow the timer.
    public static let keepaliveRange: ClosedRange<Double> = 1...3_600

    public init(timeoutSeconds: Double? = nil, verifyTLS: Bool? = nil, keepaliveSeconds: Double? = nil) {
        self.timeoutSeconds = timeoutSeconds
        self.verifyTLS = verifyTLS
        self.keepaliveSeconds = keepaliveSeconds
    }
}
