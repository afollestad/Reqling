import Foundation

/// The result of importing a cURL command.
public struct CurlImport: Hashable, Sendable {
    public var spec: HTTPRequestSpec
    /// Things the import could not carry over, such as unsupported flags or `@file` arguments.
    public var warnings: [String]
}

public enum CurlImportError: Error, Equatable, LocalizedError {
    case notACurlCommand
    case missingURL
    case missingValue(String)
    case unterminatedQuote

    public var errorDescription: String? {
        switch self {
        case .notACurlCommand: "That is not a cURL command."
        case .missingURL: "The cURL command has no URL."
        case .missingValue(let flag): "\(flag) needs a value."
        case .unterminatedQuote: "The cURL command has an unterminated quote."
        }
    }
}

/// Imports cURL commands (as browsers' "Copy as cURL" and API docs write them) and exports requests as cURL.
///
/// Import supports `-X`, `-H`, `-d`/`--data*`, `--data-urlencode`, `--json`, `-F`/`--form-string`, `-u`,
/// `--oauth2-bearer`, `-G`, `-I`, `-k`, `-L`, `-A`, `-e`, `-b`, `-m`/`--max-time`, `--connect-timeout`, and `--url`,
/// with single, double, and `$'…'` quoting and line continuations. Other options are skipped with a warning, their
/// values included, so a value is never mistaken for the URL.
public enum CurlCodec {
    public static func looksLikeCurl(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("curl ")
    }

    public static func importCommand(_ command: String) throws(CurlImportError) -> CurlImport {
        var words = try tokenize(command)
        guard words.first?.lowercased() == "curl" else {
            throw .notACurlCommand
        }
        words.removeFirst()
        var parser = Parser()
        try parser.parse(words)
        return try parser.result()
    }

    /// The request as a cURL command; pass `masked: true` to export the secret-masked summary instead of real values.
    ///
    /// A body that is not text (or, masked, was cut to the preview limit) becomes `--data-binary @body.bin`, a file for
    /// the user to supply. No shell comment marks it: a `#` would swallow the trailing `\` and split the command.
    public static func export(_ request: PreparedHTTPRequest, masked: Bool = false) -> String {
        var lines: [String]
        let headers: [KeyValuePair]
        let body: String?
        if masked {
            lines = ["curl -X \(request.summary.method) \(quote(request.summary.url))"]
            headers = request.summary.headers
            let isComplete = request.summary.bodyByteCount <= ResolvedHTTPRequest.bodyPreviewLimit
            body = isComplete ? request.summary.bodyPreview : nil
        } else {
            let urlRequest = request.urlRequest
            lines = ["curl -X \(urlRequest.httpMethod ?? "GET") \(quote(urlRequest.url?.absoluteString ?? ""))"]
            headers = (urlRequest.allHTTPHeaderFields ?? [:])
                .map { KeyValuePair(key: $0.key, value: $0.value) }
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            body = urlRequest.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        }
        for header in headers {
            lines.append("-H \(quote("\(header.key): \(header.value)"))")
        }
        if request.summary.bodyByteCount > 0 {
            lines.append(body.map { "--data-raw \(quote($0))" } ?? "--data-binary @body.bin")
        }
        if request.followRedirects {
            lines.append("-L")
        }
        if !request.verifyTLS {
            lines.append("-k")
        }
        return lines.joined(separator: " \\\n  ")
    }

    /// Single-quotes a word for a POSIX shell.
    static func quote(_ word: String) -> String {
        "'" + word.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Splits a shell command into words the way a POSIX shell would for the quoting forms cURL commands use.
    static func tokenize(_ command: String) throws(CurlImportError) -> [String] {
        var tokenizer = ShellTokenizer(command)
        return try tokenizer.words()
    }
}

private struct Parser {
    /// One `-d`-family argument, kept in order: cURL joins them all into one body.
    enum DataPiece {
        /// `-d`, `--data-raw`, `--data-binary`, `--data-ascii`: sent as written.
        case raw(String)
        /// `--json`: sent as written, and cURL concatenates these without `&`.
        case json(String)
        /// `--data-urlencode`: the content is percent-encoded, behind `name=` when there is a name.
        case urlEncoded(name: String?, content: String)

        var isJSON: Bool {
            if case .json = self { true } else { false }
        }
    }

    var method: String?
    var url: String?
    var headers: [KeyValuePair] = []
    var data: [DataPiece] = []
    var formFields: [MultipartField] = []
    var auth: HTTPAuth = .inherit
    var useGet = false
    var useHead = false
    var options = HTTPRequestOptions()
    var warnings: [String] = []

