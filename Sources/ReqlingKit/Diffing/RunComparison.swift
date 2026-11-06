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
        // Both kinds have three sections; titled as the newer run's, should the two ever be of different kinds.
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

/// One run as the texts a comparison diffs. HTTP and gRPC runs both yield three sections, titled by `titles`, so a
/// comparison of two runs of one request lines them up by position.
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

    init(_ exchange: RequestExchange) throws(CancellationError) {
        if exchange.grpc != nil || exchange.spec?.name == .grpc {
            titles = ["Messages", "Metadata", "Request"]
            let call = exchange.grpc
            sections = [
                .text(call.map(Self.messages) ?? Self.failureText(exchange), .plainText),
                .text(call.map(Self.metadata) ?? "", .plainText),
                .text(call.map(Self.callRequest) ?? "", .plainText)
            ]
        } else {
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
