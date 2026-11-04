import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
@testable import ReqlingKit
import Synchronization
import XCTest

final class GRPCExecutorTests: XCTestCase {
    typealias Message = Reqling_Test_V1_EchoMessage

    func testUnaryCallReportsMetadataTheMessageAndTrailers() async throws {
        let server = try await start()
        let token = Data([0, 1, 2, 255]).base64EncodedString()

        let (events, outcome) = await run(
            call(server, "Unary", .unary, body: .message(try encode("hi")), metadata: [
                KeyValuePair(key: "X-Token-Bin", value: String(token.dropLast(2))),
                KeyValuePair(key: "x-plain", value: "value"),
                KeyValuePair(key: "x-disabled", value: "ignored", isEnabled: false)
            ])
        )

        let status = try XCTUnwrap(outcome.status)
        XCTAssertEqual(status, GRPCStatusRecord(code: 0, name: "OK", message: ""))
        XCTAssertEqual(try decode(events.received), ["hi"])
        XCTAssertEqual(events.sentIndexes, [0])
        guard case .opened = events.first else {
            return XCTFail("The stream opens before anything else: \(events)")
        }
        let initial = try XCTUnwrap(events.initialMetadata)
        XCTAssertTrue(initial.contains(KeyValuePair(key: "x-initial", value: "hello")))
        XCTAssertTrue(initial.contains(KeyValuePair(key: "x-token-bin", value: token)))
        XCTAssertFalse(initial.contains { $0.key.hasPrefix(":") })
        XCTAssertTrue(outcome.trailers.contains(KeyValuePair(key: "x-trailer", value: "bye")))
        XCTAssertTrue(outcome.trailers.contains(KeyValuePair(key: "x-token-bin", value: token)))
    }

    func testServerStreamingReceivesEveryMessageInOrder() async throws {
        let server = try await start()

        let (events, outcome) = await run(call(server, "ServerStream", .serverStreaming, body: .message(try encode("tick"))))

        XCTAssertEqual(outcome.status?.isOK, true)
        let messages = try events.received.map { try Message(serializedBytes: $0) }
        XCTAssertEqual(messages.map(\.index), [0, 1, 2])
        XCTAssertEqual(Set(messages.map(\.text)), ["tick"])
        XCTAssertTrue(outcome.trailers.contains(KeyValuePair(key: "x-trailer", value: "bye")))
    }

    func testClientStreamingSendsEveryQueuedMessage() async throws {
        let server = try await start()
        let outbox = GRPCOutbox([try encode("a"), try encode("b")])
        outbox.send(try encode("c"))
        outbox.finish()

        let (events, outcome) = await run(call(server, "ClientStream", .clientStreaming, body: .stream(outbox)))

        XCTAssertEqual(outcome.status?.isOK, true)
        XCTAssertEqual(events.sentIndexes, [0, 1, 2])
        let reply = try Message(serializedBytes: try XCTUnwrap(events.received.first))
        XCTAssertEqual(reply.text, "a,b,c")
        XCTAssertEqual(reply.index, 3)
        XCTAssertFalse(outbox.send(try encode("late")), "A finished outbox drops later messages")
    }

    /// Each message goes out while the call is open, and its echo comes back before the next is sent.
    func testBidirectionalCallsSendFromTheOutboxWhileOpen() async throws {
        let server = try await start()
        let outbox = GRPCOutbox()
        let (received, signal) = AsyncStream.makeStream(of: GRPCCallEvent.self)
        let recorded = EventLog()
        let request = call(server, "Bidi", .bidirectionalStreaming, body: .stream(outbox))
        let running = Task {
            await GRPCExecutor().execute(request) { event in
                recorded.append(event)
                signal.yield(event)
            }
        }
        var receivedEvents = received.makeAsyncIterator()
        for text in ["one", "two"] {
            XCTAssertTrue(outbox.send(try encode(text)))
            while let event = await receivedEvents.next() {
                if case .received = event {
                    break
                }
            }
        }
        outbox.finish()
        let outcome = await running.value

        XCTAssertEqual(outcome.status?.isOK, true)
        XCTAssertEqual(try decode(recorded.events.received), ["one", "two"])
        let order = recorded.events.compactMap { event -> String? in
            switch event {
            case .sent(let index, _, _): "sent \(index)"
            case .received: "received"
            case .opened: "opened"
            case .initialMetadata, .omitted: nil
            }
        }
        XCTAssertEqual(order, ["opened", "sent 0", "received", "sent 1", "received"])
        XCTAssertFalse(outbox.send(try encode("late")))
    }

