import Foundation
import NIOCore
import NIOWebSocket
@testable import ReqlingKit
import XCTest

/// WebSocket connections through `WebSocketExecutor` against a scripted loopback server: the handshake, messages both
/// ways, pings, and how a connection ends.
final class WebSocketExecutorTests: XCTestCase {
    var servers: [TestWebSocketServer] = []

    override func tearDown() async throws {
        for server in servers {
            try await server.shutdown()
        }
        servers = []
    }

    func start(
        tls: Bool = false,
        requireClientCertificate: Bool = false,
        behavior: TestWebSocketServer.Behavior = TestWebSocketServer.Behavior(),
        answer: @escaping @Sendable (TestWebSocketServer.Handshake) -> TestWebSocketServer.Answer = { _ in .accept() }
    ) async throws -> TestWebSocketServer {
        let context = tls ? try TLSFixtures.serverContext(requireClientCertificate: requireClientCertificate) : nil
        let server = try await TestWebSocketServer.start(tls: context, behavior: behavior, answer: answer)
        servers.append(server)
        return server
    }

    /// One connection as a test drives it: its outbox, and its events as they arrive.
    struct Connection {
        let outbox: WebSocketOutbox
        let task: Task<WebSocketOutcome, Never>
        var events: AsyncStream<WebSocketEvent>.Iterator

        /// The next event other than a drop report, which a test this small never sees.
        mutating func next() async -> WebSocketEvent? {
            while let event = await events.next() {
                if case .omitted = event {
                    continue
                }
                return event
            }
            return nil
        }

        /// Skips ahead to the next event `match` accepts.
        mutating func next<T>(_ match: (WebSocketEvent) -> T?) async -> T? {
            while let event = await next() {
                if let found = match(event) {
                    return found
                }
            }
            return nil
        }

        mutating func nextControl() async -> WebSocketControlEvent? {
            await next { if case .control(let control, _) = $0 { control } else { nil } }
        }

        var outcome: WebSocketOutcome {
            get async {
                await task.value
            }
        }
    }

    func connect(
        _ url: String,
        headers: [String: String] = [:],
        subprotocols: [String] = [],
        tls: TLSContext? = nil,
        cookies: HTTPCookieStorage? = nil,
        handlesCookies: Bool = true,
        keepalive: Duration? = nil,
        sleeper: TestSleeper = TestSleeper(returnsAtOnce: false),
        messageLimit: Int = WebSocketExecutor.messageLimit,
        commands: [WebSocketCommand] = []
    ) throws -> Connection {
        var handshake = URLRequest(url: try XCTUnwrap(URL(string: url)))
        handshake.timeoutInterval = 10
        handshake.httpShouldHandleCookies = handlesCookies
        for (name, value) in headers {
            handshake.setValue(value, forHTTPHeaderField: name)
        }
        let outbox = WebSocketOutbox(commands)
        let (events, feed) = AsyncStream<WebSocketEvent>.makeStream()
        let executor = WebSocketExecutor(sleep: { try await sleeper.sleep($0) }, messageLimit: messageLimit)
        let request = WebSocketConnectRequest(
            handshake: handshake,
            shownURL: url,
            subprotocols: subprotocols,
            tls: tls,
            cookies: cookies,
            keepalive: keepalive
        )
        let task = Task {
            let outcome = await executor.execute(request, outbox: outbox) { feed.yield($0) }
            feed.finish()
            return outcome
        }
        return Connection(outbox: outbox, task: task, events: events.makeAsyncIterator())
    }

