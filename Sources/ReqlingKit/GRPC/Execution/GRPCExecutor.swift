import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import Synchronization

/// Makes gRPC calls with raw message bytes; encoding and decoding them belongs to the codec.
///
/// Each call runs in the caller's task, so cancelling that task cancels the call, and opens a connection of its own
/// (`GRPCConnection`).
public struct GRPCExecutor: Sendable {
    /// The most messages, and payload bytes, waiting for `onEvent`. A receiver that falls further behind loses the
    /// oldest messages, which `GRPCCallEvent.omitted` counts, so a fast stream of large messages cannot grow memory
    /// without bound.
    public static let eventBufferLimit = 2_000
    public static let eventBufferByteLimit = 32 * 1024 * 1024

    private let now: @Sendable () -> Date
    /// Runs once the call has ended and only delivery remains, so tests can act in that window.
    private let beforeDrain: @Sendable () -> Void

    public init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.init(now: now, beforeDrain: {})
    }

    init(now: @escaping @Sendable () -> Date = { Date() }, beforeDrain: @escaping @Sendable () -> Void) {
        self.now = now
        self.beforeDrain = beforeDrain
    }

    /// Runs `request` to the end. `onEvent` gets the events in order, one at a time, and has had them all by the time
    /// this returns, except those `GRPCCallEvent.omitted` counts: when the call is cancelled, events still queued are
    /// skipped rather than delivered, so cancelling never waits on a backlog.
    public func execute(
        _ request: GRPCCallRequest,
        onEvent: @escaping @Sendable (GRPCCallEvent) async -> Void
    ) async -> GRPCCallOutcome {
        let metadata: Metadata
        let messages: GRPCOutbox
        do {
            metadata = try GRPCMetadataCoding.metadata(from: request.metadata)
            messages = try Self.outbox(for: request)
        } catch {
            return .failed(error)
        }
        guard !request.service.isEmpty, !request.method.isEmpty else {
            return .failed(.invalidRequest("Choose a service and method to call."))
        }
        let buffer = LiveEventBuffer<GRPCCallEvent>(messageLimit: Self.eventBufferLimit, byteLimit: Self.eventBufferByteLimit)
        let recorder = GRPCCallRecorder(buffer: buffer, now: now)
        // Unstructured, so cancelling the call does not cancel delivery: what was already delivered stays, and the
        // backlog is counted rather than lost silently.
        let delivery = Task { await Self.deliver(buffer, to: onEvent) }
        var outcome: GRPCCallOutcome
        do {
            outcome = try await withTaskCancellationHandler { () async throws(GRPCCallTermination) -> GRPCCallOutcome in
                try await GRPCConnection.run(target: request.target, security: request.security) { client in
                    try await Self.call(request, metadata: metadata, messages: messages, client: client, recorder: recorder)
                }
            } onCancel: {
                // From the moment of cancellation, not once the call has wound down, so no more messages are delivered.
                buffer.skipBacklog()
            }
        } catch {
            switch error {
            case .status(let status, let trailers):
                outcome = .finished(status: status, trailers: trailers, timestamp: now())
            case .failure(let failure):
                outcome = .failed(failure)
            }
        }
        // A cancelled call reports that, not whatever status the interrupted stream produced on the way out.
        if Task.isCancelled, outcome.status?.isOK != true {
            outcome = .failed(.cancelled)
        }
        messages.finish()
        buffer.finish()
        beforeDrain()
        // A cancel that lands while the backlog drains, after the call itself has ended, skips the rest too.
        await withTaskCancellationHandler {
            await delivery.value
        } onCancel: {
            buffer.skipBacklog()
        }
        return outcome
    }

    /// The buffer interleaves `.omitted` with the rest, so the totals arrive while the call is still open.
    private static func deliver(_ buffer: LiveEventBuffer<GRPCCallEvent>, to onEvent: @Sendable (GRPCCallEvent) async -> Void) async {
        while let event = await buffer.next() {
            await onEvent(event)
        }
    }

    /// One shape for every kind's request messages: a lone message becomes a finished outbox.
    private static func outbox(for request: GRPCCallRequest) throws(GRPCCallError) -> GRPCOutbox {
        switch request.body {
        case .message(let message):
            let outbox = GRPCOutbox([message])
            outbox.finish()
            return outbox
        case .stream(let outbox):
            guard request.kind.clientStreams else {
                throw .invalidRequest("A unary or server-streaming call sends exactly one message.")
            }
            return outbox
        }
    }

    private static func call(
        _ request: GRPCCallRequest,
        metadata: Metadata,
        messages: GRPCOutbox,
        client: GRPCClient<HTTP2ClientTransport.Posix>,
        recorder: GRPCCallRecorder
    ) async throws -> GRPCCallOutcome {
        let descriptor = MethodDescriptor(
            fullyQualifiedService: request.service,
            method: request.method,
            type: request.kind.rpcType
        )
        let serializer = RawMessageSerializer { recorder.sent() }
        let deserializer = RawMessageDeserializer()
        var options = CallOptions.defaults
        options.timeout = request.timeout
        let stream = StreamingClientRequest(of: [UInt8].self, metadata: metadata) { writer in
            recorder.open()
            for await message in messages.messages {
                try await writer.write(message)
            }
        }
        // `outbox(for:)` has already refused a stream body for the kinds that send one message.
        let single: [UInt8] = if case .message(let message) = request.body { message } else { [] }
        switch request.kind {
        case .unary:
            return try await client.unary(
                request: ClientRequest(message: single, metadata: metadata),
                descriptor: descriptor, serializer: serializer, deserializer: deserializer, options: options
            ) { response in
                recorder.outcome(of: response)
            }
        case .serverStreaming:
            return try await client.serverStreaming(
                request: ClientRequest(message: single, metadata: metadata),
                descriptor: descriptor, serializer: serializer, deserializer: deserializer, options: options
            ) { response in
                await recorder.outcome(of: response)
            }
        case .clientStreaming:
            return try await client.clientStreaming(
                request: stream, descriptor: descriptor, serializer: serializer, deserializer: deserializer, options: options
            ) { response in
                recorder.outcome(of: response)
            }
        case .bidirectionalStreaming:
            return try await client.bidirectionalStreaming(
                request: stream, descriptor: descriptor, serializer: serializer, deserializer: deserializer, options: options
            ) { response in
                await recorder.outcome(of: response)
            }
        }
    }
}

