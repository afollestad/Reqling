import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2
import GRPCProtobuf
import NIOCore
import NIOPosix
@testable import ReqlingKit
import Synchronization
import XCTest

/// A loopback gRPC server for the executor and reflection suites, bound to port 0 (or a Unix socket) and stopped by
/// `stop()`.
final class GRPCTestServer: Sendable {
    let target: GRPCTarget
    private let server: GRPCServer<HTTP2ServerTransport.Posix>
    private let serving: Task<Void, any Error>

    private init(target: GRPCTarget, server: GRPCServer<HTTP2ServerTransport.Posix>, serving: Task<Void, any Error>) {
        self.target = target
        self.server = server
        self.serving = serving
    }

    static func start(
        _ services: [any RegistrableRPCService],
        address: GRPCNIOTransportCore.SocketAddress = .ipv4(host: "127.0.0.1", port: 0),
        security: HTTP2ServerTransport.Posix.TransportSecurity = .plaintext
    ) async throws -> GRPCTestServer {
        let transport = HTTP2ServerTransport.Posix(address: address, transportSecurity: security)
        let server = GRPCServer(transport: transport, services: services)
        let serving = Task { try await server.serve() }
        let bound: GRPCNIOTransportCore.SocketAddress
        do {
            bound = try await transport.listeningAddress
        } catch {
            serving.cancel()
            throw error
        }
        let target: GRPCTarget
        if let ipv4 = bound.ipv4 {
            target = GRPCTarget(.host(ipv4.host, port: ipv4.port))
        } else if let ipv6 = bound.ipv6 {
            target = GRPCTarget(.host(ipv6.host, port: ipv6.port))
        } else if let socket = bound.unixDomainSocket {
            target = GRPCTarget(.unixSocket(path: socket.path))
        } else {
            serving.cancel()
            throw RPCError(code: .internalError, message: "Unexpected listening address \(bound)")
        }
        return GRPCTestServer(target: target, server: server, serving: serving)
    }

    /// Cancels rather than drains, so a handler left hanging by a deadline or cancellation test cannot hold it up.
    func stop() async {
        server.beginGracefulShutdown()
        serving.cancel()
        _ = await serving.result
    }
}

/// `reqling.test.v1.EchoService`, written by hand with protobuf serializers, so the suites need no generated stubs.
///
/// - Every method sends initial metadata `x-initial: hello` and trailers `x-trailer: bye`, and echoes a request's
///   `x-token-bin` back in both.
/// - A message whose text is `fail` ends the call with `NOT_FOUND` and trailer `x-reason: missing`; `hang` never
///   answers (server streaming sends one message first).
/// - Unary echoes `newer` with two fields `EchoMessage` does not define, as a server on a newer schema would.
/// - Server streaming sends `index` messages (3 when it is 0), then calls `onStreamed`; with the text `flood` it
///   then hangs instead of finishing.
struct EchoService: RegistrableRPCService {
    typealias Message = Reqling_Test_V1_EchoMessage

    static let name = "reqling.test.v1.EchoService"

    /// Records each call's request metadata, for tests that check what reached the server.
    var log: MetadataLog?
    var onStreamed: (@Sendable () -> Void)?

