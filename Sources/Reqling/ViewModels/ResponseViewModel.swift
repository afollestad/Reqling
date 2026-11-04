import AppKit
import Foundation
import Observation
import ReqlingKit

enum ResponseTab: String, CaseIterable, Identifiable {
    case body = "Body"
    case headers = "Headers"
    case timing = "Timing"
    case request = "Request"

    var id: Self {
        self
    }
}

enum ResponseBodyMode: String, CaseIterable, Identifiable {
    case pretty = "Pretty"
    case raw = "Raw"
    case preview = "Preview"

    var id: Self {
        self
    }
}

/// How a response body renders: as highlighted text, an image, or a binary placeholder.
struct ResponseBodyPresentation {
    enum Content {
        case text(String, SyntaxLanguage)
        case image(NSImage)
        case binary(byteCount: Int)
        case empty
    }

    let content: Content
    let availableModes: [ResponseBodyMode]
}

/// The latest exchange for one request, shaped for display. Body shaping (pretty-printing a large JSON payload) is
/// memoized per exchange and mode, so a re-render never repeats it.
@MainActor
@Observable
final class ResponseViewModel {
    var tab: ResponseTab = .body
    var bodyMode: ResponseBodyMode = .pretty

    let requestID: RequestNodeID
    let projectID: ProjectID
    @ObservationIgnored private let runner: RequestRunner
    @ObservationIgnored private var cache: (key: CacheKey, value: ResponseBodyPresentation)?

    private struct CacheKey: Equatable {
        let startedAt: Date
        let mode: ResponseBodyMode
    }

    init(requestID: RequestNodeID, projectID: ProjectID, runner: RequestRunner) {
        self.requestID = requestID
        self.projectID = projectID
        self.runner = runner
        _ = runner.exchange(for: requestID, in: projectID)
    }

    var exchange: RequestExchange? {
        runner.latest[RunKey(requestID, in: projectID)]
    }

    var isSending: Bool {
        runner.isInFlight(requestID, in: projectID)
    }

    var body: ResponseBodyPresentation {
        // Read every observable input before consulting the cache, so observation keeps tracking them.
        let mode = bodyMode
        guard let exchange, let response = exchange.response else {
            return ResponseBodyPresentation(content: .empty, availableModes: [])
        }
        let key = CacheKey(startedAt: exchange.startedAt, mode: mode)
        if let cache, cache.key == key {
            return cache.value
        }
        let value = Self.present(response, mode: mode)
        cache = (key, value)
        return value
    }

    func copyBody(to system: any SystemIntegration) {
        guard let body = exchange?.response?.body, let text = String(bytes: body, encoding: .utf8) else {
            return
        }
        system.copyToPasteboard(text)
    }

    func saveBody(with system: any SystemIntegration) {
        guard let response = exchange?.response,
              let url = system.chooseSaveLocation(suggestedName: Self.suggestedFileName(for: response)) else {
            return
        }
        try? response.body.write(to: url, options: .atomic)
    }

    private static func present(_ response: HTTPResponseRecord, mode: ResponseBodyMode) -> ResponseBodyPresentation {
        let contentType = response.header("Content-Type")
        guard !response.body.isEmpty else {
            return ResponseBodyPresentation(content: .empty, availableModes: [])
        }
        if contentType?.lowercased().hasPrefix("image/") == true, let image = NSImage(data: response.body) {
            let modes: [ResponseBodyMode] = [.preview]
            return ResponseBodyPresentation(content: .image(image), availableModes: modes)
        }
        guard let text = String(bytes: response.body, encoding: .utf8) else {
            return ResponseBodyPresentation(content: .binary(byteCount: response.body.count), availableModes: [])
        }
        var language = ContentTypeLanguage.language(forContentType: contentType)
        if language == .plainText, looksLikeJSON(text), response.body.count < 5_000_000,
           (try? JSONSerialization.jsonObject(with: response.body)) != nil {
            // Many APIs label JSON as text/plain; trust the content when it parses as such.
            language = .json
        }
        let modes: [ResponseBodyMode] = language == .json ? [.pretty, .raw] : [.raw]
        if mode == .pretty, language == .json, let pretty = JSONFormatter.pretty(text) {
            return ResponseBodyPresentation(content: .text(pretty, .json), availableModes: modes)
        }
        return ResponseBodyPresentation(content: .text(text, language), availableModes: modes)
    }

    private static func looksLikeJSON(_ text: String) -> Bool {
        guard let first = text.first(where: { !$0.isWhitespace }) else {
            return false
        }
        return first == "{" || first == "["
    }

    private static func suggestedFileName(for response: HTTPResponseRecord) -> String {
        let last = URL(string: response.url)?.lastPathComponent ?? ""
        return last.isEmpty || last == "/" ? "response" : last
    }
}

extension Error {
    /// The run's own message for `RunFailure`, the localized description otherwise.
    var message: String {
        (self as? RunFailure)?.message ?? localizedDescription
    }
}
