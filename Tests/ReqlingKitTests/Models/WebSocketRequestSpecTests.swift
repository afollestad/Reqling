import Foundation
@testable import ReqlingKit
import XCTest

/// A WebSocket request's file shape, its handshake as an HTTP GET, and its automatic headers.
final class WebSocketRequestSpecTests: XCTestCase {
    func testARequestFileRoundTripsUnderItsKindAndLeavesDefaultsOut() throws {
        let request = RequestItem(name: "Chat", kind: .webSocket(WebSocketRequestSpec(
            url: "wss://{{host}}/chat",
            subprotocols: ["chat"],
            messages: [WebSocketMessage(text: "hi"), WebSocketMessage(format: .binary, text: "AAE=", sendsOnConnect: false)],
            options: WebSocketRequestOptions(keepaliveSeconds: 30)
        )))

        let data = try JSONEncoder().encode(request)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let spec = try XCTUnwrap(object["websocket"] as? [String: Any])
        let decoded = try JSONDecoder().decode(RequestItem.self, from: data)

        XCTAssertEqual(object["kind"] as? String, "websocket")
        XCTAssertNil(spec["disabledAutoHeaders"], "Empty lists stay out of the file")
        XCTAssertNil(spec["enabledAutoHeaders"])
        XCTAssertEqual((spec["messages"] as? [[String: Any]])?.last?["sendOnConnect"] as? Bool, false)
        XCTAssertEqual(decoded, request)
    }

    /// A hand-written file names only what it needs; its messages get IDs from their place, the same on every read.
    func testAHandWrittenSpecFillsInDefaultsAndStableIDs() throws {
        let json = Data(("{\"id\": \"2B0C2C33-4F55-4B2D-8F11-3D8A3D7C6B10\", \"name\": \"Echo\", \"kind\": \"websocket\", "
            + #""websocket": {"url": "ws://localhost", "messages": [{"text": "a"}, {"text": "b"}]}}"#).utf8)

        let first = try JSONDecoder().decode(RequestItem.self, from: json)
        let second = try JSONDecoder().decode(RequestItem.self, from: json)
        let spec = try XCTUnwrap(first.kind.webSocketSpec)

        XCTAssertEqual(spec.messages.map(\.text), ["a", "b"])
        XCTAssertEqual(spec.messages.map(\.format), [.text, .text])
        XCTAssertTrue(spec.messages.allSatisfy(\.sendsOnConnect))
        XCTAssertEqual(Set(spec.messages.map(\.id)).count, 2)
        XCTAssertEqual(first, second)
        XCTAssertEqual(spec.auth, .inherit)
    }

    func testTheHandshakeIsAGETThatNeverRedirectsWithItsSubprotocolsAndOrigin() {
        var spec = WebSocketRequestSpec(
            url: "wss://{{host}}:8443/chat",
            headers: [KeyValuePair(key: "X-Trace", value: "1")],
            subprotocols: ["chat", "superchat"],
            auth: .bearer(token: "{{token}}"),
            options: WebSocketRequestOptions(timeoutSeconds: 5, verifyTLS: false)
        )

        let handshake = spec.handshake
        spec.enabledAutoHeaders = ["origin"]
        let withOrigin = spec.handshake
        spec.headers.append(KeyValuePair(key: "Origin", value: "https://app.example.com"))
        spec.headers.append(KeyValuePair(key: "Sec-WebSocket-Protocol", value: "mine"))
        let typed = spec.handshake

        XCTAssertEqual(handshake.method, .get)
        XCTAssertEqual(handshake.options, HTTPRequestOptions(timeoutSeconds: 5, followRedirects: false, verifyTLS: false))
        XCTAssertEqual(handshake.auth, .bearer(token: "{{token}}"))
        XCTAssertTrue(handshake.disabledAutoHeaders.contains("accept"))
        XCTAssertEqual(handshake.headers.map(\.key), ["X-Trace", "Sec-WebSocket-Protocol"])
        XCTAssertEqual(handshake.headers.last?.value, "chat, superchat")
        XCTAssertEqual(withOrigin.headers.last.map { "\($0.key): \($0.value)" }, "Origin: https://{{host}}:8443", "Off until turned on")
        XCTAssertEqual(typed.headers.filter { $0.key == "Origin" }.map(\.value), ["https://app.example.com"], "A typed one replaces it")
        XCTAssertEqual(typed.headers.filter { $0.key == "Sec-WebSocket-Protocol" }.map(\.value), ["mine"])
    }

    func testTheOriginComesFromTheURLsSchemeAndHost() {
        XCTAssertEqual(WebSocketRequestSpec.origin(for: "wss://chat.example.com/socket?x=1"), "https://chat.example.com")
        XCTAssertEqual(WebSocketRequestSpec.origin(for: "ws://localhost:8080"), "http://localhost:8080")
        XCTAssertEqual(WebSocketRequestSpec.origin(for: "{{base}}/socket"), "http://{{base}}")
        XCTAssertNil(WebSocketRequestSpec.origin(for: ""))
    }

    func testAutomaticHeadersSwitchEitherWay() throws {
        var spec = WebSocketRequestSpec(url: "wss://example.com", subprotocols: ["chat"])
        let headers = HTTPRequestBuilder.autoHeaders(for: spec, userAgent: "Reqling/1.0")
        let userAgent = try XCTUnwrap(headers.first { $0.key == "user-agent" })
        let origin = try XCTUnwrap(headers.first { $0.key == "origin" })

        XCTAssertEqual(headers.map(\.name), [
            "User-Agent", "Origin", "Sec-WebSocket-Protocol", "Host", "Upgrade", "Connection", "Sec-WebSocket-Key",
            "Sec-WebSocket-Version", "Cookie"
        ])
        XCTAssertEqual(origin.value, "https://example.com")
        XCTAssertTrue(spec.sends(userAgent))
        XCTAssertFalse(spec.sends(origin))
        spec.setSends(userAgent, false)
        spec.setSends(origin, true)
        XCTAssertEqual(spec.disabledAutoHeaders, ["user-agent"])
        XCTAssertEqual(spec.enabledAutoHeaders, ["origin"])
        XCTAssertFalse(spec.sends(userAgent))
        XCTAssertTrue(spec.sends(origin))
    }

    func testAPastedQueryMovesIntoTheTable() {
        let spec = WebSocketRequestSpec(url: "wss://example.com/chat?room=a&token={{token}}").normalized()

        XCTAssertEqual(spec.url, "wss://example.com/chat")
        XCTAssertEqual(spec.queryParameters.map(\.key), ["room", "token"])
        XCTAssertEqual(spec.displayURL, "wss://example.com/chat?room=a&token={{token}}")
    }
}