    func testTheHandshakeSendsItsHeadersAndOpensWithTheServersChoice() async throws {
        let server = try await start { _ in .accept(subprotocol: "chat") }
        let headers = [
            "Authorization": "Bearer abc", "X-Trace": "1", "Host": "elsewhere", "Upgrade": "h2c", "Sec-WebSocket-Protocol": "chat, superchat"
        ]
        var connection = try connect("\(server.url)/socket?room=a%20b", headers: headers, subprotocols: ["chat", "superchat"])

        guard case .opened(let head, let subprotocol, _) = await connection.next() else {
            return XCTFail("The connection opens first")
        }
        connection.outbox.send(.close(code: 1000, reason: ""))
        let outcome = await connection.outcome

        XCTAssertEqual(head.statusCode, 101)
        XCTAssertEqual(head.url, "\(server.url)/socket?room=a%20b", "The shown URL, which the runner masks")
        XCTAssertEqual(head.protocolName, "http/1.1")
        XCTAssertNotNil(head.timing?.connect)
        XCTAssertNil(head.tlsVersion)
        XCTAssertEqual(subprotocol, "chat")
        let handshake = try XCTUnwrap(server.handshakes.first)
        XCTAssertEqual(handshake.uri, "/socket?room=a%20b")
        XCTAssertEqual(handshake.header("Host"), "127.0.0.1:\(server.port)", "Host comes from the URL, never a typed header")
        XCTAssertEqual(handshake.count(of: "Host"), 1)
        XCTAssertEqual(handshake.count(of: "Upgrade"), 1, "A typed Upgrade is dropped, not sent beside NIO's")
        XCTAssertEqual(handshake.header("Upgrade")?.lowercased(), "websocket")
        XCTAssertEqual(handshake.header("Sec-WebSocket-Version"), "13")
        XCTAssertEqual(handshake.header("Authorization"), "Bearer abc")
        XCTAssertEqual(handshake.header("X-Trace"), "1")
        XCTAssertEqual(handshake.header("Sec-WebSocket-Protocol"), "chat, superchat")
        guard case .ended(.closed(code: 1000, reason: "", byServer: false), _) = outcome else {
            return XCTFail("Closing from the client ends it closed: \(outcome)")
        }
    }

    func testMessagesGoBothWaysMaskedAndInOrder() async throws {
        let server = try await start()
        var frames = server.frames.makeAsyncIterator()
        var connection = try connect(server.url, commands: [.message(.text, Array("hello".utf8)), .message(.binary, [0, 1, 2])])

        var sent: [Int] = []
        var received: [(WebSocketMessageFormat, [UInt8])] = []
        while received.count < 2, let event = await connection.next() {
            switch event {
            case .sent(let index, _): sent.append(index)
            case .received(let format, let bytes, _): received.append((format, bytes))
            default: break
            }
        }
        let first = await frames.next()
        let second = await frames.next()
        connection.outbox.send(.close(code: 1000, reason: ""))
        _ = await connection.outcome

        XCTAssertEqual(sent, [0, 1])
        XCTAssertEqual(received.map(\.0), [.text, .binary])
        XCTAssertEqual(received.map(\.1), [Array("hello".utf8), [0, 1, 2]])
        XCTAssertEqual(first?.opcode, .text)
        XCTAssertEqual(first?.text, "hello")
        XCTAssertEqual(second?.opcode, .binary)
        XCTAssertEqual([first?.isMasked, second?.isMasked], [true, true], "A client masks every frame")
    }

    /// The frames go out in the same write as the 101, so this also covers bytes that arrive with the handshake's end;
    /// the server's ping between the fragments is answered at once.
    func testAFragmentedMessageArrivesWholeWithAPingAnsweredBetweenItsFragments() async throws {
        let frames: [WebSocketFrame] = [
            .server(.text, Array("Hel".utf8), fin: false),
            .server(.ping, Array("are you there".utf8)),
            .server(.continuation, Array("lo".utf8))
        ]
        let server = try await start { _ in .accept(frames: frames) }
        var serverFrames = server.frames.makeAsyncIterator()
        var connection = try connect(server.url)

        var order: [String] = []
        while order.count < 2, let event = await connection.next() {
            switch event {
            case .control(.serverPinged, _): order.append("ping")
            case .received(.text, let bytes, _): order.append(String(bytes: bytes, encoding: .utf8) ?? "")
            default: break
            }
        }
        let pong = await serverFrames.next()
        connection.task.cancel()
        _ = await connection.outcome

        XCTAssertEqual(order, ["ping", "Hello"])
        XCTAssertEqual(pong?.opcode, .pong)
        XCTAssertEqual(pong?.text, "are you there", "A pong echoes its ping's payload")
    }