    func registerMethods<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        register("Unary", with: &router) { request in
            guard let first = try await Self.first(request.messages) else {
                throw RPCError(code: .invalidArgument, message: "No message")
            }
            try await Self.act(on: first)
            let reply = first.text == "newer" ? try Self.addingUnknownFields(to: first) : first
            return Self.response(to: request.metadata) { writer in
                try await writer.write(reply)
            }
        }
        registerServerStream(with: &router)
        register("ClientStream", with: &router) { request in
            var texts: [String] = []
            for try await message in request.messages {
                try await Self.act(on: message)
                texts.append(message.text)
            }
            let reply = Message.with {
                $0.text = texts.joined(separator: ",")
                $0.index = Int32(texts.count)
            }
            return Self.response(to: request.metadata) { writer in
                try await writer.write(reply)
            }
        }
        register("Bidi", with: &router) { request in
            Self.response(to: request.metadata) { writer in
                for try await message in request.messages {
                    try await Self.act(on: message)
                    try await writer.write(message)
                }
            }
        }
    }

    private func registerServerStream<Transport: ServerTransport>(with router: inout RPCRouter<Transport>) {
        register("ServerStream", with: &router) { [onStreamed] request in
            guard let first = try await Self.first(request.messages) else {
                throw RPCError(code: .invalidArgument, message: "No message")
            }
            return Self.response(to: request.metadata) { writer in
                if first.text == "hang" {
                    try await writer.write(Message.with { $0.text = "first" })
                    try await Self.hang()
                }
                for index in 0..<(first.index > 0 ? Int(first.index) : 3) {
                    try await writer.write(Message.with {
                        $0.text = first.text
                        $0.index = Int32(index)
                    })
                }
                onStreamed?()
                if first.text == "flood" {
                    try await Self.hang()
                }
            }
        }
    }

    private func register<Transport: ServerTransport>(
        _ method: String,
        with router: inout RPCRouter<Transport>,
        handler: @escaping @Sendable (StreamingServerRequest<Message>) async throws -> StreamingServerResponse<Message>
    ) {
        router.registerHandler(
            forMethod: MethodDescriptor(fullyQualifiedService: Self.name, method: method),
            deserializer: ProtobufDeserializer<Message>(),
            serializer: ProtobufSerializer<Message>()
        ) { [log] request, _ in
            log?.append(request.metadata)
            return try await handler(request)
        }
    }

    private static func response(
        to metadata: Metadata,
        produce: @escaping @Sendable (RPCWriter<Message>) async throws -> Void
    ) -> StreamingServerResponse<Message> {
        var initial: Metadata = ["x-initial": "hello"]
        var trailers: Metadata = ["x-trailer": "bye"]
        for token in metadata[binaryValues: "x-token-bin"] {
            initial.addBinary(token, forKey: "x-token-bin")
            trailers.addBinary(token, forKey: "x-token-bin")
        }
        let finalTrailers = trailers
        return StreamingServerResponse(metadata: initial) { writer in
            try await produce(writer)
            return finalTrailers
        }
    }

    private static func act(on message: Message) async throws {
        switch message.text {
        case "fail":
            throw RPCError(code: .notFound, message: "nothing here", metadata: ["x-reason": "missing"])
        case "hang":
            try await hang()
        default:
            break
        }
    }

    /// `message` with fields 98 and 99 set as varints; SwiftProtobuf keeps unknown fields it parses and writes them back.
    private static func addingUnknownFields(to message: Message) throws -> Message {
        try Message(serializedBytes: try message.serializedBytes() + [0x90, 0x06, 0x01, 0x98, 0x06, 0x02])
    }

    /// Ends only through cancellation, which a client's deadline or cancellation delivers.
    private static func hang() async throws {
        try await Task.sleep(for: .seconds(3_600))
    }

    private static func first(_ messages: RPCAsyncSequence<Message, any Error>) async throws -> Message? {
        for try await message in messages {
            return message
        }
        return nil
    }
}

/// The string metadata each call arrived with, in call order.
final class MetadataLog: Sendable {
    private let calls = Mutex<[[String: String]]>([])

    var received: [[String: String]] {
        calls.withLock { $0 }
    }

    func append(_ metadata: Metadata) {
        var values: [String: String] = [:]
        for (key, value) in metadata {
            if case .string(let text) = value {
                values[key] = text
            }
        }
        calls.withLock { $0.append(values) }
    }
}

/// A loopback server that accepts connections and never says anything: TCP connects, and the HTTP/2 handshake then
/// waits forever, so a call to it can only end by its deadline or cancellation.
final class SilentServer: Sendable {
    let target: GRPCTarget
    private let channel: any Channel
    private let group: MultiThreadedEventLoopGroup

    private init(target: GRPCTarget, channel: any Channel, group: MultiThreadedEventLoopGroup) {
        self.target = target
        self.channel = channel
        self.group = group
    }

    static func start() async throws -> SilentServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else {
            throw ChannelError.unknownLocalAddress
        }
        return SilentServer(target: GRPCTarget(.host("127.0.0.1", port: port)), channel: channel, group: group)
    }

    func stop() async {
        try? await channel.close()
        try? await group.shutdownGracefully()
    }
}

/// `task`'s value, or a test failure instead of a hang when it does not finish within `timeout`: a hang detector for
/// calls that must end on their own, not a timing assertion. Free-standing so suites of any isolation can call it.
func bounded<Value: Sendable>(_ description: String, timeout: TimeInterval = 15, _ task: Task<Value, Never>) async -> Value? {
    let done = XCTestExpectation(description: description)
    let waiter = Task {
        let value = await task.value
        done.fulfill()
        return value
    }
    guard await XCTWaiter().fulfillment(of: [done], timeout: timeout) == .completed else {
        XCTFail("\(description) did not finish within \(timeout) seconds")
        task.cancel()
        return nil
    }
    return await waiter.value
}

/// Holds whoever calls `wait()` until `open()`, before or after; for tests that stall a consumer on purpose.
final class TestGate: Sendable {
    private struct State {
        var isOpen = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func wait() async {
        await withCheckedContinuation { continuation in
            let proceed = state.withLock { state -> Bool in
                if state.isOpen {
                    return true
                }
                state.waiters.append(continuation)
                return false
            }
            if proceed {
                continuation.resume()
            }
        }
    }

    func open() {
        let waiters = state.withLock { state in
            state.isOpen = true
            defer { state.waiters = [] }
            return state.waiters
        }
        waiters.forEach { $0.resume() }
    }
}
