import Foundation
import GRPCCore
@testable import ReqlingKit
import XCTest

/// Fast streams against a stalled receiver: the executor's buffer stays bounded, and cancelling skips its backlog.
extension GRPCExecutorTests {
    private static let flood = 20_000

    func testAStalledReceiverLosesTheOldestEventsAndIsToldHowMany() async throws {
        let (server, streamed) = try await startFlooding()
        let gate = TestGate()
        let log = EventLog()
        let request = call(server, "ServerStream", .serverStreaming, body: .message(try encode("x", index: Self.flood)))

        let running = Task {
            await GRPCExecutor().execute(request) { event in
                log.append(event)
                if case .received = event, log.events.received.count == 1 {
                    await gate.wait()
                }
            }
        }
        await streamed()
        gate.open()
        let outcome = await bounded("flood", running)

        XCTAssertEqual(outcome?.status?.isOK, true)
        let delivered = log.events.filter(\.isMessage).count
        let omitted = log.events.omittedCount
        XCTAssertGreaterThan(omitted, 0, "The buffer is bounded at \(GRPCExecutor.eventBufferLimit) events")
        XCTAssertEqual(delivered + omitted, Self.flood + 1, "Every message is delivered or counted, by the last totals")
        XCTAssertEqual(log.events.omitted?.sent, 0, "The one request message was delivered")
        XCTAssertEqual(log.events.sequences, log.events.sequences.sorted(), "Sequences follow delivery order")
        XCTAssertEqual(log.events.sequences.last, Self.flood, "Counting the request message first")
        let reports = log.events.filter { if case .omitted = $0 { true } else { false } }
        XCTAssertLessThanOrEqual(reports.count, delivered, "Reports never outnumber what was delivered")
    }

    func testCancellingSkipsTheBacklogInsteadOfDeliveringIt() async throws {
        let (server, streamed) = try await startFlooding()
        let gate = TestGate()
        let log = EventLog()
        let request = call(server, "ServerStream", .serverStreaming, body: .message(try encode("flood", index: Self.flood)))

        let running = Task {
            await GRPCExecutor().execute(request) { event in
                log.append(event)
                if case .received = event, log.events.received.count == 1 {
                    await gate.wait()
                }
            }
        }
        await streamed()
        running.cancel()
        gate.open()
        let outcome = await bounded("cancel", running)

        XCTAssertEqual(outcome, .failed(.cancelled))
        XCTAssertEqual(log.events.received.count, 1, "Nothing queued is delivered after the cancel")
        XCTAssertGreaterThan(log.events.omittedCount, 0)
    }

    /// The call has ended (the server finished) and only the backlog is left to deliver when the cancel lands.
    func testCancellingWhileTheBacklogDrainsSkipsTheRest() async throws {
        let (server, streamed) = try await startFlooding()
        let gate = TestGate()
        let log = EventLog()
        let (drainStarted, drain) = AsyncStream.makeStream(of: Void.self)
        let request = call(server, "ServerStream", .serverStreaming, body: .message(try encode("x", index: 5_000)))

        let running = Task {
            await GRPCExecutor(beforeDrain: { drain.yield() }).execute(request) { event in
                log.append(event)
                if case .received = event, log.events.received.count == 1 {
                    await gate.wait()
                }
            }
        }
        await streamed()
        for await _ in drainStarted {
            break
        }
        running.cancel()
        gate.open()
        let outcome = await bounded("drain", running)

        XCTAssertEqual(outcome?.status?.isOK, true, "The call itself finished before the cancel")
        XCTAssertEqual(log.events.received.count, 1, "The backlog is skipped, not delivered")
        XCTAssertEqual(log.events.omittedCount, 4_999, "Every other received message is counted")
    }

    /// A server whose stream calls back once every message is written; the returned function waits for that.
    private func startFlooding() async throws -> (GRPCTestServer, () async -> Void) {
        let (signal, continuation) = AsyncStream.makeStream(of: Void.self)
        var service = EchoService()
        service.onStreamed = { continuation.yield() }
        let server = try await GRPCTestServer.start([service])
        addTeardownBlock { await server.stop() }
        return (server, {
            for await _ in signal {
                break
            }
        })
    }

    private func encode(_ text: String, index: Int) throws -> [UInt8] {
        try Message.with {
            $0.text = text
            $0.index = Int32(index)
        }.serializedBytes()
    }
}

extension [GRPCCallEvent] {
    /// The latest running totals.
    var omitted: (sent: Int, received: Int)? {
        compactMap { event in
            if case .omitted(let sent, let received) = event {
                return (sent, received)
            }
            return nil
        }.last
    }

    var omittedCount: Int {
        omitted.map { $0.sent + $0.received } ?? 0
    }

    var sequences: [Int] {
        compactMap { event in
            switch event {
            case .sent(_, let sequence, _), .received(_, let sequence, _): sequence
            default: nil
            }
        }
    }
}