    func testAClientPingIsMatchedToItsPongAndAnUnaskedPongIsNoted() async throws {
        let server = try await start()
        var connection = try connect(server.url, commands: [.ping])

        let sent = await connection.nextControl()
        let answered = await connection.nextControl()
        try await server.send(.server(.pong, [9]))
        let unasked = await connection.nextControl()
        connection.task.cancel()
        _ = await connection.outcome

        XCTAssertEqual(sent, .pingSent(id: 1))
        guard case .pong(id: 1, roundTrip: .some(let roundTrip)) = answered else {
            return XCTFail("The server's pong answers ping 1: \(String(describing: answered))")
        }
        XCTAssertGreaterThanOrEqual(roundTrip, 0)
        XCTAssertEqual(unasked, .pong(id: nil, roundTrip: nil))
    }

    func testAServerCloseIsEchoedAndEndsTheConnectionAsTheServersClose() async throws {
        let server = try await start()
        var frames = server.frames.makeAsyncIterator()
        var connection = try connect(server.url)
        _ = await connection.next()

        try await server.send(.serverClose(code: 4001, reason: "bye"))
        let received = await connection.nextControl()
        let sent = await connection.nextControl()
        let echo = await frames.next()
        let outcome = await connection.outcome

        XCTAssertEqual(received, .closeReceived(code: 4001, reason: "bye"))
        XCTAssertEqual(sent, .closeSent(code: 4001, reason: ""))
        XCTAssertEqual(echo?.closeCode, 4001, "The close echoes the server's code")
        guard case .ended(.closed(code: 4001, reason: "bye", byServer: true), _) = outcome else {
            return XCTFail("The server's code and reason end it: \(outcome)")
        }
    }

    func testACloseWithoutAStatusIsAnsweredWithoutOne() async throws {
        let server = try await start()
        var frames = server.frames.makeAsyncIterator()
        var connection = try connect(server.url)
        _ = await connection.next()

        try await server.send(.serverClose(code: nil))
        let echo = await frames.next()
        let outcome = await connection.outcome

        XCTAssertEqual(echo?.opcode, .connectionClose)
        XCTAssertNil(echo?.closeCode)
        guard case .ended(.closed(code: nil, reason: "", byServer: true), _) = outcome else {
            return XCTFail("No status reads as none: \(outcome)")
        }
    }

    func testAClientCloseTheServerNeverAnswersEndsAfterTheCloseTimeout() async throws {
        let sleeper = TestSleeper(returnsAtOnce: false)
        let server = try await start(behavior: TestWebSocketServer.Behavior(answersClose: false))
        var requests = sleeper.requests.makeAsyncIterator()
        var connection = try connect(server.url, sleeper: sleeper)
        _ = await connection.next()

        connection.outbox.send(.close(code: 1000, reason: ""))
        // The handshake's deadline may have slept first; the close's wait is the one to end.
        while await requests.next() != WebSocketExecutor.closeTimeout {}
        sleeper.wake()
        var controls: [WebSocketControlEvent] = []
        while let event = await connection.next() {
            if case .control(let control, _) = event {
                controls.append(control)
            }
        }
        let outcome = await connection.outcome

        XCTAssertEqual(controls.first, .closeSent(code: 1000, reason: ""))
        XCTAssertTrue(controls.contains { if case .note(let text) = $0 { text.contains("didn't answer the close") } else { false } }, "\(controls)")
        guard case .ended(.closed(code: 1000, reason: "", byServer: false), _) = outcome else {
            return XCTFail("An unanswered close still ends closed: \(outcome)")
        }
    }

    func testAConnectionThatDropsWithoutACloseFrameEndsDropped() async throws {
        let server = try await start()
        var connection = try connect(server.url)
        _ = await connection.next()

        try await server.disconnect()
        let outcome = await connection.outcome

        guard case .ended(.dropped(let message), _) = outcome else {
            return XCTFail("No close frame means dropped: \(outcome)")
        }
        XCTAssertTrue(message.contains("1006"), message)
    }

