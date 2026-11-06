import Foundation
import NIOCore
import NIOWebSocket

/// One open connection, from the 101 until it closes: a single loop owns its state and makes every write, so a pong, a
/// close echo, and the caller's messages never race each other onto the wire. A reader task, a forwarder of the
/// outbox's commands, and the timers only feed it `Input`s.
///
/// The connection is held to the protocol as a browser holds it (RFC 6455): a frame a client must never get, text that
/// is not UTF-8, or a close code a server may not send closes it with 1002 or 1007, and the run ends in a `violation`.
/// What arrived before stays reported.
struct WebSocketSession: Sendable {
    enum Input: Sendable {
        case frame(WebSocketFrame)
        case inboundEnded((any Error)?)
        case command(WebSocketCommand)
        case keepaliveTick
        case closeTimeout
    }

    let channel: NIOAsyncChannel<WebSocketFrame, WebSocketFrame>
    /// The channel under `channel`, closed directly when the server never finishes the close handshake.
    let underlying: any Channel
    let sink: WebSocketEventSink
    let keepalive: Duration?
    let closeTimeout: Duration
    let messageLimit: Int
    let sleep: @Sendable (Duration) async throws -> Void
    let now: @Sendable () -> Date

    /// Runs until the connection closes. `inputs` and `feed` are one stream, made by the caller so it can start the
    /// close handshake itself (`Input.command(.close)`) when it is cancelled.
    func run(outbox: WebSocketOutbox, inputs: AsyncStream<Input>, feed: AsyncStream<Input>.Continuation) async -> WebSocketEnd {
        do {
            return try await channel.executeThenClose { inbound, outbound in
                await withTaskGroup(of: Void.self) { group -> WebSocketEnd in
                    group.addTask {
                        do {
                            for try await frame in inbound {
                                feed.yield(.frame(frame))
                            }
                            feed.yield(.inboundEnded(nil))
                        } catch {
                            feed.yield(.inboundEnded(error))
                        }
                    }
                    group.addTask {
                        for await command in outbox.commands {
                            feed.yield(.command(command))
                        }
                    }
                    if let keepalive {
                        let sleep = sleep
                        group.addTask {
                            while (try? await sleep(keepalive)) != nil {
                                feed.yield(.keepaliveTick)
                            }
                        }
                    }
                    var loop = Loop(session: self, outbound: outbound)
                    var end: WebSocketEnd = .dropped("The connection closed without a close frame (1006).")
                    for await input in inputs {
                        if let finished = await loop.handle(input, startCloseTimer: {
                            let (sleep, timeout) = (sleep, closeTimeout)
                            group.addTask {
                                if (try? await sleep(timeout)) != nil {
                                    feed.yield(.closeTimeout)
                                }
                            }
                        }) {
                            end = finished
                            break
                        }
                    }
                    group.cancelAll()
                    return end
                }
            }
        } catch {
            return .dropped("The connection was lost: \(WebSocketExecutor.describe(error)) (1006).")
        }
    }
}

/// The session's state, changed only by `handle`, one input at a time.
private struct Loop {
    let session: WebSocketSession
    let outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>
    /// Counts message commands, numbering `WebSocketEvent.sent`.
    var messageIndex = 0
    var sentClose: (code: UInt16?, reason: String)?
    var receivedClose: (code: UInt16?, reason: String)?
    var serverClosedFirst = false
    var violation: (code: UInt16, message: String)?
    var dropped: String?
    var outstandingPings: [UInt64: Date] = [:]
    var nextPingID: UInt64 = 1
    /// The keepalive ping waiting for any sign of life, which ends the connection when the next tick finds it waiting.
    var keepalivePing: UInt64?
    var trafficSinceTick = false

    init(session: WebSocketSession, outbound: NIOAsyncChannelOutboundWriter<WebSocketFrame>) {
        self.session = session
        self.outbound = outbound
    }

    /// The end once the connection has closed, or `nil` while it is open.
    mutating func handle(_ input: WebSocketSession.Input, startCloseTimer: () -> Void) async -> WebSocketEnd? {
        switch input {
        case .command(let command):
            await perform(command, startCloseTimer: startCloseTimer)
        case .frame(let frame):
            // A pong only answers a ping; counting it would make an idle connection's keepalive skip every other tick.
            if frame.opcode != .pong {
                trafficSinceTick = true
            }
            keepalivePing = nil
            await receive(frame, startCloseTimer: startCloseTimer)
        case .keepaliveTick:
            await tick()
        case .closeTimeout:
            let text = receivedClose == nil
                ? "The server didn't answer the close in \(Self.describe(session.closeTimeout)), so Reqling closed the connection."
                : "The server didn't close the connection after the close handshake, so Reqling did."
            session.sink.control(.note(text))
            session.underlying.close(promise: nil)
        case .inboundEnded(let error):
            return await ended(error)
        }
        return nil
    }

