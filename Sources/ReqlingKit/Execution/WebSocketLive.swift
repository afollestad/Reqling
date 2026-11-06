import Foundation

/// One open WebSocket connection as `RequestRunner` sees it: the record it grows from `WebSocketExecutor`'s events, the
/// outbox the editor sends into, and what a message sent later needs to resolve the way the on-connect ones did.
///
/// Entries take their sequences from one counter, which skips ahead by each drop the executor reports, so gaps show
/// where messages were left out (as `EventStreamLive` numbers a stream). Main-actor isolated like the runner, so each
/// partial record goes straight into `latest`.
@MainActor
final class WebSocketLive: LiveRun {
    struct Context {
        let runID: RunID
        let projectID: ProjectID
        let requestID: RequestNodeID
        let startedAt: Date
        let environmentName: String?
        /// The handshake as sent, masked.
        let request: ResolvedHTTPRequest
        let unresolvedVariables: [String]
        let resolver: TemplateResolver
        let redaction: SecretRedaction
        let allowUnresolved: Bool
        let limit: StreamLimit?
    }

    let context: Context
    let outbox: WebSocketOutbox
    /// Every message queued so far, masked, with its size on the wire; a `sent` event's index points into it.
    private var queued: [EncodedWebSocketMessage]
    private var head: HTTPResponseRecord?
    private var subprotocol: String?
    private var window = LiveWindow<WebSocketEntry>(limit: WebSocketRecord.entryLimit, byteLimit: GRPCLiveCall.byteLimit) {
        $0.message?.text.utf8.count ?? 0
    }
    private var nextSequence = 0
    private var appliedSent = 0
    private var appliedReceived = 0
    private var droppedSent = 0
    private var droppedReceived = 0
    private var sentBytes = 0
    private var receivedBytes = 0
    private var close: WebSocketRecord.Close?
    private var end: WebSocketRecord.End?
    /// Seconds from the run's start to its latest activity, which the record's duration shows while it is open.
    private var activity: TimeInterval = 0
    /// The server switched protocols, and the connection has not ended.
    private(set) var isOpen = false
    /// A bound (`Context.limit`) was reached and the close handshake started; the run ends as `.limit`.
    private(set) var reachedLimit = false
    /// Disconnect was asked for (`RequestRunner.cancel`), so a connection opening only now never takes messages.
    var isStopping = false
    /// Stops the connection once `limit.maxDuration` has passed since it opened.
    var limitTimer: Task<Void, Never>?
    var lastPublished: ContinuousClock.Instant?
    var isPublishPending = false

    /// `seeds` (the on-connect messages, already resolved) are queued first, ahead of anything `send` adds.
    init(context: Context, seeds: [EncodedWebSocketMessage]) {
        self.context = context
        queued = seeds
        outbox = WebSocketOutbox(seeds.map { .message($0.format, $0.bytes) })
    }

    /// Every message received so far, which `StreamLimit.maxEvents` counts.
    var receivedCount: Int {
        appliedReceived + droppedReceived
    }

    /// Resolves and encodes `message` like an on-connect one, then queues it on the open connection.
    func send(_ message: WebSocketMessage) throws(RunFailure) {
        var templates = RunTemplates(resolver: context.resolver)
        let encoded: EncodedWebSocketMessage
        do throws(RunFailure) {
            encoded = try Self.encode(message, templates: &templates, label: "The message")
            if !context.allowUnresolved, !templates.unresolved.isEmpty {
                throw RunFailure.undefinedVariables(templates.unresolved)
            }
        } catch {
            throw error.redacting(context.redaction)
        }
        queued.append(encoded)
        guard outbox.send(.message(encoded.format, encoded.bytes)) else {
            queued.removeLast()
            throw RunFailure(kind: .invalidRequest, message: "The connection is closed.")
        }
    }

    func ping() throws(RunFailure) {
        guard outbox.send(.ping) else {
            throw RunFailure(kind: .invalidRequest, message: "The connection is closed.")
        }
    }

    /// Closes normally once a bound is reached; the messages already on their way are still recorded.
    func stopAtLimit() {
        guard !reachedLimit else {
            return
        }
        reachedLimit = true
        limitTimer?.cancel()
        outbox.send(.close(code: 1000, reason: ""))
    }