    /// Options that take a value. Every one must be listed, handled or not, or its value would be read as the URL.
    static let valueFlags: Set<String> = handledValueFlags.union(skippedValueFlags).union(unsupportedValueFlags)
    static let handledValueFlags: Set<String> = [
        "-X", "--request", "-H", "--header", "-d", "--data", "--data-raw", "--data-binary", "--data-ascii",
        "--data-urlencode", "--json", "-F", "--form", "--form-string", "-u", "--user", "--oauth2-bearer", "-A",
        "--user-agent", "-e", "--referer", "-b", "--cookie", "--url", "-m", "--max-time", "--connect-timeout"
    ]
    /// Options that only shape cURL's own output or retries; skipped without a warning.
    static let skippedValueFlags: Set<String> = [
        "-o", "--output", "--output-dir", "-w", "--write-out", "-D", "--dump-header", "-c", "--cookie-jar", "--stderr",
        "--trace", "--trace-ascii", "--trace-config", "--libcurl", "--retry", "--retry-delay", "--retry-max-time",
        "--max-redirs", "--limit-rate", "--rate", "--parallel-max", "--create-file-mode", "--etag-save", "--etag-compare"
    ]
    /// Options Reqling cannot carry over; skipped with a warning.
    static let unsupportedValueFlags: Set<String> = [
        "-x", "--proxy", "-U", "--proxy-user", "--proxy-header", "--preproxy", "--noproxy", "--socks4", "--socks4a",
        "--socks5", "--socks5-hostname", "--cacert", "--capath", "-E", "--cert", "--cert-type", "--key", "--key-type",
        "--pass", "--ciphers", "--tls13-ciphers", "--curves", "--tls-max", "--pinnedpubkey", "--crlfile",
        "--proxy-cacert", "--proxy-cert", "--proxy-key", "--proxy-pass", "-T", "--upload-file", "-r", "--range",
        "-C", "--continue-at", "--resolve", "--connect-to", "--interface", "--local-port", "--dns-servers", "--doh-url",
        "-K", "--config", "--netrc-file", "--proto", "--proto-redir", "--proto-default", "--unix-socket",
        "--abstract-unix-socket", "--aws-sigv4", "--request-target", "--url-query", "--variable", "-z", "--time-cond",
        "-Y", "--speed-limit", "-y", "--speed-time", "--expect100-timeout", "--keepalive-time", "--max-filesize",
        "--hsts", "--alt-svc", "--happy-eyeballs-timeout-ms", "--ip-tos", "--login-options", "--sasl-authzid",
        "--service-name", "--mail-from", "--mail-rcpt", "--mail-auth", "-Q", "--quote", "-P", "--ftp-port", "-t",
        "--telnet-option", "--engine", "--delegation", "--krb", "--tlsuser", "--tlspassword", "--tlsauthtype",
        "--socks5-gssapi-service", "--proxy-service-name", "--ftp-method", "--ftp-account", "--ftp-alternative-to-user",
        "--ftp-ssl-ccc-mode", "--pubkey", "--hostpubmd5", "--hostpubsha256", "--knownhosts", "--dns-interface",
        "--dns-ipv4-addr", "--dns-ipv6-addr", "--proxy-ciphers", "--proxy-tls13-ciphers", "--proxy-capath",
        "--proxy-cert-type", "--proxy-key-type", "--proxy-crlfile", "--proxy-pinnedpubkey", "--proxy-tlsuser",
        "--proxy-tlspassword", "--proxy-tlsauthtype", "--proxy1.0", "--haproxy-clientip", "--ech", "--egd-file",
        "--random-file", "--ipfs-gateway", "--keepalive-cnt", "--tftp-blksize", "--vlan-priority", "--sigalgs",
        "--ssl-sessions", "--upload-flags"
    ]
    static let ignoredSwitches: Set<String> = [
        "-s", "--silent", "-S", "--show-error", "-v", "--verbose", "-i", "--include", "--compressed", "--http1.1",
        "--http2", "--http2-prior-knowledge", "-#", "--progress-bar", "-f", "--fail", "--fail-with-body",
        "--no-progress-meter", "-N", "--no-buffer", "-g", "--globoff", "-4", "--ipv4", "-6", "--ipv6", "-q", "--disable",
        "--tlsv1.2", "--tlsv1.3", "--path-as-is", "--tcp-nodelay", "--no-keepalive"
    ]

    mutating func parse(_ words: [String]) throws(CurlImportError) {
        var remaining = words[...]
        while let word = remaining.popFirst() {
            if word.hasPrefix("--") {
                try parseLongOption(word, remaining: &remaining)
            } else if word.hasPrefix("-"), word.count > 1 {
                try parseShortOptions(word, remaining: &remaining)
            } else if url == nil {
                url = word
            } else {
                warnings.append("Ignored the extra argument “\(word)”.")
            }
        }
    }

