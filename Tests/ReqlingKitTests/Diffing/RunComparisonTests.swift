import Foundation
import ReqlingKit
import XCTest

final class RunComparisonTests: XCTestCase {
    /// JSON is compared re-indented and headers sorted, so only real changes show.
    func testHTTPRunsCompareByContentNotLayout() throws {
        let older = exchange(body: #"{"id":1,"name":"Ada"}"#, headers: [("X-B", "2"), ("Content-Type", "application/json")])
        let newer = exchange(body: "{\n  \"id\": 1,\n  \"name\": \"Grace\"\n}", headers: [("Content-Type", "application/json"), ("X-B", "2")])

        let comparison = try RunComparer.compare(older, newer)

        XCTAssertEqual(comparison.sections.map(\.title), ["Body", "Headers", "Request"])
        XCTAssertEqual(comparison.sections.map(\.hasChanges), [true, false, false])
        guard case .diff(let body) = comparison.sections[0].content else {
            return XCTFail("a text body diffs")
        }
        XCTAssertEqual([body.addedCount, body.removedCount], [1, 1])
    }

    func testBinaryBodiesSayOnlyWhetherTheyMatch() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0xFF, 0xFE])
        let comparison = try RunComparer.compare(
            exchange(body: png, contentType: "image/png"),
            exchange(body: png + Data([0x00]), contentType: "image/png")
        )

        guard case .binary(let identical) = comparison.sections[0].content else {
            return XCTFail("an image body compares as bytes")
        }
        XCTAssertFalse(identical)
    }

    func testGRPCCallsCompareMessagesMetadataAndTheCall() throws {
        let request = GRPCMessageEvent(direction: .sent, offset: 0, json: #"{"text":"hi"}"#, byteCount: 4, sequence: 0)
        func call(reply: String, status: GRPCStatusRecord) -> RequestExchange {
            let reply = GRPCMessageEvent(direction: .received, offset: 0.1, json: reply, byteCount: 4, sequence: 1)
            let record = GRPCCallRecord(target: "localhost:1", method: "chat.Echo/Say", kind: .unary, events: [request, reply], status: status)
            return RequestExchange(
                projectID: ProjectID(), requestID: RequestNodeID(), startedAt: Date(), environmentName: nil, request: nil, outcome: .grpc(record)
            )
        }

        let comparison = try RunComparer.compare(
            call(reply: #"{"text":"hi"}"#, status: GRPCStatusRecord(code: 0, name: "OK", message: "")),
            call(reply: #"{"text":"hi"}"#, status: GRPCStatusRecord(code: 14, name: "UNAVAILABLE", message: "down"))
        )

        XCTAssertEqual(comparison.sections.map(\.title), ["Messages", "Metadata", "Request"])
        XCTAssertEqual(comparison.sections.map(\.hasChanges), [false, true, false])
    }

    private func exchange(body: String, headers: [(String, String)]) -> RequestExchange {
        exchange(body: Data(body.utf8), headers: headers.map { KeyValuePair(key: $0.0, value: $0.1) })
    }

    private func exchange(body: Data, contentType: String) -> RequestExchange {
        exchange(body: body, headers: [KeyValuePair(key: "Content-Type", value: contentType)])
    }

    private func exchange(body: Data, headers: [KeyValuePair]) -> RequestExchange {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let response = HTTPResponseRecord(
            statusCode: 200, headers: headers, body: body, url: "https://example.test", startedAt: startedAt, duration: 0.1
        )
        let sent = ResolvedHTTPRequest(method: "GET", url: "https://example.test", headers: [], bodyPreview: nil, bodyByteCount: 0)
        return RequestExchange(
            projectID: ProjectID(),
            requestID: RequestNodeID(),
            startedAt: startedAt,
            environmentName: nil,
            request: sent,
            outcome: .response(response)
        )
    }
}
