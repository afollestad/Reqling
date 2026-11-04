import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Synchronization

/// A loopback HTTP(S) server on an ephemeral port that records what it receives and answers through `respond`.
final class TestHTTPServer: Sendable {
    struct Request: Sendable {
        var method: String
        var uri: String
        var headers: [(name: String, value: String)]
        var body: Data

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }
    }

    enum Response: Sendable {
        case reply(status: HTTPResponseStatus, headers: [(String, String)] = [], body: Data = Data())
        /// Never answers, for timeout tests.
        case hang

        static func text(_ text: String, status: HTTPResponseStatus = .ok, headers: [(String, String)] = []) -> Response {
            .reply(status: status, headers: headers, body: Data(text.utf8))
        }
    }

    let port: Int
    private let group: MultiThreadedEventLoopGroup
    private let channel: any Channel
    private let recorded: Mutex<[Request]>

    var requests: [Request] {
        recorded.withLock { $0 }
    }

    var baseURL: String {
        "http\(isTLS ? "s" : "")://127.0.0.1:\(port)"
    }

    private let isTLS: Bool

    private init(port: Int, group: MultiThreadedEventLoopGroup, channel: any Channel, isTLS: Bool) {
        self.port = port
        self.group = group
        self.channel = channel
        recorded = Mutex([])
        self.isTLS = isTLS
    }

    static func start(tls: NIOSSLContext? = nil, respond: @escaping @Sendable (Request) -> Response) async throws -> TestHTTPServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let box = RecorderBox()
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    if let tls {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                    }
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(RequestHandler(respond: respond, record: box.record))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else {
            throw ChannelError.unknownLocalAddress
        }
        let server = TestHTTPServer(port: port, group: group, channel: channel, isTLS: tls != nil)
        box.server.withLock { $0 = server }
        return server
    }

    func shutdown() async throws {
        try await channel.close()
        try await group.shutdownGracefully()
    }

    fileprivate func record(_ request: Request) {
        recorded.withLock { $0.append(request) }
    }

    /// Lets child channels record into a server that only exists once binding succeeds.
    private final class RecorderBox: Sendable {
        let server = Mutex<TestHTTPServer?>(nil)

        var record: @Sendable (Request) -> Void {
            { [self] request in server.withLock { $0 }?.record(request) }
        }
    }
}

private final class RequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let respond: @Sendable (TestHTTPServer.Request) -> TestHTTPServer.Response
    private let record: @Sendable (TestHTTPServer.Request) -> Void
    private var head: HTTPRequestHead?
    private var body = Data()

    init(
        respond: @escaping @Sendable (TestHTTPServer.Request) -> TestHTTPServer.Response,
        record: @escaping @Sendable (TestHTTPServer.Request) -> Void
    ) {
        self.respond = respond
        self.record = record
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(var buffer):
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            guard let head else {
                return
            }
            let request = TestHTTPServer.Request(
                method: head.method.rawValue,
                uri: head.uri,
                headers: head.headers.map { ($0.name, $0.value) },
                body: body
            )
            record(request)
            guard case .reply(let status, let headers, let responseBody) = respond(request) else {
                return
            }
            var responseHeaders = HTTPHeaders(headers)
            responseHeaders.replaceOrAdd(name: "Content-Length", value: String(responseBody.count))
            context.write(wrapOutboundOut(.head(HTTPResponseHead(version: head.version, status: status, headers: responseHeaders))), promise: nil)
            context.write(wrapOutboundOut(.body(.byteBuffer(ByteBuffer(bytes: responseBody)))), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        }
    }
}
