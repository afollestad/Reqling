import Foundation
import NIOCore
import NIOWebSocket
@testable import ReqlingKit
import XCTest

/// A server that breaks RFC 6455 gets what a browser would give it: a refused handshake, or a close with 1002, 1007, or
/// 1009, with everything before the violation still reported.
extension WebSocketExecutorTests {
    func testFramesNoClientMayGetCloseWithAProtocolError() async throws {
        let cases: [(WebSocketFrame, String)] = [
            (.server(.text, Array("hi".utf8), maskKey: .random()), "masked a frame"),
            (.server(.text, Array("hi".utf8), rsv1: true), "reserved bit"),
            (.server(WebSocketOpcode(encodedWebSocketOpcode: 0x3)!, []), "opcode 0x3"),
            (.serverClose(code: 1005), "code 1005"),
            (.server(.connectionClose, [0x03]), "malformed")
        ]
        for (frame, expected) in cases {
            let server = try await start()
            var frames = server.frames.makeAsyncIterator()
            var connection = try connect(server.url)
            _ = await connection.next()

            try await server.send(frame)
            let close = await frames.next()
            let outcome = await connection.outcome

            XCTAssertEqual(close?.closeCode, 1002, expected)
            guard case .ended(.violation(code: 1002, let message), _) = outcome else {
                XCTFail("\(expected): \(outcome)")
                continue
            }
            XCTAssertTrue(message.contains(expected), message)
        }
    }

    func testTextThatIsNotUTF8IsReportedThenClosedWith1007() async throws {
        let server = try await start { _ in .accept(frames: [.server(text: "fine"), .server(.text, [0x68, 0xFF])]) }
        var frames = server.frames.makeAsyncIterator()
        var connection = try connect(server.url)

        var received: [[UInt8]] = []
        while received.count < 2, let event = await connection.next() {
            if case .received(.text, let bytes, _) = event {
                received.append(bytes)
            }
        }
        let close = await frames.next()
        let outcome = await connection.outcome

        XCTAssertEqual(received, [Array("fine".utf8), [0x68, 0xFF]], "What came before, and the offending message, both arrive")
        XCTAssertEqual(close?.closeCode, 1007)
        guard case .ended(.violation(code: 1007, "A text message wasn't valid UTF-8."), _) = outcome else {
            return XCTFail("\(outcome)")
        }
    }

    func testAMessageOverTheLimitClosesWith1009WholeOrInFragments() async throws {
        let fragments: [WebSocketFrame] = [
            .server(.binary, [UInt8](repeating: 1, count: 700), fin: false),
            .server(.continuation, [UInt8](repeating: 2, count: 700))
        ]
        for frames in [[.server(.binary, [UInt8](repeating: 0, count: 2_048))], fragments] {
            let server = try await start { _ in .accept(frames: frames) }
            var serverFrames = server.frames.makeAsyncIterator()
            let connection = try connect(server.url, messageLimit: 1_024)

            let close = await serverFrames.next()
            let outcome = await connection.outcome

            XCTAssertEqual(close?.closeCode, 1009)
            guard case .ended(.violation(code: 1009, let message), _) = outcome else {
                XCTFail("\(outcome)")
                continue
            }
            XCTAssertTrue(message.contains("larger than"), message)
        }
    }

    func testAnOutgoingMessageOverTheLimitIsNotSent() async throws {
        let server = try await start()
        var connection = try connect(server.url, messageLimit: 1_024, commands: [.message(.binary, [UInt8](repeating: 0, count: 2_048))])

        _ = await connection.next()
        let note = await connection.nextControl()
        connection.task.cancel()
        _ = await connection.outcome

        XCTAssertEqual(note, .note("Message 1 is larger than 1 KB, so it wasn't sent."))
    }

    func testAHandshakeThatBreaksTheRulesIsRefusedWithItsHead() async throws {
        struct Case {
            let answer: TestWebSocketServer.Answer
            var offered: [String] = []
            let expected: String
        }
        let cases = [
            Case(answer: .accept(wrongAccept: true), expected: "Sec-WebSocket-Accept doesn't match"),
            Case(answer: .accept(subprotocol: "mqtt"), offered: ["chat"], expected: "chose the subprotocol “mqtt”, but Reqling offered chat"),
            Case(answer: .accept(subprotocol: "chat"), expected: "chose the subprotocol “chat”, but none were offered"),
            Case(answer: .accept(headers: [("Sec-WebSocket-Extensions", "permessage-deflate")]), expected: "“permessage-deflate”, an extension")
        ]
        for testCase in cases {
            let (answer, expected) = (testCase.answer, testCase.expected)
            let server = try await start { _ in answer }
            let connection = try connect(server.url, subprotocols: testCase.offered)

            guard case .refused(let head, let reason) = await connection.outcome else {
                XCTFail(expected)
                continue
            }
            XCTAssertEqual(head.statusCode, 101, expected)
            XCTAssertTrue(reason.contains(expected), reason)
        }
    }

    /// A typed `Sec-WebSocket-Extensions` is dropped: no extension is supported, so offering one would break the
    /// connection the moment a server took it.
    func testATypedExtensionOfferIsNeverSent() async throws {
        let server = try await start()
        var connection = try connect(server.url, headers: ["Sec-WebSocket-Extensions": "permessage-deflate"])

        _ = await connection.next()
        connection.task.cancel()
        _ = await connection.outcome

        XCTAssertNil(server.handshakes.first?.header("Sec-WebSocket-Extensions"))
    }
}
