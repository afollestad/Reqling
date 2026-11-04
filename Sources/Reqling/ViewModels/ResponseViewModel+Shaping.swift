import AppKit
import Foundation
import ReqlingKit

/// Which shaped body the response pane wants: one exchange's body in one mode.
struct ResponseShapeKey: Hashable, Sendable {
    let startedAt: Date
    let mode: ResponseBodyMode
}

/// An exchange's body format, and its image when it decodes as one; `ResponseViewModel` keeps the latest.
struct BodyClassification {
    let startedAt: Date
    let format: BodyFormat
    let image: NSImage?
}

/// Shaped bodies for one exchange, by mode; storing one for another exchange drops the rest.
struct ShapedBodies {
    private(set) var startedAt: Date?
    private var bodies: [ResponseBodyMode: ShapedBody] = [:]

    subscript(key: ResponseShapeKey) -> ShapedBody? {
        startedAt == key.startedAt ? bodies[key.mode] : nil
    }

    /// The format a finished shape of this exchange settled on, which beats `ResponseBodyShaper.classify`'s guess.
    func format(for startedAt: Date) -> BodyFormat? {
        self.startedAt == startedAt ? bodies.values.first?.format : nil
    }

    mutating func store(_ body: ShapedBody, for key: ResponseShapeKey) {
        if startedAt != key.startedAt {
            startedAt = key.startedAt
            bodies = [:]
        }
        bodies[key.mode] = body
    }
}

/// Shaping response bodies: small ones inline in `body`, larger ones in a background task the view starts.
///
/// The task is the view model's, not the view's, so switching to the Headers tab and back doesn't restart it. A result
/// lands only while its key is still the one wanted: a newer exchange or another mode cancels it instead.
extension ResponseViewModel {
    /// Bodies up to this size shape inline, faster than a frame even for pretty-printed JSON, so they never flash a
    /// progress indicator.
    static let inlineShapingLimit = 256 * 1024

    func presentation(
        of response: HTTPResponseRecord,
        in exchange: RequestExchange,
        preference: ResponseBodyMode,
        shaped: ShapedBodies
    ) -> ResponseBodyPresentation {
        let startedAt = exchange.startedAt
        let (classified, image) = classify(response, startedAt: startedAt)
        if let image {
            return ResponseBodyPresentation(content: .image(image), availableModes: [.preview], mode: .preview, pendingShape: nil)
        }
        if classified == .empty {
            return .empty
        }
        let format = shaped.format(for: startedAt) ?? inlineShapes.format(for: startedAt) ?? classified
        let modes = Self.modes(for: format)
        let mode = modes.contains(preference) ? preference : modes.first ?? .raw
        let key = ResponseShapeKey(startedAt: startedAt, mode: mode)
        if let done = shaped[key] ?? inlineShapes[key] {
            return Self.presentation(done, preference: preference)
        }
        if response.body.count <= Self.inlineShapingLimit,
           let done = try? ResponseBodyShaper.shape(response.body, as: classified, mode: mode.shapingMode, isTruncated: exchange.isBodyTruncated) {
            inlineShapes.store(done, for: key)
            return Self.presentation(done, preference: preference)
        }
        return ResponseBodyPresentation(content: .shaping, availableModes: modes, mode: mode, pendingShape: key)
    }

    /// Shapes `key`'s body off the main actor, superseding any shaping still running for another key. `nil`, for a
    /// body that needs no shaping (a small one, or one already shaped), cancels what is running: it can only be for an
    /// exchange or mode no longer shown, and finishing it would hold a body nobody reads.
    func startShaping(_ key: ResponseShapeKey?) {
        guard let key else {
            shapingTask?.cancel()
            shapingTask = nil
            shapingKey = nil
            return
        }
        guard key != shapingKey, shapedBodies[key] == nil,
              let exchange, exchange.startedAt == key.startedAt, let response = exchange.response else {
            return
        }
        shapingTask?.cancel()
        shapingKey = key
        let body = response.body
        let (format, _) = classify(response, startedAt: key.startedAt)
        let mode = key.mode.shapingMode
        let isTruncated = exchange.isBodyTruncated
        let task = Task.detached(priority: .userInitiated) {
            try ResponseBodyShaper.shape(body, as: format, mode: mode, isTruncated: isTruncated)
        }
        shapingTask = task
        Task { [weak self] in
            let shaped = try? await task.value
            guard let self, shapingKey == key else {
                return
            }
            shapingKey = nil
            shapingTask = nil
            if let shaped {
                shapedBodies.store(shaped, for: key)
            }
        }
    }

    private func classify(_ response: HTTPResponseRecord, startedAt: Date) -> (BodyFormat, NSImage?) {
        if let classification, classification.startedAt == startedAt {
            return (classification.format, classification.image)
        }
        let format = ResponseBodyShaper.classify(response.body, contentType: response.header("Content-Type"))
        let image = format == .image ? NSImage(data: response.body) : nil
        classification = BodyClassification(startedAt: startedAt, format: format, image: image)
        return (format, image)
    }

    private static func presentation(_ shaped: ShapedBody, preference: ResponseBodyMode) -> ResponseBodyPresentation {
        let modes = modes(for: shaped.format)
        let mode = modes.contains(preference) ? preference : modes.first
        switch shaped.content {
        case .text(let document):
            return ResponseBodyPresentation(content: .text(document), availableModes: modes, mode: mode, pendingShape: nil)
        case .tree(let structure):
            return ResponseBodyPresentation(content: .tree(structure), availableModes: modes, mode: mode, pendingShape: nil)
        case .treeFailed(let message):
            return ResponseBodyPresentation(content: .treeFailed(message), availableModes: modes, mode: mode, pendingShape: nil)
        case .binary(let byteCount):
            return ResponseBodyPresentation(content: .binary(byteCount: byteCount), availableModes: [], mode: nil, pendingShape: nil)
        case .empty:
            return .empty
        }
    }

    private static func modes(for format: BodyFormat) -> [ResponseBodyMode] {
        switch format {
        case .empty:
            []
        case .json:
            [.tree, .pretty, .raw]
        case .xml:
            [.tree, .raw]
        case .image, .text:
            [.raw]
        }
    }
}

extension ResponseBodyMode {
    var shapingMode: ShapingMode {
        switch self {
        case .tree: .tree
        case .pretty: .pretty
        case .raw, .preview: .raw
        }
    }
}
