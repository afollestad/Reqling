import Foundation
import NIOCore
import NIOHTTP1

/// Collects one HTTP request, records it, and writes the server's reply once it is ready. GraphQL execution is
/// asynchronous, so the reply comes back through a promise and is written on the channel's event loop.
final class FixtureRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let box: ServerBox
    private var head: HTTPRequestHead?
    private var body = Data()

    init(box: ServerBox) {
        self.box = box
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            self.head = head
            body = Data()
        case .body(var buffer):
            body.append(contentsOf: buffer.readBytes(length: buffer.readableBytes) ?? [])
        case .end:
            guard let head, let server = box.server.withLock({ $0 }) else {
                return
            }
            let request = GraphQLFixtureServer.RecordedRequest(
                method: head.method.rawValue,
                uri: head.uri,
                headers: head.headers.map { ($0.name, $0.value) },
                body: body
            )
            server.record(request)
            let promise = context.eventLoop.makePromise(of: GraphQLFixtureServer.Reply.self)
            promise.completeWithTask {
                await server.reply(to: request)
            }
            let bound = NIOLoopBound(context, eventLoop: context.eventLoop)
            let version = head.version
            promise.futureResult.whenSuccess { reply in
                guard case .respond(let status, let headers, let responseBody) = reply else {
                    return
                }
                Self.write(status: status, headers: headers, body: responseBody, version: version, to: bound.value)
            }
        }
    }

    private static func write(status: Int, headers: [(String, String)], body: Data, version: HTTPVersion, to context: ChannelHandlerContext) {
        var responseHeaders = HTTPHeaders(headers)
        responseHeaders.replaceOrAdd(name: "Content-Length", value: String(body.count))
        let head = HTTPResponseHead(version: version, status: HTTPResponseStatus(statusCode: status), headers: responseHeaders)
        context.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        context.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: body)))), promise: nil)
        context.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil)), promise: nil)
    }
}
