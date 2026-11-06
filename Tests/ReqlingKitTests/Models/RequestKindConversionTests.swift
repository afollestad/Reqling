import ReqlingKit
import XCTest

final class RequestKindConversionTests: XCTestCase {
    func testSharedSettingsCarryBothWays() throws {
        let header = KeyValuePair(key: "x-trace", value: "{{trace}}")
        let http = RequestKind.http(HTTPRequestSpec(
            url: "https://{{host}}:8443",
            headers: [header],
            auth: .bearer(token: "{{token}}"),
            options: HTTPRequestOptions(timeoutSeconds: 5, verifyTLS: false)
        ))

        let grpc = try XCTUnwrap(http.converted(to: .grpc).grpcSpec)

        XCTAssertEqual(grpc.target, "{{host}}:8443")
        XCTAssertEqual(grpc.security, .tls)
        XCTAssertEqual(grpc.metadata, [header])
        XCTAssertEqual(grpc.deadlineSeconds, 5)
        XCTAssertEqual(grpc.verifyTLS, false)
        XCTAssertEqual(grpc.auth, .bearer(token: "{{token}}"))
        XCTAssertFalse(http.losesContent(convertingTo: .grpc))
        XCTAssertEqual(http.converted(to: .grpc).converted(to: .http), http)
    }

    func testANewRequestSwitchesWithoutLoss() {
        XCTAssertFalse(RequestKind.http(HTTPRequestSpec()).losesContent(convertingTo: .grpc))
        XCTAssertFalse(RequestKind.grpc(GRPCRequestSpec()).losesContent(convertingTo: .http))
    }

    func testWhatOnlyOneProtocolHasIsReportedAsLost() {
        XCTAssertTrue(RequestKind.http(HTTPRequestSpec(method: .post)).losesContent(convertingTo: .grpc))
        XCTAssertTrue(RequestKind.http(HTTPRequestSpec(url: "https://api.example.com/v1")).losesContent(convertingTo: .grpc))
        XCTAssertTrue(RequestKind.grpc(GRPCRequestSpec(service: "helloworld.Greeter")).losesContent(convertingTo: .http))
        XCTAssertTrue(RequestKind.grpc(GRPCRequestSpec(target: "unix:/tmp/app.sock")).losesContent(convertingTo: .http))
    }

    func testAURLWithAPathLeavesTheTargetEmpty() {
        let grpc = RequestKind.http(HTTPRequestSpec(url: "http://localhost:8080/users")).converted(to: .grpc)

        XCTAssertEqual(grpc.grpcSpec?.target, "")
    }

    func testATrailingSlashStillCarriesTheHost() {
        let http = RequestKind.http(HTTPRequestSpec(url: "http://localhost:8080/"))

        XCTAssertEqual(http.converted(to: .grpc).grpcSpec?.target, "localhost:8080")
        XCTAssertTrue(http.losesContent(convertingTo: .grpc), "the slash itself does not come back")
    }

    func testConvertingToTheSameKindIsANoOp() {
        let http = RequestKind.http(HTTPRequestSpec(method: .post))

        XCTAssertEqual(http.converted(to: .http), http)
        XCTAssertFalse(http.losesContent(convertingTo: .http))
    }

    func testHTTPAndWebSocketShareTheURLQueryAndSettings() throws {
        let http = RequestKind.http(HTTPRequestSpec(
            url: "https://{{host}}/chat",
            queryParameters: [KeyValuePair(key: "room", value: "a")],
            headers: [KeyValuePair(key: "x-trace", value: "1")],
            disabledAutoHeaders: ["user-agent"],
            auth: .bearer(token: "{{token}}"),
            options: HTTPRequestOptions(timeoutSeconds: 5, verifyTLS: false)
        ))

        let webSocket = try XCTUnwrap(http.converted(to: .webSocket).webSocketSpec)

        XCTAssertEqual(webSocket.url, "wss://{{host}}/chat")
        XCTAssertEqual(webSocket.queryParameters.map(\.key), ["room"])
        XCTAssertEqual(webSocket.disabledAutoHeaders, ["user-agent"])
        XCTAssertEqual(webSocket.options, WebSocketRequestOptions(timeoutSeconds: 5, verifyTLS: false))
        XCTAssertFalse(http.losesContent(convertingTo: .webSocket))
        XCTAssertEqual(RequestKind.webSocket(webSocket).converted(to: .http), http)
        XCTAssertEqual(RequestKind.http(HTTPRequestSpec(url: "HTTP://x")).converted(to: .webSocket).webSocketSpec?.url, "ws://x")
    }

    func testWhatOnlyAWebSocketHasIsReportedAsLost() {
        XCTAssertFalse(RequestKind.webSocket(WebSocketRequestSpec()).losesContent(convertingTo: .http))
        XCTAssertTrue(RequestKind.webSocket(WebSocketRequestSpec(messages: [WebSocketMessage(text: "hi")])).losesContent(convertingTo: .http))
        XCTAssertTrue(RequestKind.webSocket(WebSocketRequestSpec(subprotocols: ["chat"])).losesContent(convertingTo: .http))
        XCTAssertTrue(RequestKind.http(HTTPRequestSpec(method: .post)).losesContent(convertingTo: .webSocket))
    }

    func testGRPCAndWebSocketConvertThroughHTTP() {
        let grpc = RequestKind.grpc(GRPCRequestSpec(target: "{{host}}:443", security: .tls, metadata: [KeyValuePair(key: "x", value: "1")]))

        let webSocket = grpc.converted(to: .webSocket)

        XCTAssertEqual(webSocket.webSocketSpec?.url, "wss://{{host}}:443")
        XCTAssertEqual(webSocket.webSocketSpec?.headers.map(\.key), ["x"])
        XCTAssertEqual(webSocket.converted(to: .grpc), grpc)
        XCTAssertTrue(RequestKind.webSocket(WebSocketRequestSpec(url: "wss://host/path")).losesContent(convertingTo: .grpc))
    }
}