    private mutating func perform(_ command: WebSocketCommand, startCloseTimer: () -> Void) async {
        switch command {
        case .message(let format, let bytes):
            let index = messageIndex
            messageIndex += 1
            guard sentClose == nil else {
                session.sink.control(.note("Message \(index + 1) wasn't sent: the connection is closing."))
                return
            }
            guard bytes.count <= session.messageLimit else {
                session.sink.control(.note("Message \(index + 1) is larger than \(Self.size(session.messageLimit)), so it wasn't sent."))
                return
            }
            if await write(Self.frame(format == .text ? .text : .binary, bytes)) {
                trafficSinceTick = true
                session.sink.sent(index: index)
            }
        case .ping:
            guard sentClose == nil else {
                return
            }
            await ping()
        case .close(let code, let reason):
            await close(code: code, reason: reason, startCloseTimer: startCloseTimer)
        }
    }

    private mutating func receive(_ frame: WebSocketFrame, startCloseTimer: () -> Void) async {
        guard receivedClose == nil else {
            // Nothing may follow a close frame; whatever does is ignored, as browsers do.
            return
        }
        if violation != nil, frame.opcode != .connectionClose {
            return
        }
        if frame.maskKey != nil {
            return await violate(1002, "The server masked a frame, which only clients may do.", startCloseTimer: startCloseTimer)
        }
        if frame.rsv1 || frame.rsv2 || frame.rsv3 {
            return await violate(1002, "The server set a reserved bit, but no extension was agreed.", startCloseTimer: startCloseTimer)
        }
        let bytes = Array(frame.data.readableBytesView)
        switch frame.opcode {
        case .text:
            session.sink.received(.text, bytes)
            if String(validating: bytes, as: UTF8.self) == nil {
                await violate(1007, "A text message wasn't valid UTF-8.", startCloseTimer: startCloseTimer)
            }
        case .binary:
            session.sink.received(.binary, bytes)
        case .ping:
            session.sink.control(.serverPinged)
            if sentClose == nil {
                _ = await write(Self.frame(.pong, bytes))
            }
        case .pong:
            pong(bytes)
        case .connectionClose:
            await serverClosed(bytes, startCloseTimer: startCloseTimer)
        default:
            let opcode = String(UInt8(webSocketOpcode: frame.opcode), radix: 16, uppercase: true)
            await violate(1002, "The server sent a frame with opcode 0x\(opcode), which WebSockets don't define.", startCloseTimer: startCloseTimer)
        }
    }

    private mutating func ping() async {
        let id = nextPingID
        nextPingID += 1
        if await write(Self.frame(.ping, Self.payload(for: id))) {
            outstandingPings[id] = session.now()
            trafficSinceTick = true
            session.sink.control(.pingSent(id: id))
        }
    }

    private mutating func pong(_ bytes: [UInt8]) {
        guard bytes.count == 8 else {
            session.sink.control(.pong(id: nil, roundTrip: nil))
            return
        }
        let id = bytes.reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        guard let sentAt = outstandingPings.removeValue(forKey: id) else {
            session.sink.control(.pong(id: nil, roundTrip: nil))
            return
        }
        session.sink.control(.pong(id: id, roundTrip: max(0, session.now().timeIntervalSince(sentAt))))
    }

    /// Records the server's close frame and answers it, echoing its code (none for none) unless it broke the rules.
    private mutating func serverClosed(_ bytes: [UInt8], startCloseTimer: () -> Void) async {
        var code: UInt16?
        var reason = ""
        var problem: (code: UInt16, message: String)?
        if bytes.count == 1 {
            problem = (1002, "The server's close frame was malformed.")
        } else if bytes.count >= 2 {
            let received = UInt16(bytes[0]) << 8 | UInt16(bytes[1])
            code = received
            if let text = String(validating: bytes[2...], as: UTF8.self) {
                reason = text
            } else {
                problem = (1007, "The server's close reason wasn't valid UTF-8.")
            }
            if !Self.serverMaySend(received) {
                problem = (1002, "The server closed with code \(received), which servers may not send.")
            }
        }
        receivedClose = (code, reason)
        session.sink.control(.closeReceived(code: code, reason: reason))
        if let problem, violation == nil {
            violation = problem
        }
        guard sentClose == nil else {
            return
        }
        serverClosedFirst = true
        let answer = problem?.code ?? code
        await close(code: answer, reason: "", startCloseTimer: startCloseTimer)
    }

    /// Closes as a browser would when the server breaks the protocol.
    private mutating func violate(_ code: UInt16, _ message: String, startCloseTimer: () -> Void) async {
        if violation == nil {
            violation = (code, message)
        }
        await close(code: code, reason: "", startCloseTimer: startCloseTimer)
    }

    /// Sends one close frame, the first only; then waits `closeTimeout` for the server to finish closing.
    private mutating func close(code: UInt16?, reason: String, startCloseTimer: () -> Void) async {
        guard sentClose == nil else {
            return
        }
        let reason = reason.prefix(utf8Count: 123)
        sentClose = (code, reason)
        var payload: [UInt8] = []
        if let code {
            payload = [UInt8(code >> 8), UInt8(code & 0xFF)] + Array(reason.utf8)
        }
        if await write(Self.frame(.connectionClose, payload)) {
            session.sink.control(.closeSent(code: code, reason: reason))
        }
        startCloseTimer()
    }