    func apply(_ event: WebSocketEvent) {
        switch event {
        case .opened(let head, let subprotocol, let timestamp):
            self.head = head
            self.subprotocol = subprotocol
            isOpen = true
            activity = offset(at: timestamp)
        case .sent(let index, let timestamp):
            guard queued.indices.contains(index) else {
                return
            }
            let message = queued[index]
            appliedSent += 1
            sentBytes += message.bytes.count
            let record = WebSocketMessageRecord(direction: .sent, format: message.format, text: message.shown)
            append(.message(record), byteCount: message.bytes.count, at: timestamp)
        case .received(let format, let bytes, let timestamp):
            appliedReceived += 1
            receivedBytes += bytes.count
            append(.message(Self.received(format, bytes)), byteCount: bytes.count, at: timestamp)
        case .control(let control, let timestamp):
            apply(control, at: timestamp)
        case .omitted(let sent, let received):
            // Running totals, each superseding the last.
            nextSequence += sent - droppedSent + received - droppedReceived
            droppedSent = sent
            droppedReceived = received
        }
    }

    var exchange: RequestExchange {
        exchange(.webSocket(record))
    }

    /// Reqling is quitting: closes with 1001 Going Away, best effort, since the process may end before the frame goes
    /// out, and ends the run as stopped.
    func quit(now: Date = Date()) -> RequestExchange {
        outbox.send(.close(code: 1001, reason: ""))
        apply(.control(.note("Reqling quit, closing the connection with 1001 Going Away."), timestamp: now))
        return finished(.ended(.closed(code: 1001, reason: "", byServer: false), timestamp: now), stopped: true)
    }

    /// `stopped` says the run was cancelled (Disconnect, `cancel_request`): a close that came of it ends `.stopped`.
    func finished(_ outcome: WebSocketOutcome, stopped: Bool) -> RequestExchange {
        isOpen = false
        limitTimer?.cancel()
        switch outcome {
        case .ended(let end, let timestamp):
            activity = offset(at: timestamp)
            switch end {
            case .closed(let code, let reason, let byServer):
                close = WebSocketRecord.Close(code: code.map(Int.init), reason: reason, byServer: byServer)
                self.end = reachedLimit ? .limit : stopped && !byServer ? .stopped : .closed
            case .dropped(let message):
                self.end = .failed(message: context.redaction.apply(message))
            case .violation(let code, let message):
                close = WebSocketRecord.Close(code: Int(code), byServer: false)
                self.end = .failed(message: "\(message) Reqling closed the connection with \(close?.title ?? "\(code)").")
            }
            return exchange(.webSocket(record))
        case .refused(let head, let reason):
            self.head = head
            activity = head.duration
            end = .refused(message: context.redaction.apply(reason))
            return exchange(.webSocket(record))
        case .failed(let error):
            return exchange(.failure(RunFailure(error).redacting(context.redaction)))
        }
    }

    var record: WebSocketRecord {
        let newest = window.newest
        return WebSocketRecord(
            url: context.request.url,
            handshake: head,
            subprotocol: subprotocol,
            entries: newest.entries,
            sentCount: appliedSent + droppedSent,
            receivedCount: appliedReceived + droppedReceived,
            sentByteCount: sentBytes,
            receivedByteCount: receivedBytes,
            trimmedEntryCount: newest.trimmedCount,
            droppedEntryCount: droppedSent + droppedReceived,
            close: close,
            end: end,
            duration: activity
        )
    }

    /// The text a message shows: as received for valid UTF-8, otherwise base64, so nothing is lost in decoding.
    private static func received(_ format: WebSocketMessageFormat, _ bytes: [UInt8]) -> WebSocketMessageRecord {
        if format == .text, let text = String(validating: bytes, as: UTF8.self) {
            return WebSocketMessageRecord(direction: .received, format: .text, text: text)
        }
        return WebSocketMessageRecord(direction: .received, format: format, text: Data(bytes).base64EncodedString(), isBase64: true)
    }

