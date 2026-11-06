import Foundation

/// How two runs of one request differ, section by section: for HTTP, the response body (an event stream's events),
/// the response headers, and the request sent; for gRPC, the messages, the metadata and status, and the call sent.
/// Everything compared is what the history stores, so it is masked like the runs themselves.
public struct RunComparison: Sendable {
    public let sections: [RunComparisonSection]
}

/// One part of two runs compared, such as their bodies.
public struct RunComparisonSection: Sendable, Identifiable {
    public enum Content: Sendable {
        case diff(DiffDocument)
        /// Bytes that aren't text, so all that can be said is whether they match.
        case binary(identical: Bool)
    }

    public let title: String
    public let content: Content

    public var id: String {
        title
    }

    public var hasChanges: Bool {
        switch content {
        case .diff(let diff): diff.hasChanges
        case .binary(let identical): !identical
        }
    }
}

public enum RunComparer {
    /// Compares `older` with `newer`. JSON bodies are re-indented first (`JSONFormatter`), keeping key order, so two
    /// responses that differ only in whitespace read as identical. Throws once the current task is cancelled; a large
    /// body takes a while, so run it off the main actor.
    public static func compare(_ older: RequestExchange, _ newer: RequestExchange) throws(CancellationError) -> RunComparison {
        let old = try Facets(older)
        let new = try Facets(newer)
        var sections: [RunComparisonSection] = []
        // Every kind has three sections; titled as the newer run's, should the two ever be of different kinds.
        for index in new.titles.indices {
            sections.append(RunComparisonSection(title: new.titles[index], content: try content(old.sections[index], new.sections[index])))
        }
        return RunComparison(sections: sections)
    }

    private static func content(_ old: Facets.Body, _ new: Facets.Body) throws(CancellationError) -> RunComparisonSection.Content {
        switch (old, new) {
        case (.binary(let oldBytes), .binary(let newBytes)):
            return .binary(identical: oldBytes == newBytes)
        default:
            let language = old.language == new.language ? old.language : .plainText
            return .diff(try DiffDocument.make(old: old.text, new: new.text, language: language))
        }
    }
}

/// One run as the texts a comparison diffs. Every kind's runs yield three sections, titled by `titles`, so a comparison
/// of two runs of one request lines them up by position.
private struct Facets {
    enum Body {
        case text(String, SyntaxLanguage)
        case binary(Data)

        var text: String {
            switch self {
            case .text(let text, _): text
            case .binary(let bytes): ByteCountFormatter.string(fromByteCount: Int64(bytes.count), countStyle: .file) + " of binary data"
            }
        }

        var language: SyntaxLanguage {
            switch self {
            case .text(_, let language): language
            case .binary: .plainText
            }
        }
    }

    let titles: [String]
    let sections: [Body]

    /// By the outcome's kind, or for a failure the spec's, so a failed run lines up with the request's other runs.
    init(_ exchange: RequestExchange) throws(CancellationError) {
        let kind: RequestKind.Name = switch exchange.outcome {
        case .response: .http
        case .grpc: .grpc
        case .webSocket: .webSocket
        case .failure: exchange.spec?.name ?? .http
        }
        switch kind {
        case .grpc:
            titles = ["Messages", "Metadata", "Request"]
            let call = exchange.grpc
            sections = [
                .text(call.map(Self.messages) ?? Self.failureText(exchange), .plainText),
                .text(call.map(Self.metadata) ?? "", .plainText),
                .text(call.map(Self.callRequest) ?? "", .plainText)
            ]
        case .webSocket:
            titles = ["Messages", "Handshake", "Request"]
            let record = exchange.webSocket
            sections = [
                .text(record.map(Self.messages) ?? Self.failureText(exchange), .plainText),
                .text(record.map(Self.handshake) ?? "", .plainText),
                .text(exchange.request.map(Self.httpRequest) ?? "", .plainText)
            ]
        case .http:
            let response = exchange.response
            titles = [response?.eventStream == nil ? "Body" : "Events", "Headers", "Request"]
            sections = [
                try response.map(Self.body) ?? .text(Self.failureText(exchange), .plainText),
                .text(response.map { Self.headerLines($0.headers) } ?? "", .plainText),
                .text(exchange.request.map(Self.httpRequest) ?? "", .plainText)
            ]
        }
    }

    private static func failureText(_ exchange: RequestExchange) -> String {
        exchange.failure.map { "No response: \($0.message)" } ?? ""
    }

