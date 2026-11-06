import Foundation

/// One running gRPC call as `RequestRunner` sees it: the record it grows from the executor's events, the outbox the
/// editor sends into, and what a live message needs to be resolved and encoded the way the seeded ones were.
///
/// Main-actor isolated like the runner, so each event's record goes straight into `RequestRunner.latest`.
@MainActor
final class GRPCLiveCall: LiveRun {
    struct Context {
        let runID: RunID
        let projectID: ProjectID
        let requestID: RequestNodeID
        let startedAt: Date
        let environmentName: String
        let unresolvedVariables: [String]
        let resolver: TemplateResolver
        let redaction: SecretRedaction
        let allowUnresolved: Bool
    }

    let outbox: GRPCOutbox
    let method: GRPCMethodDescriptor
    private let context: Context
    private let endpoint: GRPCEndpoint
    private let codec: ProtobufJSONCodec
    /// The request's own messages, encoded; a unary-style call sends the first.
    private let seeds: [EncodedMessage]
    /// Every message queued so far, masked, with its encoded size; a `sent` event's index points into it.
    private var queued: [(json: String, byteCount: Int)]
    /// Everything but the events, which `window` holds.
    private var base: GRPCCallRecord
    private var window = LiveWindow<GRPCMessageEvent>(limit: GRPCCallRecord.eventLimit, byteLimit: GRPCLiveCall.byteLimit) {
        $0.json.utf8.count
    }
    /// Messages the executor never delivered, by direction.
    private var droppedSent = 0
    private var droppedReceived = 0
    private var appliedSent = 0
    private var appliedReceived = 0
    /// Any event means the call reached the server, so cancelling it from then on keeps its record.
    private var isEstablished = false
    /// When `RequestRunner` last published this call into `latest`, and whether a trailing publish is scheduled.
    var lastPublished: ContinuousClock.Instant?
    var isPublishPending = false

    /// Bounds the JSON a live record holds (`LiveWindow`).
    static let byteLimit = 32 * 1024 * 1024

    /// `seeds` are queued first, ahead of anything `send` adds.
    init(context: Context, method: GRPCMethodDescriptor, endpoint: GRPCEndpoint, codec: ProtobufJSONCodec, seeds: [EncodedMessage]) {
        self.context = context
        self.method = method
        self.endpoint = endpoint
        self.codec = codec
        self.seeds = seeds
        base = GRPCCallRecord(target: endpoint.shownTarget, method: method.path, kind: method.kind, sentMetadata: endpoint.shownMetadata)
        queued = seeds.map { ($0.shown, $0.bytes.count) }
        outbox = GRPCOutbox(seeds.map(\.bytes))
    }

    /// What `GRPCExecutor` runs. The method's kind comes from the schema, never from the spec.
    func request(security: GRPCTransportSecurity, timeout: Duration?) -> GRPCCallRequest {
        GRPCCallRequest(
            target: endpoint.target,
            security: security,
            service: method.service,
            method: method.name,
            kind: method.kind,
            metadata: endpoint.metadata,
            timeout: timeout,
            body: method.kind.clientStreams ? .stream(outbox) : .message(seeds.first?.bytes ?? [])
        )
    }

    /// Resolves and encodes `json` like a seeded message, then queues it on the open request stream.
    func send(_ json: String) throws(RunFailure) {
        var templates = RunTemplates(resolver: context.resolver)
        let message: EncodedMessage
        do throws(RunFailure) {
            let text = try templates.resolve(json)
            if !context.allowUnresolved, !templates.unresolved.isEmpty {
                throw RunFailure.undefinedVariables(templates.unresolved)
            }
            message = try Self.encode(text, as: method.inputType, codec: codec, label: "The message")
        } catch {
            throw error.redacting(context.redaction)
        }
        queued.append((message.shown, message.bytes.count))
        guard outbox.send(message.bytes) else {
            queued.removeLast()
            throw RunFailure(kind: .invalidRequest, message: "The call's request stream is already closed.")
        }
    }