    func testCancellingAnOpenConnectionClosesItNormally() async throws {
        let server = try await start()
        var frames = server.frames.makeAsyncIterator()
        var connection = try connect(server.url)
        _ = await connection.next()

        connection.task.cancel()
        let close = await frames.next()
        let outcome = await connection.outcome

        XCTAssertEqual(close?.closeCode, 1000)
        guard case .ended(.closed(code: 1000, reason: "", byServer: false), _) = outcome else {
            return XCTFail("Cancelling closes with 1000: \(outcome)")
        }
    }

    func testCancellingOrTimingOutTheHandshakeFails() async throws {
        let server = try await start { _ in .hang }
        var arrivals = server.arrivals.makeAsyncIterator()
        let cancelled = try connect(server.url)
        _ = await arrivals.next()
        cancelled.task.cancel()
        let timedOut = try connect(server.url, sleeper: TestSleeper(returnsAtOnce: true))

        guard case .failed(.cancelled) = await cancelled.outcome else {
            return XCTFail("A cancelled handshake fails as cancelled")
        }
        guard case .failed(.timedOut) = await timedOut.outcome else {
            return XCTFail("A handshake past its deadline fails as timed out")
        }
    }

    func testARefusalKeepsItsStatusHeadersBodyAndCookies() async throws {
        let body = #"{"error":"token expired"}"#
        let server = try await start { _ in
            let headers = [("Set-Cookie", "retry=1; Path=/"), ("Content-Type", "application/json")]
            return .refuse(status: 401, reason: "Unauthorized", headers: headers, body: body)
        }
        let jar = try XCTUnwrap(HTTPExecutor.defaultConfiguration().httpCookieStorage)
        let connection = try connect(server.url, cookies: jar)

        guard case .refused(let head, let reason) = await connection.outcome else {
            return XCTFail("A 401 refuses the connection")
        }
        XCTAssertEqual(head.statusCode, 401)
        XCTAssertEqual(head.header("Content-Type"), "application/json")
        XCTAssertEqual(head.body.utf8Text, body)
        XCTAssertEqual(reason, "The server answered 401 Unauthorized instead of switching protocols.")
        XCTAssertEqual(jar.cookies(for: try XCTUnwrap(URL(string: "http://127.0.0.1:\(server.port)/")))?.map(\.name), ["retry"])
    }

    func testARedirectIsNeverFollowed() async throws {
        let server = try await start { _ in .refuse(status: 302, reason: "Found", headers: [("Location", "wss://elsewhere/")]) }
        let connection = try connect(server.url)

        guard case .refused(let head, let reason) = await connection.outcome else {
            return XCTFail("A redirect refuses the connection")
        }
        XCTAssertEqual(head.statusCode, 302)
        XCTAssertEqual(reason, "The server answered 302 Found to wss://elsewhere/. WebSocket handshakes never follow redirects.")
        XCTAssertEqual(server.handshakes.count, 1)
    }