    private static func body(_ response: HTTPResponseRecord) throws(CancellationError) -> Body {
        if let stream = response.eventStream {
            return .text(events(stream), .plainText)
        }
        let contentType = response.header("Content-Type")
        switch ResponseBodyShaper.classify(response.body, contentType: contentType) {
        case .empty:
            return .text("", .plainText)
        case .json:
            if let pretty = try JSONFormatter.pretty(response.body), let text = String(bytes: pretty, encoding: .utf8) {
                return .text(text, .json)
            }
        case .image:
            return .binary(response.body)
        case .xml, .text:
            break
        }
        guard let text = String(data: response.body, encoding: .utf8) else {
            return .binary(response.body)
        }
        return .text(text, ContentTypeLanguage.language(forContentType: contentType))
    }

    /// Sorted by name, so two servers' orderings don't read as changes.
    private static func headerLines(_ headers: [KeyValuePair]) -> String {
        headers
            .map { "\($0.key): \($0.value)" }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .joined(separator: "\n")
    }

    private static func httpRequest(_ request: ResolvedHTTPRequest) -> String {
        var lines = ["\(request.method) \(request.url)"]
        if !request.headers.isEmpty {
            lines += ["", headerLines(request.headers)]
        }
        if let body = request.bodyPreview, !body.isEmpty {
            lines += ["", JSONFormatter.pretty(body) ?? body]
        }
        return lines.joined(separator: "\n")
    }

    /// Each message under a line naming its direction and place in the call.
    private static func messages(_ call: GRPCCallRecord) -> String {
        call.events.map { event in
            let heading = event.direction == .sent ? "→ Sent #\(event.sequence + 1)" : "← Received #\(event.sequence + 1)"
            return heading + "\n" + (JSONFormatter.pretty(event.json) ?? event.json)
        }
        .joined(separator: "\n\n")
    }

    /// Each event under a line naming its type and ID, its data re-indented when it is JSON, with the notes between.
    private static func events(_ stream: EventStreamRecord) -> String {
        stream.entries.map { entry in
            switch entry.kind {
            case .event(let event):
                let heading = "event: \(event.type)" + (event.id.map { " · id: \($0)" } ?? "")
                return heading + "\n" + (JSONFormatter.pretty(event.data) ?? event.data)
            case .note(let note):
                return "— \(note)"
            }
        }
        .joined(separator: "\n\n")
    }

    /// Each message under a line naming its direction and place in the connection, with pings, closes, and notes
    /// between.
    private static func messages(_ record: WebSocketRecord) -> String {
        record.entries.map { entry in
            switch entry.kind {
            case .message(let message):
                let direction = message.direction == .sent ? "→ Sent" : "← Received"
                let format = message.isBase64 ? " (base64)" : ""
                let text = message.isBase64 ? message.text : JSONFormatter.pretty(message.text) ?? message.text
                return "\(direction) #\(entry.sequence + 1)\(format)\n\(text)"
            case .control(let direction, let text):
                return "\(direction == .sent ? "→" : "←") \(text)"
            case .note(let note):
                return "— \(note)"
            }
        }
        .joined(separator: "\n\n")
    }

    /// The server's answer and how the connection ended.
    private static func handshake(_ record: WebSocketRecord) -> String {
        var lines: [String] = []
        if let head = record.handshake {
            lines.append("Status: \(head.statusCode) \(head.reasonPhrase)")
            if !head.headers.isEmpty {
                lines += ["", headerLines(head.headers)]
            }
            if let body = String(data: head.body, encoding: .utf8), !body.isEmpty {
                lines += ["", JSONFormatter.pretty(body) ?? body]
            }
        }
        if let close = record.close {
            let reason = close.reason.isEmpty ? "" : ": \(close.reason)"
            lines += ["", "Close: \(close.title) by the \(close.byServer ? "server" : "client")\(reason)"]
        }
        switch record.end {
        case .refused(let message), .failed(let message):
            lines += ["", message]
        case .closed, .stopped, .limit, nil:
            break
        }
        return lines.joined(separator: "\n")
    }

    private static func metadata(_ call: GRPCCallRecord) -> String {
        var lines: [String] = []
        if let status = call.status {
            lines.append("Status: \(status.name) (\(status.code))" + (status.message.isEmpty ? "" : " \(status.message)"))
        }
        if !call.initialMetadata.isEmpty {
            lines += ["", "Initial metadata", headerLines(call.initialMetadata)]
        }
        if !call.trailers.isEmpty {
            lines += ["", "Trailers", headerLines(call.trailers)]
        }
        return lines.joined(separator: "\n")
    }

    private static func callRequest(_ call: GRPCCallRecord) -> String {
        var lines = ["\(call.target) \(call.method)"]
        if !call.sentMetadata.isEmpty {
            lines += ["", headerLines(call.sentMetadata)]
        }
        return lines.joined(separator: "\n")
    }
}
