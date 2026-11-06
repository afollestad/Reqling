import Foundation
import NIOWebSocket
@testable import ReqlingKit
import XCTest

/// WebSocket runs through `RequestRunner`: the handshake built as HTTP's, on-connect messages, live sends and pings,
/// Disconnect, an agent's bounds, and what the history keeps.
@MainActor
extension RequestRunnerTests {
    private func socketServer(
        behavior: TestWebSocketServer.Behavior = TestWebSocketServer.Behavior(),
        answer: @escaping @Sendable (TestWebSocketServer.Handshake) -> TestWebSocketServer.Answer = { _ in .accept() }
    ) async throws -> TestWebSocketServer {
        let server = try await TestWebSocketServer.start(behavior: behavior, answer: answer)
        socketServers.append(server)
        return server
    }

    /// A project with one WebSocket request to `url`, `{{token}}` a secret.
    private func makeSocketProject(url: String, _ configure: (inout WebSocketRequestSpec) -> Void = { _ in }) throws -> RunKey {
        let project = try fixture.library.createProject(named: "Sockets")
        var spec = WebSocketRequestSpec(url: url)
        configure(&spec)
        let request = RequestItem(name: "Chat", kind: .webSocket(spec))
        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables = [
                Variable(key: "token", value: "s3cr3t-token", isSecret: true),
                Variable(key: "room", value: "lobby")
            ]
            try document.insert(.request(request), into: nil)
        }
        return RunKey(request.id, in: project)
    }

    /// Never returns on its own, so a handshake's deadline never passes mid-test.
    private var patientSleeper: TestSleeper {
        TestSleeper(returnsAtOnce: false)
    }

    private func texts(_ record: WebSocketRecord?, _ direction: MessageDirection) -> [String] {
        record?.entries.compactMap { $0.message?.direction == direction ? $0.message?.text : nil } ?? []
    }

    func testOnConnectMessagesGoInOrderResolvedAndMasked() async throws {
        let server = try await socketServer()
        let key = try makeSocketProject(url: "\(server.url)/chat?room={{room}}") { spec in
            spec.headers = [KeyValuePair(key: "Authorization", value: "Bearer {{token}}")]
            spec.messages = [
                WebSocketMessage(text: #"{"auth":"{{token}}"}"#),
                WebSocketMessage(text: "skipped", sendsOnConnect: false),
                WebSocketMessage(format: .binary, text: "aGk")
            ]
        }
        var frames = server.frames.makeAsyncIterator()
        let runner = makeRunner(sleep: patientSleeper)

        let run = Task { await runner.run(key.requestID, in: key.projectID) }
        await waitUntil("both echoes arrive") { self.texts(runner.latest[key]?.webSocket, .received).count == 2 }
        let first = await frames.next()
        let second = await frames.next()
        runner.cancel(key.requestID, in: key.projectID)
        let exchange = await run.value
        let record = try XCTUnwrap(exchange.webSocket)

        XCTAssertEqual(first?.text, #"{"auth":"s3cr3t-token"}"#, "The server gets the secret")
        XCTAssertEqual(second?.data, Array("hi".utf8), "Binary goes as the base64's bytes, padding or not")
        XCTAssertEqual(texts(record, .sent), [#"{"auth":"••••••"}"#, "aGk="], "The record shows what was sent, masked")
        XCTAssertEqual(server.handshakes.first?.uri, "/chat?room=lobby")
        XCTAssertEqual(server.handshakes.first?.header("Authorization"), "Bearer s3cr3t-token")
        XCTAssertEqual(exchange.request?.headers.first { $0.key == "Authorization" }?.value, "Bearer ••••••")
        XCTAssertEqual(exchange.request?.url, "\(server.url)/chat?room=lobby")
        XCTAssertEqual(record.end, .stopped, "Disconnect ends it stopped")
        XCTAssertEqual(record.close, WebSocketRecord.Close(code: 1000, byServer: false))
        XCTAssertEqual(exchange.outcomeKind, .succeeded)
        XCTAssertEqual(runner.history.runs(for: key.requestID, in: key.projectID).first?.status, .webSocket(.closed(code: 1000)))
    }

    func testUnresolvedVariablesAndBadBase64FailBeforeConnecting() async throws {
        let server = try await socketServer()
        let unresolved = try makeSocketProject(url: server.url) { $0.messages = [WebSocketMessage(text: "{{missing}}")] }
        let badBase64 = try makeSocketProject(url: server.url) {
            $0.messages = [WebSocketMessage(), WebSocketMessage(format: .binary, text: "not base64!")]
        }
        let runner = makeRunner(sleep: patientSleeper)

        let first = await runner.run(unresolved.requestID, in: unresolved.projectID)
        let second = await runner.run(badBase64.requestID, in: badBase64.projectID)

        XCTAssertEqual(first.failure?.message, "Undefined variables: {{missing}}. Define them in an environment, or remove them.")
        XCTAssertEqual(second.failure?.message, "Message 2 isn't valid base64, which a binary message is written in.")
        XCTAssertTrue(server.handshakes.isEmpty, "Nothing connects")
    }

    func testAURLWithAFragmentOrCredentialsOrAnotherSchemeIsRefused() async throws {
        let runner = makeRunner(sleep: patientSleeper)
        let cases = [
            ("ws://localhost/chat#top", "can't have a #fragment"),
            ("wss://user:pw@localhost/", "can't carry credentials"),
            ("ftp://localhost/", "starts with ws:// or wss://")
        ]
        for (url, expected) in cases {
            let key = try makeSocketProject(url: url)
            let exchange = await runner.run(key.requestID, in: key.projectID)
            XCTAssertTrue(exchange.failure?.message.contains(expected) == true, "\(url): \(String(describing: exchange.failure))")
        }
    }

    func testLiveSendsResolveAgainstTheRunAndPingsShowTheirPong() async throws {
        let server = try await socketServer()
        let key = try makeSocketProject(url: server.url)
        let runner = makeRunner(sleep: patientSleeper)

        let run = Task { await runner.run(key.requestID, in: key.projectID) }
        await waitUntil("the connection opens") { runner.openSockets.contains(key) }
        try runner.sendWebSocketMessage(WebSocketMessage(text: "token={{token}}"), to: key.requestID, in: key.projectID)
        try runner.pingWebSocket(key.requestID, in: key.projectID)
        await waitUntil("the echo and pong show") {
            let entries = runner.latest[key]?.webSocket?.entries ?? []
            let ponged = entries.contains { if case .control(.received, let text) = $0.kind { text.hasPrefix("Pong 1") } else { false } }
            return ponged && entries.contains { $0.message?.direction == .received }
        }
        XCTAssertThrowsError(try runner.sendWebSocketMessage(WebSocketMessage(text: "{{nope}}"), to: key.requestID, in: key.projectID))
        runner.cancel(key.requestID, in: key.projectID)
        XCTAssertFalse(runner.openSockets.contains(key), "Disconnect takes no more messages at once")
        XCTAssertThrowsError(try runner.sendWebSocketMessage(WebSocketMessage(text: "late"), to: key.requestID, in: key.projectID))
        let exchange = await run.value

        XCTAssertEqual(texts(exchange.webSocket, .sent), ["token=••••••"])
        XCTAssertEqual(texts(exchange.webSocket, .received), ["token=s3cr3t-token"], "What a server echoes is kept as received")
    }

    func testAnAgentsBoundsCloseTheConnectionNormally() async throws {
        let server = try await socketServer()
        let key = try makeSocketProject(url: server.url) { spec in
            spec.messages = ["one", "two", "three"].map { WebSocketMessage(text: $0) }
        }
        let runner = makeRunner(sleep: patientSleeper)

        let exchange = await runner.run(key.requestID, in: key.projectID, options: RunOptions(streamLimit: StreamLimit(maxEvents: 2)))
        let record = try XCTUnwrap(exchange.webSocket)

        XCTAssertEqual(record.end, .limit)
        XCTAssertEqual(record.close?.code, 1000)
        XCTAssertGreaterThanOrEqual(record.receivedCount, 2)
        XCTAssertEqual(exchange.outcomeKind, .succeeded)
    }

    func testATimeBoundStartsOnceTheConnectionOpens() async throws {
        let sleeper = TestSleeper(returnsAtOnce: false)
        let server = try await socketServer()
        let key = try makeSocketProject(url: server.url)
        var requests = sleeper.requests.makeAsyncIterator()
        let runner = makeRunner(sleep: sleeper)

        let run = Task { await runner.run(key.requestID, in: key.projectID, options: RunOptions(streamLimit: StreamLimit(maxDuration: .seconds(7)))) }
        while await requests.next() != .seconds(7) {}
        sleeper.wake()
        let exchange = await run.value

        XCTAssertEqual(exchange.webSocket?.end, .limit)
    }

    func testARefusalIsRecordedWithTheServersAnswer() async throws {
        let server = try await socketServer { _ in .refuse(status: 403, reason: "Forbidden", body: "token={{token}} rejected") }
        let key = try makeSocketProject(url: "\(server.url)/?key={{token}}")
        let runner = makeRunner(sleep: patientSleeper)

        let exchange = await runner.run(key.requestID, in: key.projectID)
        let record = try XCTUnwrap(exchange.webSocket)

        XCTAssertEqual(record.handshake?.statusCode, 403)
        XCTAssertEqual(record.end, .refused(message: "The server answered 403 Forbidden instead of switching protocols."))
        XCTAssertFalse(record.url.contains("s3cr3t"), "The record's URL is masked: \(record.url)")
        XCTAssertEqual(record.url, exchange.request?.url, "As the masked handshake shows it")
        XCTAssertEqual(record.handshake?.url, record.url)
        XCTAssertEqual(exchange.outcomeKind, .failed)
        XCTAssertEqual(runner.history.runs(for: key.requestID, in: key.projectID).first?.status, .webSocket(.refused(statusCode: 403)))
    }

    /// A change to the saved keepalive, from the window or an agent, reaches the open connection; other edits don't.
    func testTheOpenConnectionFollowsChangesToTheSavedKeepalive() async throws {
        let server = try await socketServer()
        let key = try makeSocketProject(url: server.url)
        let runner = makeRunner(sleep: patientSleeper)
        func save(_ change: @escaping (inout WebSocketRequestSpec) -> Void) throws {
            try fixture.library.mutate(key.projectID) { document in
                try document.updateRequest(key.requestID) { item in
                    guard var spec = item.kind.webSocketSpec else {
                        return
                    }
                    change(&spec)
                    item.kind = .webSocket(spec)
                }
            }
        }
        func notes() -> [String] {
            runner.latest[key]?.webSocket?.entries.compactMap { if case .note(let text) = $0.kind { text } else { nil } } ?? []
        }

        let run = Task { await runner.run(key.requestID, in: key.projectID) }
        await waitUntil("the connection opens") { runner.openSockets.contains(key) }
        try save { $0.options.keepaliveSeconds = 20 }
        await waitUntil("the new keepalive shows") { notes().count == 1 }
        try save { $0.subprotocols = ["chat"] }
        try save { $0.options.keepaliveSeconds = nil }
        await waitUntil("the keepalive turns off") { notes().count == 2 }
        runner.cancel(key.requestID, in: key.projectID)
        let exchange = await run.value

        XCTAssertEqual(
            exchange.webSocket?.entries.compactMap { if case .note(let text) = $0.kind { text } else { nil } },
            ["Keepalive now pings after 20 s of silence.", "Keepalive turned off."]
        )
    }

    /// A value an agent or a hand edit stores can't overflow the timer, or ping more than once a second.
    func testAKeepaliveIsHeldToItsRange() {
        XCTAssertEqual(RequestRunner.keepalive(seconds: 1e300), .seconds(3_600))
        XCTAssertEqual(RequestRunner.keepalive(seconds: 0.5), .seconds(1))
        XCTAssertEqual(RequestRunner.keepalive(seconds: 25), .seconds(25))
        for off in [nil, 0, -5, .nan] as [Double?] {
            XCTAssertNil(RequestRunner.keepalive(seconds: off), "\(String(describing: off))")
        }
    }

    func testForgettingARequestClosesItsOpenConnection() async throws {
        let server = try await socketServer()
        let key = try makeSocketProject(url: server.url)
        var frames = server.frames.makeAsyncIterator()
        let runner = makeRunner(sleep: patientSleeper)

        let run = Task { await runner.run(key.requestID, in: key.projectID) }
        await waitUntil("the connection opens") { runner.openSockets.contains(key) }
        runner.forget(key.requestID, in: key.projectID)
        let close = await frames.next()
        _ = await run.value

        XCTAssertEqual(close?.closeCode, 1000)
        XCTAssertFalse(runner.openSockets.contains(key))
        XCTAssertNil(runner.latest[key])
        XCTAssertTrue(runner.history.runs(for: key.requestID, in: key.projectID).isEmpty, "A forgotten run never records")
    }
}