    /// `--flag`, `--flag value`, or `--flag=value`.
    private mutating func parseLongOption(_ word: String, remaining: inout ArraySlice<String>) throws(CurlImportError) {
        if let equals = word.firstIndex(of: "="), Self.valueFlags.contains(String(word[..<equals])) {
            try apply(String(word[..<equals]), value: String(word[word.index(after: equals)...]))
        } else if Self.valueFlags.contains(word) {
            guard let value = remaining.popFirst() else {
                throw .missingValue(word)
            }
            try apply(word, value: value)
        } else {
            try apply(word, value: nil)
        }
    }

    /// A bundle of short options (`-sSL`, `-XPOST`, `-sXPOST`, `-sH 'A: b'`): the first option that takes a value takes
    /// the rest of the bundle, or the next word when nothing is left.
    private mutating func parseShortOptions(_ word: String, remaining: inout ArraySlice<String>) throws(CurlImportError) {
        var letters = word.dropFirst()
        while let letter = letters.popFirst() {
            let flag = "-\(letter)"
            guard Self.valueFlags.contains(flag) else {
                try apply(flag, value: nil)
                continue
            }
            if !letters.isEmpty {
                try apply(flag, value: String(letters))
            } else if let value = remaining.popFirst() {
                try apply(flag, value: value)
            } else {
                throw .missingValue(flag)
            }
            return
        }
    }

    mutating func apply(_ flag: String, value: String?) throws(CurlImportError) {
        let value = value ?? ""
        if applyBody(flag, value: value) {
            return
        }
        switch flag {
        case "-X", "--request":
            method = value
        case "-H", "--header":
            addHeader(value)
        case "-u", "--user":
            let (username, password) = Self.split(value, at: ":")
            auth = .basic(username: username, password: password)
        case "--oauth2-bearer":
            auth = .bearer(token: value)
        case "-A", "--user-agent":
            headers.append(KeyValuePair(key: "User-Agent", value: value))
        case "-e", "--referer":
            headers.append(KeyValuePair(key: "Referer", value: value))
        case "-b", "--cookie":
            headers.append(KeyValuePair(key: "Cookie", value: value))
        case "--url":
            url = value
        case "-m", "--max-time", "--connect-timeout":
            options.timeoutSeconds = Double(value)
        case "-G", "--get":
            useGet = true
        case "-I", "--head":
            useHead = true
        case "-k", "--insecure":
            options.verifyTLS = false
        case "-L", "--location", "--location-trusted":
            options.followRedirects = true
        case _ where Self.skippedValueFlags.contains(flag) || Self.ignoredSwitches.contains(flag):
            break
        default:
            warnings.append("Ignored the unsupported option \(flag).")
        }
    }

    /// The `-d` family and forms; returns whether `flag` was one of them.
    private mutating func applyBody(_ flag: String, value: String) -> Bool {
        switch flag {
        case "-d", "--data", "--data-binary", "--data-ascii", "--json":
            if value.hasPrefix("@") {
                warnings.append("The body was read from a file (\(value)); choose that file in the Body tab.")
            }
            data.append(flag == "--json" ? .json(value) : .raw(value))
        case "--data-raw":
            data.append(.raw(value))
        case "--data-urlencode":
            addURLEncoded(value)
        case "-F", "--form":
            addFormField(value, literal: false)
        case "--form-string":
            addFormField(value, literal: true)
        default:
            return false
        }
        return true
    }

    mutating func addHeader(_ value: String) {
        guard value.contains(":") else {
            warnings.append("Ignored a header without a colon.")
            return
        }
        let (name, headerValue) = Self.split(value, at: ":")
        headers.append(KeyValuePair(key: name.trimmingCharacters(in: .whitespaces), value: headerValue.trimmingCharacters(in: .whitespaces)))
    }

    /// cURL's forms: `content` and `=content` encode the content alone, `name=content` keeps the name, and with no `=`,
    /// `@file` or `name@file` read the content from a file, which an import cannot do.
    mutating func addURLEncoded(_ argument: String) {
        if let equals = argument.firstIndex(of: "=") {
            let name = String(argument[..<equals])
            data.append(.urlEncoded(name: name.isEmpty ? nil : name, content: String(argument[argument.index(after: equals)...])))
        } else if let atSign = argument.firstIndex(of: "@") {
            let name = String(argument[..<atSign])
            let file = String(argument[argument.index(after: atSign)...])
            if name.isEmpty {
                warnings.append("Skipped --data-urlencode content read from a file (\(file)).")
            } else {
                warnings.append("The “\(name)” value was read from a file (\(file)); fill it in by hand.")
                data.append(.urlEncoded(name: name, content: ""))
            }
        } else {
            data.append(.urlEncoded(name: nil, content: argument))
        }
    }