extension GRPCCallOutcome {
    var status: GRPCStatusRecord? {
        if case .finished(let status, _, _) = self {
            return status
        }
        return nil
    }
}

extension GRPCCallEvent {
    /// A sent or received message, the events `omitted` counts.
    var isMessage: Bool {
        switch self {
        case .sent, .received: true
        case .opened, .initialMetadata, .omitted: false
        }
    }
}

extension GRPCMethodKind {
    var rpcType: MethodDescriptor.RPCType {
        switch self {
        case .unary: .unary
        case .clientStreaming: .clientStreaming
        case .serverStreaming: .serverStreaming
        case .bidirectionalStreaming: .bidirectionalStreaming
        }
    }
}

extension LiveEventBuffer where Event == GRPCCallEvent {
    /// A call's buffer, reporting drops as `.omitted` with each direction's total.
    convenience init(messageLimit: Int, byteLimit: Int) {
        self.init(messageLimit: messageLimit, byteLimit: byteLimit) { .omitted(sent: $0, received: $1) }
    }
}

/// Turns one call's responses into events and its outcome. Both the send side (through the serializer) and the
/// receive side report here, from different tasks, so events go through `buffer` to reach the caller in order.
private final class GRPCCallRecorder: Sendable {
    private let buffer: LiveEventBuffer<GRPCCallEvent>
    private let now: @Sendable () -> Date
    private let sentCount = Mutex(0)
    private let isOpen = Mutex(false)

    init(buffer: LiveEventBuffer<GRPCCallEvent>, now: @escaping @Sendable () -> Date) {
        self.buffer = buffer
        self.now = now
    }

    /// Reports the stream open once. The request side calls it as it starts, which is only after the stream exists:
    /// a streaming call's producer, or the first serialized message of a unary-style one.
    func open() {
        let first = isOpen.withLock { isOpen in
            defer { isOpen = true }
            return !isOpen
        }
        if first {
            buffer.appendControl(.opened(timestamp: now()))
        }
    }

    func sent() {
        open()
        let index = sentCount.withLock { count in
            defer { count += 1 }
            return count
        }
        let timestamp = now()
        buffer.appendMessage(bytes: 0, isSent: true) { .sent(index: index, sequence: $0, timestamp: timestamp) }
    }

    private func received(_ message: [UInt8]) {
        let timestamp = now()
        buffer.appendMessage(bytes: message.count, isSent: false) { .received(message, sequence: $0, timestamp: timestamp) }
    }

    private func initialMetadata(_ metadata: Metadata) {
        buffer.appendControl(.initialMetadata(GRPCMetadataCoding.rows(from: metadata), timestamp: now()))
    }

    /// Unary and client-streaming responses arrive whole, so their metadata and message are reported together.
    func outcome(of response: ClientResponse<[UInt8]>) -> GRPCCallOutcome {
        switch response.accepted {
        case .failure(let error):
            return finished(error)
        case .success(let contents):
            initialMetadata(contents.metadata)
            switch contents.message {
            case .success(let message):
                received(message)
                return .finished(status: .okay, trailers: GRPCMetadataCoding.rows(from: contents.trailingMetadata), timestamp: now())
            case .failure(let error):
                return finished(error)
            }
        }
    }

    func outcome(of response: StreamingClientResponse<[UInt8]>) async -> GRPCCallOutcome {
        let contents: StreamingClientResponse<[UInt8]>.Contents
        switch response.accepted {
        case .failure(let error):
            return finished(error)
        case .success(let accepted):
            contents = accepted
        }
        initialMetadata(contents.metadata)
        do {
            for try await part in contents.bodyParts {
                switch part {
                case .message(let message):
                    received(message)
                case .trailingMetadata(let trailers):
                    return .finished(status: .okay, trailers: GRPCMetadataCoding.rows(from: trailers), timestamp: now())
                }
            }
            return .finished(status: .okay, trailers: [], timestamp: now())
        } catch let error as RPCError {
            return finished(error)
        } catch {
            return Task.isCancelled ? .failed(.cancelled) : finished(RPCError(code: .unknown, message: "\(error)"))
        }
    }

    /// A non-OK status carries the server's trailers in the error's metadata.
    private func finished(_ error: RPCError) -> GRPCCallOutcome {
        .finished(status: GRPCStatusRecord(error), trailers: GRPCMetadataCoding.rows(from: error.metadata), timestamp: now())
    }
}

/// Request messages are already encoded, so serializing passes them through. It is also the one point every call
/// kind sends each message through once its stream is open, which is when it counts as sent.
private struct RawMessageSerializer: MessageSerializer {
    let onSerialize: @Sendable () -> Void

    func serialize<Bytes: GRPCContiguousBytes>(_ message: [UInt8]) throws -> Bytes {
        onSerialize()
        return Bytes(message)
    }
}

private struct RawMessageDeserializer: MessageDeserializer {
    func deserialize<Bytes: GRPCContiguousBytes>(_ serializedMessageBytes: Bytes) throws -> [UInt8] {
        serializedMessageBytes.withUnsafeBytes { [UInt8]($0) }
    }
}
