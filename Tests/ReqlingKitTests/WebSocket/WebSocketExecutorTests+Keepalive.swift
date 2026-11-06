import Foundation
@testable import ReqlingKit
import XCTest

/// Keepalive pings: when they go out, a missed pong, and an interval changed while the connection is open.
extension WebSocketExecutorTests {
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
}