    private func apply(_ control: WebSocketControlEvent, at timestamp: Date) {
        switch control {
        case .pingSent(let id):
            append(.control(direction: .sent, text: "Ping \(id)"), at: timestamp)
        case .pong(let id?, let roundTrip):
            let after = roundTrip.map { " after \(Self.describe($0))" } ?? ""
            append(.control(direction: .received, text: "Pong \(id)\(after)"), at: timestamp)
        case .pong(nil, _):
            append(.control(direction: .received, text: "Pong, unasked"), at: timestamp)
        case .serverPinged:
            append(.control(direction: .received, text: "Ping from the server, answered with a pong"), at: timestamp)
        case .closeSent(let code, let reason):
            append(.control(direction: .sent, text: Self.describeClose(code, reason)), at: timestamp)
        case .closeReceived(let code, let reason):
            append(.control(direction: .received, text: Self.describeClose(code, reason)), at: timestamp)
        case .note(let text):
            append(.note(text), at: timestamp)
        }
    }

    private static func describeClose(_ code: UInt16?, _ reason: String) -> String {
        let title = WebSocketRecord.Close(code: code.map(Int.init), byServer: false).title
        return reason.isEmpty ? "Close \(title)" : "Close \(title): \(reason)"
    }

    /// Like `ResponseStatusBar.duration`, which shows times the same way in every locale.
    private static func describe(_ seconds: TimeInterval) -> String {
        seconds < 1 ? "\(Int((seconds * 1_000).rounded())) ms" : String(format: "%.2f s", seconds)
    }

    private func append(_ kind: WebSocketEntry.Kind, byteCount: Int = 0, at date: Date) {
        activity = offset(at: date)
        window.append(WebSocketEntry(sequence: nextSequence, offset: activity, kind: kind, byteCount: byteCount))
        nextSequence += 1
    }

    private func offset(at date: Date) -> TimeInterval {
        max(0, date.timeIntervalSince(context.startedAt))
    }

    private func exchange(_ outcome: RequestExchange.Outcome) -> RequestExchange {
        RequestExchange(
            id: context.runID,
            projectID: context.projectID,
            requestID: context.requestID,
            startedAt: context.startedAt,
            environmentName: context.environmentName,
            request: context.request,
            outcome: outcome,
            unresolvedVariables: context.unresolvedVariables
        )
    }
}

/// A message resolved for sending: its bytes, and the text the timeline shows, masked.
struct EncodedWebSocketMessage {
    let format: WebSocketMessageFormat
    let bytes: [UInt8]
    let shown: String
}

extension WebSocketLive {
    /// Resolves `message` and turns it into bytes: text as UTF-8, binary from base64. `label` names it in an error
    /// ("Message 2"), so the editor can point at it.
    static func encode(_ message: WebSocketMessage, templates: inout RunTemplates, label: String) throws(RunFailure) -> EncodedWebSocketMessage {
        let text = try templates.resolve(message.text)
        let bytes: [UInt8]
        var shown = text.shown
        switch message.format {
        case .text:
            bytes = Array(text.sent.utf8)
        case .binary:
            guard let data = base64(text.sent) else {
                throw RunFailure(kind: .invalidRequest, message: "\(label) isn't valid base64, which a binary message is written in.")
            }
            bytes = [UInt8](data)
            // As canonical base64, unless masking changed it, so a secret inside stays masked.
            if text.shown == text.sent {
                shown = data.base64EncodedString()
            }
        }
        guard bytes.count <= WebSocketExecutor.messageLimit else {
            let limit = ByteCountFormatter.string(fromByteCount: Int64(WebSocketExecutor.messageLimit), countStyle: .binary)
            throw RunFailure(kind: .invalidRequest, message: "\(label) is larger than \(limit), the most a message can be.")
        }
        return EncodedWebSocketMessage(format: message.format, bytes: bytes, shown: shown)
    }

    /// Standard or URL-safe base64, with whitespace and line breaks ignored and padding optional.
    static func base64(_ text: String) -> Data? {
        var cleaned = String(text.filter { !$0.isWhitespace })
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        switch cleaned.count % 4 {
        case 1: return nil
        case 2: cleaned += "=="
        case 3: cleaned += "="
        default: break
        }
        return Data(base64Encoded: cleaned)
    }
}
