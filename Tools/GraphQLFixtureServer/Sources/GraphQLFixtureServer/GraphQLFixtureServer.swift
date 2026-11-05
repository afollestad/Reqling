import Foundation
import GraphQL
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Synchronization

/// A GraphQL server on loopback that answers from an SDL schema through GraphQLSwift, the Swift port of graphql-js.
///
/// Tests use it so introspection responses come from a real GraphQL implementation rather than hand-written JSON, which
/// drifts from what servers send. `scripts/graphql-server.sh` runs the same server for trying Reqling by hand. It
/// records every request and can require a bearer token, refuse introspection, serve TLS, or replace any reply.
public final class GraphQLFixtureServer: Sendable {
    public struct Options: Sendable {
        public var sdl: String
        public var host: String
        /// 0 picks a free port; tests always use it.
        public var port: Int
        public var path: String
        /// Requests without `Authorization: Bearer <token>` get 401.
        public var requiredBearerToken: String?
        public var introspection: Introspection
        public var tls: NIOSSLContext?
        /// Consulted first for every request; a non-nil reply is sent instead of the GraphQL one.
        public var override: (@Sendable (RecordedRequest) -> Reply?)?

        public init(
            sdl: String = GraphQLFixtureSchema.sdl,
            host: String = "127.0.0.1",
            port: Int = 0,
            path: String = "/graphql",
            requiredBearerToken: String? = nil,
            introspection: Introspection = .enabled,
            tls: NIOSSLContext? = nil,
            override: (@Sendable (RecordedRequest) -> Reply?)? = nil
        ) {
            self.sdl = sdl
            self.host = host
            self.port = port
            self.path = path
            self.requiredBearerToken = requiredBearerToken
            self.introspection = introspection
            self.tls = tls
            self.override = override
        }
    }

    public enum Introspection: Sendable, Equatable {
        case enabled
        /// Introspection queries fail validation, answered with `status` (production servers send 200 or 400).
        case disabled(status: Int)
    }

    public struct RecordedRequest: Sendable {
        public var method: String
        public var uri: String
        public var headers: [(name: String, value: String)]
        public var body: Data

        public func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    public enum Reply: Sendable {
        case respond(status: Int, headers: [(String, String)], body: Data)
        /// Never answers, for timeout and cancellation tests.
        case hang

        public static func text(_ text: String, status: Int = 200, contentType: String = "text/plain") -> Reply {
            .respond(status: status, headers: [("Content-Type", contentType)], body: Data(text.utf8))
        }
    }

    public let port: Int
    public let url: URL
    /// Yields each request as it arrives, before it is answered. Iterate it from one task only, as with any `AsyncStream`.
    public let received: AsyncStream<RecordedRequest>

    let options: Options
    let schema: GraphQLSchema
    private let group: MultiThreadedEventLoopGroup
    private let channel: Mutex<(any Channel)?>
    private let recorded = Mutex<[RecordedRequest]>([])
    private let receivedContinuation: AsyncStream<RecordedRequest>.Continuation

    /// Every request so far, in arrival order.
    public var requests: [RecordedRequest] {
        recorded.withLock { $0 }
    }

    private init(options: Options, schema: GraphQLSchema, port: Int, group: MultiThreadedEventLoopGroup) {
        self.options = options
        self.schema = schema
        self.port = port
        self.group = group
        channel = Mutex(nil)
        let scheme = options.tls == nil ? "http" : "https"
        // A configured host and path, both validated by `start`, always form a URL.
        url = URL(string: "\(scheme)://\(options.host):\(port)\(options.path)") ?? URL(fileURLWithPath: "/")
        (received, receivedContinuation) = AsyncStream.makeStream()
    }

    /// Builds the schema, then listens. Throws when the SDL does not build or validate, or the port is taken.
    public static func start(_ options: Options = Options()) async throws -> GraphQLFixtureServer {
        let schema = try buildSchema(source: options.sdl)
        // Validates once here, which also caches the result before any request can race to write it.
        let schemaErrors = validateSchema(schema: schema)
        guard schemaErrors.isEmpty else {
            throw FixtureError.invalidSchema(schemaErrors.map(\.message))
        }
        guard options.path.hasPrefix("/"), URL(string: "http://\(options.host)\(options.path)") != nil else {
            throw FixtureError.invalidAddress
        }
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let box = ServerBox()
        let channel: any Channel
        do {
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.eventLoop.makeCompletedFuture {
                        if let tls = options.tls {
                            try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                        }
                        try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                        try channel.pipeline.syncOperations.addHandler(FixtureRequestHandler(box: box))
                    }
                }
                .bind(host: options.host, port: options.port)
                .get()
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
        guard let port = channel.localAddress?.port else {
            try? await channel.close()
            try? await group.shutdownGracefully()
            throw ChannelError.unknownLocalAddress
        }
        let server = GraphQLFixtureServer(options: options, schema: schema, port: port, group: group)
        server.channel.withLock { $0 = channel }
        box.server.withLock { $0 = server }
        return server
    }

    /// Stops listening and closes every open connection, including ones a `.hang` reply left waiting.
    public func shutdown() async throws {
        receivedContinuation.finish()
        let channel = channel.withLock { $0 }
        try await channel?.close()
        try await group.shutdownGracefully()
    }

    func record(_ request: RecordedRequest) {
        recorded.withLock { $0.append(request) }
        receivedContinuation.yield(request)
    }

    public enum FixtureError: Error, CustomStringConvertible {
        case invalidSchema([String])
        case invalidAddress

        public var description: String {
            switch self {
            case .invalidSchema(let messages): "The schema is not valid: \(messages.joined(separator: "; "))"
            case .invalidAddress: "The host and path do not form a URL; the path must start with /."
            }
        }
    }
}

/// Lets child channels reach a server that only exists once binding succeeds.
final class ServerBox: Sendable {
    let server = Mutex<GraphQLFixtureServer?>(nil)
}