    func testAServerErrorIsAStatusWithItsTrailers() async throws {
        let server = try await start()

        let (rejectedEvents, rejected) = await run(call(server, "Unary", .unary, body: .message(try encode("fail"))))
        let (_, midStream) = await run(call(server, "Bidi", .bidirectionalStreaming, body: .message(try encode("fail"))))

        for outcome in [rejected, midStream] {
            XCTAssertEqual(outcome.status, GRPCStatusRecord(code: 5, name: "NOT_FOUND", message: "nothing here"))
            XCTAssertTrue(outcome.trailers.contains(KeyValuePair(key: "x-reason", value: "missing")))
        }
        XCTAssertNil(rejectedEvents.initialMetadata, "A trailers-only rejection has no initial metadata")
    }

    func testADeadlineEndsTheCallWithDeadlineExceeded() async throws {
        let server = try await start()
        var request = call(server, "Unary", .unary, body: .message(try encode("hang")))
        request.timeout = .milliseconds(200)

        let (_, outcome) = await run(request)

        XCTAssertEqual(outcome.status?.name, "DEADLINE_EXCEEDED")
        XCTAssertEqual(outcome.status?.code, 4)
    }

    func testCancellingTheTaskCancelsTheCall() async throws {
        let server = try await start()
        let (received, signal) = AsyncStream.makeStream(of: Void.self)
        let request = call(server, "ServerStream", .serverStreaming, body: .message(try encode("hang")))
        let running = Task {
            await GRPCExecutor().execute(request) { event in
                if case .received = event {
                    signal.yield()
                }
            }
        }

        for await _ in received {
            break
        }
        running.cancel()

        let outcome = await running.value
        XCTAssertEqual(outcome, .failed(.cancelled))
    }

    func testARefusedConnectionIsAConnectionFailureNotAStatus() async throws {
        let port = try FreePort.next()
        let request = GRPCCallRequest(
            target: GRPCTarget(.host("127.0.0.1", port: port)),
            service: EchoService.name,
            method: "Unary",
            kind: .unary,
            body: .message(try encode("hi"))
        )

        let (events, outcome) = await run(request)

        guard case .failed(.connectionFailed(let message)) = outcome else {
            return XCTFail("Expected a connection failure, got \(outcome)")
        }
        XCTAssertTrue(message.contains("127.0.0.1:\(port)"), message)
        XCTAssertTrue(message.localizedCaseInsensitiveContains("refused"), message)
        XCTAssertTrue(events.isEmpty, "Nothing opens or is sent without a stream: \(events)")
    }

    /// A server that accepts TCP and never speaks HTTP/2 must not hold a call past its deadline or its cancellation,
    /// however soon the cancellation comes.
    func testASilentServerEndsTheCallAtItsDeadlineOrOnCancel() async throws {
        let silent = try await SilentServer.start()
        addTeardownBlock { await silent.stop() }
        for kind in [GRPCMethodKind.unary, .bidirectionalStreaming] {
            let body: GRPCRequestBody = kind == .unary ? .message([]) : .stream(GRPCOutbox())
            let request = GRPCCallRequest(
                target: silent.target, service: EchoService.name, method: "Unary", kind: kind, timeout: .milliseconds(200), body: body
            )
            let expired = await bounded("\(kind) deadline", Task { await GRPCExecutor().execute(request) { _ in } })
            XCTAssertEqual(expired?.status?.name, "DEADLINE_EXCEEDED", "\(kind): \(String(describing: expired))")

            var unbounded = request
            unbounded.timeout = nil
            let running = Task { await GRPCExecutor().execute(unbounded) { _ in } }
            running.cancel()
            let cancelled = await bounded("\(kind) cancel", running)
            XCTAssertEqual(cancelled, .failed(.cancelled), "\(kind)")
        }
    }

    func testUnixSocketAndIPv6Targets() async throws {
        // Short: a Unix socket path is limited to 104 bytes.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rq-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let socket = try await start(address: .unixDomainSocket(path: directory.appendingPathComponent("echo.sock").path))
        let ipv6 = try await start(address: .ipv6(host: "::1", port: 0))

        for server in [socket, ipv6] {
            let target = try GRPCTarget(parsing: server.target.description)
            XCTAssertEqual(target, server.target)
            var request = call(server, "Unary", .unary, body: .message(try encode("hi")))
            request.target = target
            let (events, outcome) = await run(request)
            XCTAssertEqual(outcome.status?.isOK, true, "\(target): \(outcome)")
            XCTAssertEqual(try decode(events.received), ["hi"])
        }
    }

