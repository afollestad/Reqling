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

/// How a response body renders: as highlighted text, an image, or a placeholder, plus the formats it offers.
struct ResponseBodyPresentation {
    enum Content {
        case text(TextDocument)
        case image(NSImage)
        case binary(byteCount: Int)
        case empty
        /// Still being shaped off the main actor; `pendingShape` names the work.
        case shaping
    }

    let content: Content
    let availableModes: [ResponseBodyMode]
    /// The mode shown: the preferred one when this body offers it, else its first.
    let mode: ResponseBodyMode?
    /// The work to start for `content` to arrive, while it is `.shaping`.
    let pendingShape: ResponseShapeKey?

    static let empty = ResponseBodyPresentation(content: .empty, availableModes: [], mode: nil, pendingShape: nil)
}

/// The latest exchange for one request, shaped for display.
///
/// Shaping a body (decoding it, pretty-printing a large JSON payload) runs once per exchange and mode: small bodies
/// inline, larger ones off the main actor through `ResponseViewModel+Shaping`, which the view starts from its
/// `.task(id: pendingShape)`, never from a getter.
@MainActor
@Observable
final class ResponseViewModel {
    var tab: ResponseTab = .body
    /// The format the person picked; a body that doesn't offer it shows its first one instead (`body.mode`).
    var bodyMode: ResponseBodyMode = .pretty

    let requestID: RequestNodeID
    let projectID: ProjectID
    /// Searching the body, whichever format shows it; the query carries over between formats.
    let search = BodySearchModel()
    @ObservationIgnored let runner: RequestRunner
    /// Results of background shaping for the exchange shown; writing it re-renders the body.
    var shapedBodies = ShapedBodies()
    @ObservationIgnored var inlineShapes = ShapedBodies()
    @ObservationIgnored var classification: BodyClassification?
    @ObservationIgnored var shapingKey: ResponseShapeKey?
    @ObservationIgnored var shapingTask: Task<ShapedBody, any Error>?
    @ObservationIgnored private var sentBodyCache: (startedAt: Date, document: TextDocument?)?

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
        // Read every observable input before consulting a cache, so observation keeps tracking them.
        let preference = bodyMode
        let shaped = shapedBodies
        guard let exchange, let response = exchange.response else {
            return .empty
        }
        return presentation(of: response, startedAt: exchange.startedAt, preference: preference, shaped: shaped)
    }

    /// The body the request sent, as text to show, highlighted by its Content-Type; `nil` when it sent none.
    var sentBody: TextDocument? {
        guard let exchange else {
            return nil
        }
        if let sentBodyCache, sentBodyCache.startedAt == exchange.startedAt {
            return sentBodyCache.document
        }
        let document = exchange.request.flatMap { request -> TextDocument? in
            guard let body = request.bodyPreview, !body.isEmpty else {
                return nil
            }
            let contentType = request.headers.first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }?.value
            return TextDocument(text: body, language: ContentTypeLanguage.language(forContentType: contentType))
        }
        sentBodyCache = (exchange.startedAt, document)
        return document
    }

    /// The format picker's selection: what `body` shows, writing the person's preference.
    var selectedBodyMode: ResponseBodyMode {
        get { body.mode ?? bodyMode }
        set { bodyMode = newValue }
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