    func testTheJarsCookiesGoWithTheHandshakeUnlessACookieHeaderWasTyped() async throws {
        let server = try await start()
        let jar = try XCTUnwrap(HTTPExecutor.defaultConfiguration().httpCookieStorage)
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.name: "session", .value: "abc", .domain: "127.0.0.1", .path: "/"]))
        jar.setCookie(cookie)

        var fromJar = try connect(server.url, cookies: jar)
        _ = await fromJar.next()
        fromJar.task.cancel()
        _ = await fromJar.outcome
        var typed = try connect(server.url, headers: ["Cookie": "mine=1"], cookies: jar, handlesCookies: false)
        _ = await typed.next()
        typed.task.cancel()
        _ = await typed.outcome

        XCTAssertEqual(server.handshakes.map { $0.header("Cookie") }, ["session=abc", "mine=1"])
    }

    func testKeepalivePingsOnlyAfterSilenceAndAMissedPongDropsTheConnection() async throws {
        let sleeper = TestSleeper(returnsAtOnce: false)
        let server = try await start(behavior: TestWebSocketServer.Behavior(answersPings: false))
        var requests = sleeper.requests.makeAsyncIterator()
        let hello = WebSocketCommand.message(.text, Array("hi".utf8))
        var connection = try connect(server.url, keepalive: .seconds(30), sleeper: sleeper, commands: [hello])
        _ = await connection.next { if case .received = $0 { true } else { nil } }

        // Traffic since the last tick, so the first tick only resets.
        while await requests.next() != .seconds(30) {}
        sleeper.wake()
        _ = await requests.next()
        sleeper.wake()
        let ping = await connection.nextControl()
        _ = await requests.next()
        sleeper.wake()
        let outcome = await connection.outcome

        XCTAssertEqual(ping, .pingSent(id: 1), "The first ping comes only after a quiet interval")
        guard case .ended(.dropped(let message), _) = outcome else {
            return XCTFail("An unanswered keepalive drops the connection: \(outcome)")
        }
        XCTAssertTrue(message.contains("Keepalive ping 1"), message)
    }

    func testAnsweredKeepalivePingsRecurEachQuietInterval() async throws {
        let sleeper = TestSleeper(returnsAtOnce: false)
        let server = try await start()
        var requests = sleeper.requests.makeAsyncIterator()
        var connection = try connect(server.url, keepalive: .seconds(30), sleeper: sleeper)
        _ = await connection.next()

        var controls: [WebSocketControlEvent] = []
        for _ in 0..<2 {
            while await requests.next() != .seconds(30) {}
            sleeper.wake()
            controls.append(await connection.nextControl() ?? .note("none"))
            controls.append(await connection.nextControl() ?? .note("none"))
        }
        connection.task.cancel()
        _ = await connection.outcome

        XCTAssertEqual(controls.map { if case .pong(let id, _) = $0 { "pong \(id ?? 0)" } else { "\($0)" } }, [
            "\(WebSocketControlEvent.pingSent(id: 1))", "pong 1", "\(WebSocketControlEvent.pingSent(id: 2))", "pong 2"
        ], "The pong to one keepalive never delays the next")
    }

    func testAKeepaliveChangedWhileOpenRestartsItsIntervalAndCanTurnItOff() async throws {
        let sleeper = TestSleeper(returnsAtOnce: false)
        let server = try await start()
        var requests = sleeper.requests.makeAsyncIterator()
        var connection = try connect(server.url, keepalive: .seconds(30), sleeper: sleeper)
        _ = await connection.next()
        while await requests.next() != .seconds(30) {}

        connection.outbox.send(.keepalive(.seconds(45)))
        connection.outbox.send(.keepalive(.seconds(45)))
        var controls = [await connection.nextControl() ?? .note("none")]
        while await requests.next() != .seconds(45) {}
        sleeper.wake()
        controls.append(await connection.nextControl() ?? .note("none"))
        controls.append(await connection.nextControl() ?? .note("none"))
        connection.outbox.send(.keepalive(nil))
        controls.append(await connection.nextControl() ?? .note("none"))
        connection.task.cancel()
        _ = await connection.outcome

        XCTAssertEqual(controls.map { if case .pong(let id, _) = $0 { "pong \(id ?? 0)" } else { "\($0)" } }, [
            "\(WebSocketControlEvent.note("Keepalive now pings after 45 s of silence."))",
            "\(WebSocketControlEvent.pingSent(id: 1))",
            "pong 1",
            "\(WebSocketControlEvent.note("Keepalive turned off."))"
        ], "One note for a repeated interval, and the first ping waits out the new one")
        XCTAssertFalse(sleeper.durations.drop { $0 != .seconds(45) }.contains(.seconds(30)), "The old interval's timer stops")
    }

    func testMessagesQueuedAfterACloseAreNotSent() async throws {
        let server = try await start(behavior: TestWebSocketServer.Behavior(answersClose: false))
        var connection = try connect(server.url, commands: [.close(code: 1000, reason: ""), .message(.text, Array("late".utf8))])

        _ = await connection.next()
        let closed = await connection.nextControl()
        let note = await connection.nextControl()
        try await server.disconnect()
        _ = await connection.outcome

        XCTAssertEqual(closed, .closeSent(code: 1000, reason: ""))
        XCTAssertEqual(note, .note("Message 1 wasn't sent: the connection is closing."))
    }
}
