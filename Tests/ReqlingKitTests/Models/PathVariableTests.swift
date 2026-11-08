import Foundation
@testable import ReqlingKit
import ReqlingScriptProtocol
import XCTest

/// Path variables: which URL segments are `:name`s, how a value is encoded, and how a spec's rows follow its URL.
final class PathVariableTests: XCTestCase {
    func testOnlyWholePathSegmentsAreVariables() {
        XCTAssertEqual(RequestPathVariables.names(in: "https://api.test:8443/users/:id/posts/:post-id"), ["id", "post-id"])
        XCTAssertEqual(RequestPathVariables.names(in: "{{baseUrl}}/pets/:petId"), ["petId"], "A variable standing for the host is the authority")
        XCTAssertEqual(RequestPathVariables.names(in: "localhost:8080/:a/:a/:b"), ["a", "b"], "Each name once, in first-use order")
        XCTAssertEqual(RequestPathVariables.names(in: "https://x/v1/things:batchGet/:"), [], "Neither a colon inside a segment nor a bare one")
        XCTAssertEqual(RequestPathVariables.names(in: "https://x/a?b=/:c#/:d"), [], "The query and fragment aren't the path")
        XCTAssertEqual(RequestPathVariables.names(in: "https://x/:file.json/:{{bad}}"), ["file.json"])
        XCTAssertEqual(RequestPathVariables.names(in: "https://host:8080"), [])
    }

    func testSubstitutingKeepsTheSegmentsWithoutAValue() {
        let url = RequestPathVariables.substituting(in: "{{base}}/users/:id/posts/:post") { $0 == "id" ? "42" : nil }

        XCTAssertEqual(url, "{{base}}/users/42/posts/:post")
    }

    func testAValueIsEncodedAsOneSegment() {
        XCTAssertEqual(RequestPathVariables.encoded("a/b?c#d e"), "a%2Fb%3Fc%23d%20e")
        XCTAssertEqual(RequestPathVariables.encoded("100%25 sure%"), "100%25%20sure%25", "A typed escape is kept and a stray % escaped")
        XCTAssertEqual(RequestPathVariables.encoded("user@host:1;v=2"), "user@host:1;v=2")
        XCTAssertEqual(RequestPathVariables.encoded("café"), "caf%C3%A9")
    }

    func testNormalizingGivesEachNameARowAndIsStable() {
        let spec = HTTPRequestSpec(url: "https://x/users/:id/posts/:post?sort=new")

        let normalized = spec.normalized()

        XCTAssertEqual(normalized.url, "https://x/users/:id/posts/:post")
        XCTAssertEqual(normalized.pathVariables.map(\.key), ["id", "post"])
        XCTAssertEqual(normalized.pathVariables.map(\.value), ["", ""])
        XCTAssertEqual(normalized.normalized(), normalized)
        XCTAssertEqual(spec.normalized(), normalized, "New rows' IDs derive from the URL, so two reads agree")
    }

    func testTypingInTheBarKeepsValuesAndRenamesInPlace() throws {
        var spec = HTTPRequestSpec(url: "https://x/users/:id").normalized()
        spec.pathVariables[0].value = "42"
        let id = try XCTUnwrap(spec.pathVariables.first?.id)

        spec.applyDisplayURL("https://x/users/:id/posts/:post")
        XCTAssertEqual(spec.pathVariables.map(\.key), ["id", "post"])
        XCTAssertEqual(spec.pathVariables.first?.value, "42", "A name the URL still uses keeps its value")

        spec.applyDisplayURL("https://x/users/:userId/posts/:post")
        XCTAssertEqual(spec.pathVariables.map(\.key), ["userId", "post"])
        XCTAssertEqual(spec.pathVariables.first?.value, "42", "Renaming a segment keeps its value")
        XCTAssertEqual(spec.pathVariables.first?.id, id)

        spec.pathVariables[1].value = "9"
        spec.applyDisplayURL("https://x/teams/:team/members/:member")
        XCTAssertEqual(spec.pathVariables.map { "\($0.key)=\($0.value)" }, ["team=42", "member=9"], "Renames pair in order")

        spec.applyDisplayURL("https://x/users/:userId")
        XCTAssertEqual(spec.pathVariables.map(\.key), ["userId"])

        spec.applyDisplayURL("https://x/users")
        XCTAssertEqual(spec.pathVariables, [])
    }

    func testRowsGivenForNamesTheURLDoesntUseAreDropped() {
        let spec = HTTPRequestSpec(
            url: "https://x/:id",
            pathVariables: [
                KeyValuePair(key: "id", value: "1", isEnabled: false),
                KeyValuePair(key: "id", value: "2"),
                KeyValuePair(key: "extra", value: "3")
            ]
        )

        let normalized = spec.normalized()

        XCTAssertEqual(normalized.pathVariables.map(\.key), ["id"])
        XCTAssertEqual(normalized.pathVariables.first?.value, "1", "The first row of a name wins, as the builder reads it")
        XCTAssertEqual(normalized.pathVariables.first?.isEnabled, true, "A segment can't be left out of a path")
    }

    func testAPathVariableIsStoredOnlyWhenThereIsOne() throws {
        let encoder = JSONEncoder()
        let plain = try XCTUnwrap(String(data: try encoder.encode(HTTPRequestSpec(url: "https://x/users")), encoding: .utf8))
        let spec = HTTPRequestSpec(url: "https://x/:id", pathVariables: [KeyValuePair(key: "id", value: "42")])

        let decoded = try JSONDecoder().decode(HTTPRequestSpec.self, from: try encoder.encode(spec))

        XCTAssertFalse(plain.contains("pathVariables"))
        XCTAssertEqual(decoded, spec)
    }

    func testWebSocketsCarryThemThroughTheHandshakeAndConversion() throws {
        let webSocket = WebSocketRequestSpec(url: "wss://x/rooms/:room", pathVariables: [KeyValuePair(key: "room", value: "lobby")])

        let http = try XCTUnwrap(RequestKind.webSocket(webSocket).converted(to: .http).httpSpec)

        XCTAssertEqual(webSocket.handshake.pathVariables, webSocket.pathVariables)
        XCTAssertEqual(http.url, "https://x/rooms/:room")
        XCTAssertEqual(http.pathVariables, webSocket.pathVariables)
        XCTAssertFalse(RequestKind.webSocket(webSocket).losesContent(convertingTo: .http))
    }
}