    private mutating func tick() async {
        if let id = keepalivePing {
            dropped = "Keepalive ping \(id) got no answer, so the connection counts as lost (1006)."
            session.sink.control(.note("Ping \(id) got no answer before the next keepalive was due."))
            session.underlying.close(promise: nil)
            return
        }
        defer { trafficSinceTick = false }
        guard !trafficSinceTick, sentClose == nil else {
            return
        }
        keepalivePing = nextPingID
        await ping()
    }

    /// The decoder and the aggregator report a broken frame as an error, which ends the inbound stream; the close
    /// they call for is sent here. NIO's `WebSocketProtocolErrorHandler` would send it itself, but its close can
    /// finish the stream before the error reaches it, losing why.
    private mutating func ended(_ error: (any Error)?) async -> WebSocketEnd {
        if let error, let broken = decodingViolation(error), violation == nil {
            violation = broken
            if sentClose == nil {
                _ = await write(Self.frame(.connectionClose, [UInt8(broken.code >> 8), UInt8(broken.code & 0xFF)]))
            }
        }
        if let violation {
            return .violation(code: violation.code, message: violation.message)
        }
        if let dropped {
            return .dropped(dropped)
        }
        if serverClosedFirst, let receivedClose {
            return .closed(code: receivedClose.code, reason: receivedClose.reason, byServer: true)
        }
        if let sentClose {
            return .closed(code: sentClose.code, reason: sentClose.reason, byServer: false)
        }
        guard let error else {
            return .dropped("The server closed the connection without a close frame (1006).")
        }
        return .dropped("The connection was lost: \(WebSocketExecutor.describe(error)) (1006).")
    }

    /// The violation behind a decoding error, or `nil` for an error of the connection itself.
    private func decodingViolation(_ error: any Error) -> (code: UInt16, message: String)? {
        let limit = Self.size(session.messageLimit)
        switch error {
        case NIOWebSocketError.invalidFrameLength:
            return (1009, "The server sent a frame larger than \(limit).")
        case NIOWebSocketError.fragmentedControlFrame:
            return (1002, "The server fragmented a control frame.")
        case NIOWebSocketError.multiByteControlFrameLength:
            return (1002, "The server sent a control frame longer than 125 bytes.")
        case NIOWebSocketFrameAggregator.Error.accumulatedFrameSizeIsTooLarge:
            return (1009, "The server sent a message larger than \(limit).")
        case is NIOWebSocketFrameAggregator.Error:
            return (1002, "The server broke the rules for fragmenting a message.")
        default:
            return nil
        }
    }

    /// `false` when the connection is already gone; its end arrives as `inboundEnded`.
    private func write(_ frame: WebSocketFrame) async -> Bool {
        do {
            try await outbound.write(frame)
            return true
        } catch {
            return false
        }
    }

    /// A client frame, masked with a fresh key as RFC 6455 requires of every frame a client sends.
    private static func frame(_ opcode: WebSocketOpcode, _ bytes: [UInt8]) -> WebSocketFrame {
        WebSocketFrame(fin: true, opcode: opcode, maskKey: .random(), data: ByteBuffer(bytes: bytes))
    }

    /// A ping's counter, big-endian, so its pong can be matched.
    private static func payload(for id: UInt64) -> [UInt8] {
        (0..<8).reversed().map { UInt8(truncatingIfNeeded: id >> (UInt64($0) * 8)) }
    }

    /// The codes RFC 6455 §7.4 lets a server send: the defined ones bar 1004–1006 (reserved, or never on the wire) and
    /// 1015 (TLS failure), plus the ranges for libraries (3000–3999) and applications (4000–4999).
    static func serverMaySend(_ code: UInt16) -> Bool {
        switch code {
        case 1000...1003, 1007...1014, 3000...4999: true
        default: false
        }
    }

    /// As the timeline shows sizes (`ByteCountFormatter`, binary units).
    private static func size(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .binary)
    }

    private static func describe(_ duration: Duration) -> String {
        let milliseconds = Int(duration / .milliseconds(1))
        return milliseconds >= 1_000 ? String(format: "%g s", Double(milliseconds) / 1_000) : "\(milliseconds) ms"
    }
}

/// Where a connection's events go: messages bounded by `LiveEventBuffer`'s budget, everything else always kept.
struct WebSocketEventSink: Sendable {
    let buffer: LiveEventBuffer<WebSocketEvent>
    let now: @Sendable () -> Date

    func sent(index: Int) {
        let date = now()
        buffer.appendMessage(bytes: 0, isSent: true) { _ in .sent(index: index, timestamp: date) }
    }

    func received(_ format: WebSocketMessageFormat, _ bytes: [UInt8]) {
        let date = now()
        buffer.appendMessage(bytes: bytes.count, isSent: false) { _ in .received(format, bytes, timestamp: date) }
    }

    func control(_ event: WebSocketControlEvent) {
        buffer.appendControl(.control(event, timestamp: now()))
    }
}
