import CryptoKit
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOWebSocket
import Synchronization

/// A loopback WebSocket server on an ephemeral port, scripted per test. It answers each handshake as `answer` says,
/// by hand rather than through NIO's upgrader, so a test can break the rules a client must enforce; then it records
/// every frame it gets and, as `behavior` says, echoes messages, answers pings, and finishes close handshakes.
final class TestWebSocketServer: Sendable {
    struct Handshake: Sendable {
        var uri: String
        var headers: [(name: String, value: String)]

        func header(_ name: String) -> String? {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func count(of name: String) -> Int {
            headers.count { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
    }

    enum Answer: Sendable {
        /// Switches protocols, naming `subprotocol`, with `headers` added; `frames` go out in the same write as the 101.
        case accept(subprotocol: String? = nil, headers: [(String, String)] = [], frames: [WebSocketFrame] = [], wrongAccept: Bool = false)
        case refuse(status: Int, reason: String, headers: [(String, String)] = [], body: String = "")
        /// Never answers.
        case hang
    }

    struct Behavior: Sendable {
        var echoes = true
        var answersPings = true
        var answersClose = true
        /// Closes the TCP connection after answering a close, as a server should.
        var closesAfterClose = true
    }

    /// A frame as received, unmasked.
    struct Frame: Sendable {
        var opcode: WebSocketOpcode
        var data: [UInt8]
        var isMasked: Bool

        var text: String {
            String(bytes: data, encoding: .utf8) ?? ""
        }

        /// A close frame's code, or `nil` for none.
        var closeCode: UInt16? {
            data.count >= 2 ? UInt16(data[0]) << 8 | UInt16(data[1]) : nil
        }
    }

    let port: Int
    let isTLS: Bool
    /// Every frame any connection got, in order.
    let frames: AsyncStream<Frame>
    private let frameFeed: AsyncStream<Frame>.Continuation
    /// Each handshake as it arrives, before it is answered.
    let arrivals: AsyncStream<Handshake>
    private let arrivalFeed: AsyncStream<Handshake>.Continuation
    private let group: MultiThreadedEventLoopGroup
    private let channel: Mutex<(any Channel)?>
    private let state = Mutex(State())

    private struct State {
        var handshakes: [Handshake] = []
        var connections: [any Channel] = []
    }

    var url: String {
        "\(isTLS ? "wss" : "ws")://127.0.0.1:\(port)"
    }

    var handshakes: [Handshake] {
        state.withLock { $0.handshakes }
    }

    private init(port: Int, isTLS: Bool, group: MultiThreadedEventLoopGroup) {
        self.port = port
        self.isTLS = isTLS
        self.group = group
        channel = Mutex(nil)
        (frames, frameFeed) = AsyncStream.makeStream()
        (arrivals, arrivalFeed) = AsyncStream.makeStream()
    }

    static func start(
        tls: NIOSSLContext? = nil,
        behavior: Behavior = Behavior(),
        answer: @escaping @Sendable (Handshake) -> Answer = { _ in .accept() }
    ) async throws -> TestWebSocketServer {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let box = Mutex<TestWebSocketServer?>(nil)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    guard let server = box.withLock({ $0 }) else {
                        throw ChannelError.ioOnClosedChannel
                    }
                    if let tls {
                        try channel.pipeline.syncOperations.addHandler(NIOSSLServerHandler(context: tls))
                    }
                    try channel.pipeline.syncOperations.addHandler(HandshakeHandler(server: server, behavior: behavior, answer: answer))
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else {
            throw ChannelError.unknownLocalAddress
        }
        let server = TestWebSocketServer(port: port, isTLS: tls != nil, group: group)
        server.channel.withLock { $0 = channel }
        box.withLock { $0 = server }
        return server
    }

    /// Sends `frame` on the newest connection.
    func send(_ frame: WebSocketFrame) async throws {
        try await latest().writeAndFlush(frame)
    }

    /// Ends the newest connection's TCP without a close frame.
    func disconnect() async throws {
        try await latest().close()
    }

    func shutdown() async throws {
        frameFeed.finish()
        arrivalFeed.finish()
        for connection in state.withLock({ $0.connections }) {
            try? await connection.close()
        }
        try await channel.withLock { $0 }?.close()
        try await group.shutdownGracefully()
    }

    private func latest() throws -> any Channel {
        guard let connection = state.withLock({ $0.connections.last }) else {
            throw ChannelError.ioOnClosedChannel
        }
        return connection
    }

    fileprivate func record(_ handshake: Handshake) {
        state.withLock { $0.handshakes.append(handshake) }
        arrivalFeed.yield(handshake)
    }

    fileprivate func opened(_ channel: any Channel) {
        state.withLock { $0.connections.append(channel) }
    }

    fileprivate func received(_ frame: Frame) {
        frameFeed.yield(frame)
    }
}

extension WebSocketFrame {
    /// A server frame: unmasked unless `maskKey` is given, which no server may send.
    static func server(
        _ opcode: WebSocketOpcode,
        _ bytes: [UInt8],
        fin: Bool = true,
        rsv1: Bool = false,
        maskKey: WebSocketMaskingKey? = nil
    ) -> WebSocketFrame {
        WebSocketFrame(fin: fin, rsv1: rsv1, opcode: opcode, maskKey: maskKey, data: ByteBuffer(bytes: bytes))
    }

    static func server(text: String) -> WebSocketFrame {
        server(.text, Array(text.utf8))
    }

    static func serverClose(code: UInt16?, reason: String = "") -> WebSocketFrame {
        server(.connectionClose, code.map { [UInt8($0 >> 8), UInt8($0 & 0xFF)] + Array(reason.utf8) } ?? [])
    }
}

/// Reads the handshake by hand and answers it, then hands the connection to `FrameHandler`.
private final class HandshakeHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let server: TestWebSocketServer
    private let behavior: TestWebSocketServer.Behavior
    private let answer: @Sendable (TestWebSocketServer.Handshake) -> TestWebSocketServer.Answer
    private var received = ByteBuffer()

    init(
        server: TestWebSocketServer,
        behavior: TestWebSocketServer.Behavior,
        answer: @escaping @Sendable (TestWebSocketServer.Handshake) -> TestWebSocketServer.Answer
    ) {
        self.server = server
        self.behavior = behavior
        self.answer = answer
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var chunk = unwrapInboundIn(data)
        received.writeBuffer(&chunk)
        let text = String(buffer: received)
        guard let end = text.range(of: "\r\n\r\n") else {
            return
        }
        let lines = text[..<end.lowerBound].components(separatedBy: "\r\n")
        let uri = lines.first?.split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let headers = lines.dropFirst().compactMap { line -> (name: String, value: String)? in
            guard let colon = line.firstIndex(of: ":") else {
                return nil
            }
            return (String(line[..<colon]), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
        }
        let handshake = TestWebSocketServer.Handshake(uri: uri, headers: headers)
        server.record(handshake)
        switch answer(handshake) {
        case .hang:
            return
        case .refuse(let status, let reason, let extra, let body):
            var response = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: \(body.utf8.count)\r\n"
            response += extra.map { "\($0.0): \($0.1)\r\n" }.joined() + "\r\n" + body
            context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: response)), promise: nil)
        case .accept(let subprotocol, let extra, let frames, let wrongAccept):
            var hash = Insecure.SHA1()
            hash.update(data: Data(((handshake.header("Sec-WebSocket-Key") ?? "") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
            let accept = wrongAccept ? "not-the-accept" : Data(hash.finalize()).base64EncodedString()
            var response = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            response += "Sec-WebSocket-Accept: \(accept)\r\n"
            if let subprotocol {
                response += "Sec-WebSocket-Protocol: \(subprotocol)\r\n"
            }
            response += extra.map { "\($0.0): \($0.1)\r\n" }.joined() + "\r\n"
            context.write(wrapOutboundOut(ByteBuffer(string: response)), promise: nil)
            let pipeline = context.pipeline.syncOperations
            try? pipeline.addHandler(WebSocketFrameEncoder())
            try? pipeline.addHandler(ByteToMessageHandler(WebSocketFrameDecoder(maxFrameSize: 64 * 1024 * 1024)))
            try? pipeline.addHandler(FrameHandler(server: server, behavior: behavior))
            server.opened(context.channel)
            for frame in frames {
                context.channel.write(frame, promise: nil)
            }
            context.channel.flush()
            pipeline.removeHandler(self, promise: nil)
        }
    }
}

/// Records each frame and answers as the server's `Behavior` says.
private final class FrameHandler: ChannelInboundHandler {
    typealias InboundIn = WebSocketFrame
    typealias OutboundOut = WebSocketFrame

    private let server: TestWebSocketServer
    private let behavior: TestWebSocketServer.Behavior

    init(server: TestWebSocketServer, behavior: TestWebSocketServer.Behavior) {
        self.server = server
        self.behavior = behavior
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        let bytes = Array(frame.unmaskedData.readableBytesView)
        server.received(TestWebSocketServer.Frame(opcode: frame.opcode, data: bytes, isMasked: frame.maskKey != nil))
        switch frame.opcode {
        case .text where behavior.echoes, .binary where behavior.echoes:
            context.writeAndFlush(wrapOutboundOut(.server(frame.opcode, bytes)), promise: nil)
        case .ping where behavior.answersPings:
            context.writeAndFlush(wrapOutboundOut(.server(.pong, bytes)), promise: nil)
        case .connectionClose where behavior.answersClose:
            let (closesAfter, channel) = (behavior.closesAfterClose, context.channel)
            context.writeAndFlush(wrapOutboundOut(.server(.connectionClose, bytes))).whenComplete { _ in
                if closesAfter {
                    channel.close(promise: nil)
                }
            }
        default:
            break
        }
    }
}