    mutating func addFormField(_ value: String, literal: Bool) {
        let (name, content) = Self.split(value, at: "=")
        if !literal, content.hasPrefix("@") || content.hasPrefix("<") {
            formFields.append(MultipartField(key: name, kind: .file))
            warnings.append("Choose the file for the “\(name)” form field.")
        } else {
            formFields.append(MultipartField(key: name, value: content))
        }
    }

    /// Splits at the first `separator`; the second half is empty when there is none.
    static func split(_ text: String, at separator: Character) -> (String, String) {
        guard let index = text.firstIndex(of: separator) else {
            return (text, "")
        }
        return (String(text[..<index]), String(text[text.index(after: index)...]))
    }

    func result() throws(CurlImportError) -> CurlImport {
        guard let url, !url.isEmpty else {
            throw .missingURL
        }
        var spec = HTTPRequestSpec(url: url, headers: headers, auth: auth, options: options).normalized()
        let isJSON = data.contains(where: \.isJSON)
        if useGet {
            for piece in data {
                switch piece {
                case .raw(let text), .json(let text):
                    spec.queryParameters += HTTPRequestSpec.parseQuery(text)
                case .urlEncoded(let name, let content):
                    // The builder keeps `%XX` escapes as typed, so a literal `%` must become `%25` here, as cURL encodes
                    // it (`100%41` goes out as `100%2541`). A nameless piece is a bare query item.
                    let content = content.replacingOccurrences(of: "%", with: "%25")
                    spec.queryParameters.append(name.map { KeyValuePair(key: $0, value: content) } ?? KeyValuePair(key: content, value: ""))
                }
            }
        } else if !formFields.isEmpty {
            spec.body = HTTPBody(mode: .formData, formData: formFields)
        } else if let pairs = namedURLEncodedPairs() {
            spec.body = HTTPBody(mode: .urlEncoded, urlEncoded: pairs)
        } else if !data.isEmpty {
            // cURL sends data as a form unless a Content-Type says otherwise.
            let contentTypeIndex = spec.headers.firstIndex { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }
            let contentType = contentTypeIndex.map { spec.headers[$0].value } ?? (isJSON ? "application/json" : "application/x-www-form-urlencoded")
            if let contentTypeIndex {
                spec.headers.remove(at: contentTypeIndex)
            }
            spec.body = .raw(joinedData(), contentType: contentType)
        }
        if isJSON, !spec.headers.contains(where: { $0.key.caseInsensitiveCompare("Accept") == .orderedSame }) {
            spec.headers.append(KeyValuePair(key: "Accept", value: "application/json"))
        }
        let hasBody = !useGet && (!data.isEmpty || !formFields.isEmpty)
        spec.method = HTTPMethod(rawValue: method ?? (useHead ? "HEAD" : hasBody ? "POST" : "GET"))
        return CurlImport(spec: spec, warnings: warnings)
    }

    /// The pieces as an editable form table, when every one is a named `--data-urlencode` whose name the table would
    /// send unchanged. cURL sends names as written, while the table form-encodes them, so a name such as `a%20b`
    /// stays in a raw body instead.
    private func namedURLEncodedPairs() -> [KeyValuePair]? {
        guard !data.isEmpty else {
            return nil
        }
        var pairs: [KeyValuePair] = []
        for piece in data {
            guard case .urlEncoded(let name?, let content) = piece, name.unicodeScalars.allSatisfy(Self.formSafe.contains) else {
                return nil
            }
            pairs.append(KeyValuePair(key: name, value: content))
        }
        return pairs
    }

    /// The body cURL would send: pieces joined with `&` (`--json` pieces directly), `--data-urlencode` content encoded.
    private func joinedData() -> String {
        var body = ""
        for (index, piece) in data.enumerated() {
            let text: String
            switch piece {
            case .raw(let raw):
                text = raw
            case .json(let json):
                text = json
            case .urlEncoded(let name, let content):
                let encoded = content.addingPercentEncoding(withAllowedCharacters: Self.unreserved) ?? content
                text = name.map { "\($0)=\(encoded)" } ?? encoded
            }
            if index > 0, !piece.isJSON {
                body += "&"
            }
            body += text
        }
        return body
    }

    /// What cURL's `--data-urlencode` leaves unescaped (RFC 3986 unreserved).
    private static let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
    /// What `HTTPEncoding.formComponent` leaves unescaped.
    private static let formSafe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789*-._")
}
