import Foundation

/// A WebSocket request's handshake is an HTTP GET built by `HTTPRequestBuilder`, so its auth (inherited ones included),
/// API keys in the query, `{{variables}}`, and masked summary are exactly an HTTP request's.
extension WebSocketRequestSpec {
    /// The headers the connection writes itself, so a typed copy is dropped rather than sent twice
    /// (`WebSocketHandshake.reservedHeaders`); lower-cased.
    public static let connectionHeaders: Set<String> = ["host", "upgrade", "connection", "sec-websocket-key", "sec-websocket-version"]

    /// Never redirected (browsers don't follow a handshake's redirects), with no `Accept`, which means nothing to an
    /// upgrade. `Sec-WebSocket-Protocol` comes from `subprotocols` and `Origin` from the URL, each only where no typed
    /// header names it.
    public var handshake: HTTPRequestSpec {
        var headers = headers
        let typed = Set(headers.filter(\.isEnabled).map { $0.key.lowercased() })
        if !subprotocols.isEmpty, !typed.contains("sec-websocket-protocol") {
            headers.append(KeyValuePair(key: "Sec-WebSocket-Protocol", value: subprotocols.joined(separator: ", ")))
        }
        if enabledAutoHeaders.contains("origin"), !typed.contains("origin"), let origin = Self.origin(for: url) {
            headers.append(KeyValuePair(key: "Origin", value: origin))
        }
        return HTTPRequestSpec(
            method: .get,
            url: url,
            queryParameters: queryParameters,
            headers: headers,
            disabledAutoHeaders: disabledAutoHeaders + ["accept"],
            auth: auth,
            options: HTTPRequestOptions(timeoutSeconds: options.timeoutSeconds, followRedirects: false, verifyTLS: options.verifyTLS)
        )
    }

    /// The origin a browser page on the socket's own host would send: `wss` and `https` as `https`, anything else as
    /// `http`, with the URL's host and port. Worked out from the text, `{{variables}}` and all, so they resolve with the
    /// rest of the handshake; `nil` when the URL has no host yet.
    public static func origin(for url: String) -> String? {
        var text = Substring(url.trimmingCharacters(in: .whitespaces))
        var scheme = "http"
        if let separator = text.range(of: "://") {
            let given = text[..<separator.lowerBound].lowercased()
            scheme = given == "wss" || given == "https" ? "https" : "http"
            text = text[separator.upperBound...]
        }
        let authority = text.prefix { !"/?#".contains($0) }
        return authority.isEmpty ? nil : "\(scheme)://\(authority)"
    }

    /// Whether `header` goes out: one on by default until turned off, one off by default once turned on.
    public func sends(_ header: AutoHeader) -> Bool {
        header.isOnByDefault ? !disabledAutoHeaders.contains(header.key) : enabledAutoHeaders.contains(header.key)
    }

    public mutating func setSends(_ header: AutoHeader, _ isOn: Bool) {
        if header.isOnByDefault {
            var disabled = Set(disabledAutoHeaders)
            if isOn {
                disabled.remove(header.key)
            } else {
                disabled.insert(header.key)
            }
            disabledAutoHeaders = disabled.sorted()
        } else {
            var enabled = Set(enabledAutoHeaders)
            if isOn {
                enabled.insert(header.key)
            } else {
                enabled.remove(header.key)
            }
            enabledAutoHeaders = enabled.sorted()
        }
    }
}

extension HTTPRequestBuilder {
    /// The headers a WebSocket handshake gets beyond the user's, as the editor lists them. The connection writes the
    /// fixed ones itself (`WebSocketHandshake.reservedHeaders`), so typed copies of those are dropped rather than sent.
    public static func autoHeaders(for spec: WebSocketRequestSpec, userAgent: String) -> [AutoHeader] {
        var headers = [
            AutoHeader(name: "User-Agent", value: userAgent, isOverridable: true),
            AutoHeader(
                name: "Origin",
                value: WebSocketRequestSpec.origin(for: spec.url) ?? "From the URL",
                isOverridable: true,
                isOnByDefault: false
            )
        ]
        if !spec.subprotocols.isEmpty {
            headers.append(AutoHeader(name: "Sec-WebSocket-Protocol", value: spec.subprotocols.joined(separator: ", "), isOverridable: false))
        }
        headers += [
            AutoHeader(name: "Host", value: "From the URL", isOverridable: false),
            AutoHeader(name: "Upgrade", value: "websocket", isOverridable: false),
            AutoHeader(name: "Connection", value: "Upgrade", isOverridable: false),
            AutoHeader(name: "Sec-WebSocket-Key", value: "New for each connection", isOverridable: false),
            AutoHeader(name: "Sec-WebSocket-Version", value: "13", isOverridable: false),
            AutoHeader(name: "Cookie", value: "From the project's cookies", isOverridable: false)
        ]
        return headers
    }
}