    func testInvalidRequestsFailBeforeConnecting() async throws {
        let target = GRPCTarget(.host("127.0.0.1", port: 1))
        let rows: [[KeyValuePair]] = [
            [KeyValuePair(key: "x-token-bin", value: "not base64!")],
            [KeyValuePair(key: "x-name", value: "café")],
            [KeyValuePair(key: "bad key", value: "v")],
            [KeyValuePair(key: "grpc-timeout", value: "1S")],
            [KeyValuePair(key: "connection", value: "keep-alive")],
            [KeyValuePair(key: "Transfer-Encoding", value: "chunked")],
            [KeyValuePair(key: "te", value: "gzip")]
        ]
        for metadata in rows {
            let request = GRPCCallRequest(
                target: target, service: EchoService.name, method: "Unary", kind: .unary, metadata: metadata, body: .message([])
            )
            let (_, outcome) = await run(request)
            guard case .failed(.invalidRequest) = outcome else {
                return XCTFail("Expected \(metadata) to be refused, got \(outcome)")
            }
        }
        let streamed = GRPCCallRequest(target: target, service: EchoService.name, method: "Unary", kind: .unary, body: .stream(GRPCOutbox()))
        let (_, outcome) = await run(streamed)
        guard case .failed(.invalidRequest) = outcome else {
            return XCTFail("A unary call cannot take an outbox, got \(outcome)")
        }
    }
}

// MARK: - Helpers

extension GRPCExecutorTests {
    func start(
        address: GRPCNIOTransportCore.SocketAddress = .ipv4(host: "127.0.0.1", port: 0),
        security: HTTP2ServerTransport.Posix.TransportSecurity = .plaintext
    ) async throws -> GRPCTestServer {
        let server = try await GRPCTestServer.start([EchoService()], address: address, security: security)
        addTeardownBlock { await server.stop() }
        return server
    }

    func call(
        _ server: GRPCTestServer,
        _ method: String,
        _ kind: GRPCMethodKind,
        body: GRPCRequestBody,
        metadata: [KeyValuePair] = [],
        security: GRPCTransportSecurity = .plaintext
    ) -> GRPCCallRequest {
        GRPCCallRequest(
            target: server.target,
            security: security,
            service: EchoService.name,
            method: method,
            kind: kind,
            metadata: metadata,
            body: body
        )
    }

    func run(_ request: GRPCCallRequest) async -> ([GRPCCallEvent], GRPCCallOutcome) {
        let log = EventLog()
        let outcome = await GRPCExecutor().execute(request) { log.append($0) }
        return (log.events, outcome)
    }

    func encode(_ text: String) throws -> [UInt8] {
        try Message.with { $0.text = text }.serializedBytes()
    }

    func decode(_ messages: [[UInt8]]) throws -> [String] {
        try messages.map { try Message(serializedBytes: $0).text }
    }
}

final class EventLog: Sendable {
    private let stored = Mutex<[GRPCCallEvent]>([])

    var events: [GRPCCallEvent] {
        stored.withLock { $0 }
    }

    func append(_ event: GRPCCallEvent) {
        stored.withLock { $0.append(event) }
    }
}

extension [GRPCCallEvent] {
    var received: [[UInt8]] {
        compactMap { event in
            if case .received(let bytes, _, _) = event {
                return bytes
            }
            return nil
        }
    }

    var sentIndexes: [Int] {
        compactMap { event in
            if case .sent(let index, _, _) = event {
                return index
            }
            return nil
        }
    }

    var initialMetadata: [KeyValuePair]? {
        lazy.compactMap { event in
            if case .initialMetadata(let rows, _) = event {
                return rows
            }
            return nil
        }.first
    }
}

extension GRPCCallOutcome {
    var trailers: [KeyValuePair] {
        if case .finished(_, let trailers, _) = self {
            return trailers
        }
        return []
    }
}

/// A loopback TCP port the system just handed out and released, so nothing listens there and connecting is refused.
/// (A port kept bound without listening would be safer from reuse, but macOS drops connections to one rather than
/// refusing them, so the attempt only times out.)
enum FreePort {
    static func next() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw POSIXError(.EMFILE)
        }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
                bind(descriptor, generic, length) == 0 && getsockname(descriptor, generic, &length) == 0
            }
        }
        guard bound else {
            throw POSIXError(.EADDRNOTAVAIL)
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