    func apply(_ event: GRPCCallEvent) {
        isEstablished = true
        switch event {
        case .opened(let timestamp):
            base.duration = timestamp.timeIntervalSince(context.startedAt)
        case .omitted(let sent, let received):
            // Running totals, each superseding the last.
            droppedSent = sent
            droppedReceived = received
        case .sent(let index, let sequence, let timestamp):
            let message = queued.indices.contains(index) ? queued[index] : (json: "", byteCount: 0)
            appliedSent += 1
            append(GRPCMessageEvent(
                direction: .sent,
                offset: offset(at: timestamp),
                json: message.json,
                byteCount: message.byteCount,
                sequence: sequence
            ))
        case .initialMetadata(let rows, let timestamp):
            base.initialMetadata = rows
            base.duration = timestamp.timeIntervalSince(context.startedAt)
        case .received(let bytes, let sequence, let timestamp):
            appliedReceived += 1
            let decoded: (json: String, unknownFieldCount: Int)
            do {
                decoded = try codec.decodeCountingUnknownFields(bytes, as: method.outputType)
            } catch {
                decoded = ("Could not decode the message as \(method.outputType): \(error.localizedDescription)", 0)
            }
            append(GRPCMessageEvent(
                direction: .received,
                offset: offset(at: timestamp),
                json: decoded.json,
                byteCount: bytes.count,
                sequence: sequence,
                unknownFieldCount: decoded.unknownFieldCount
            ))
        }
    }

    /// The call so far, its newest `GRPCCallRecord.eventLimit` events included; the status stays `nil` until
    /// `finished`.
    var record: GRPCCallRecord {
        var record = base
        let newest = window.newest
        record.events = newest.entries
        record.trimmedEventCount = newest.trimmedCount
        record.droppedEventCount = droppedSent + droppedReceived
        record.sentCount = appliedSent + droppedSent
        record.receivedCount = appliedReceived + droppedReceived
        return record
    }

    var exchange: RequestExchange {
        exchange(.grpc(record))
    }

    /// A call cancelled once established ends as a `CANCELLED` record, so a watched stream keeps its timeline; one
    /// cancelled earlier never reached the server and fails like any other unconnected call.
    func finished(_ outcome: GRPCCallOutcome, now: Date = Date()) -> RequestExchange {
        switch outcome {
        case .finished(let status, let trailers, let timestamp):
            base.status = status
            base.trailers = trailers
            base.duration = timestamp.timeIntervalSince(context.startedAt)
            return exchange(.grpc(record))
        case .failed(.cancelled) where isEstablished:
            base.status = GRPCStatusRecord(code: 1, name: "CANCELLED", message: "Cancelled")
            base.duration = now.timeIntervalSince(context.startedAt)
            return exchange(.grpc(record))
        case .failed(let error):
            return exchange(.failure(RunFailure(error).redacting(context.redaction)))
        }
    }

    /// `label` names the message in an error ("Message 2"), with the codec's JSON path, so the editor can point at it.
    /// The shown text is pretty-printed like decoded received messages, so the timeline reads one way; masked text that
    /// no longer parses (a secret that stood for a number) stays as typed.
    static func encode(
        _ text: ResolvedTemplate,
        as inputType: String,
        codec: ProtobufJSONCodec,
        label: String
    ) throws(RunFailure) -> EncodedMessage {
        do {
            let bytes = try codec.encode(json: text.sent, as: inputType)
            return EncodedMessage(bytes: bytes, shown: JSONFormatter.pretty(text.shown) ?? text.shown)
        } catch {
            throw RunFailure(kind: .invalidRequest, message: "\(label) is not a valid \(inputType): \(error.localizedDescription)")
        }
    }

    private func offset(at timestamp: Date) -> TimeInterval {
        timestamp.timeIntervalSince(context.startedAt)
    }

    private func append(_ event: GRPCMessageEvent) {
        window.append(event)
        base.duration = event.offset
    }

    private func exchange(_ outcome: RequestExchange.Outcome) -> RequestExchange {
        RequestExchange(
            id: context.runID,
            projectID: context.projectID,
            requestID: context.requestID,
            startedAt: context.startedAt,
            environmentName: context.environmentName,
            request: nil,
            outcome: outcome,
            unresolvedVariables: context.unresolvedVariables
        )
    }
}

/// A request message as sent, and as shown with secrets masked.
struct EncodedMessage {
    let bytes: [UInt8]
    let shown: String
}
