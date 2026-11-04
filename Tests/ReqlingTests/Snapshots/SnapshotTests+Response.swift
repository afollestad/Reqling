import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

extension SnapshotTests {
    private static let responseSize = CGSize(width: 820, height: 340)

    /// Wide enough that the format picker and the body actions share the tabs' row.
    func testResponseJSONBody() throws {
        let view = try jsonResponseView()
        assertBothAppearances(view, size: Self.responseSize)
    }

    /// The detail column at its minimum width: too narrow for one row, so the picker and the actions wrap under the tabs.
    func testResponseJSONBodyNarrow() throws {
        let view = try jsonResponseView()
        assertBothAppearances(view, size: CGSize(width: 520, height: 340))
    }

    /// The empty state centers in the pane rather than hugging its leading edge.
    func testResponseEmptyBody() throws {
        let project = try SnapshotProject.make(in: fixture)
        project.cacheExchange(.response(HTTPResponseRecord(
            statusCode: 204,
            headers: [],
            body: Data(),
            url: "https://api.example.com/users",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 0.042,
            protocolName: "h2",
            tlsVersion: "TLS 1.3"
        )), for: project.listUsers, in: fixture)
        let editor = try project.editor(project.listUsers, in: fixture)

        assertBothAppearances(ResponseView(response: editor.response, model: fixture.model), size: Self.responseSize)
    }

    func testResponseFailure() throws {
        let project = try SnapshotProject.make(in: fixture)
        project.cacheExchange(
            .failure(RunFailure(kind: .tls, message: "The certificate for api.example.com is not trusted.")),
            for: project.listUsers,
            in: fixture
        )
        let editor = try project.editor(project.listUsers, in: fixture)

        assertBothAppearances(ResponseView(response: editor.response, model: fixture.model), size: Self.responseSize)
    }

    /// The Raw format shows the body as sent, highlighted the same way.
    func testResponseRawBody() throws {
        let response = try jsonResponse()
        response.bodyMode = .raw
        assertBothAppearances(ResponseView(response: response, model: fixture.model), size: Self.responseSize)
    }

    /// Searching in place: the bar above the body, every match tinted, and the current one selected.
    func testResponseBodySearch() async throws {
        let response = try jsonResponse()
        guard case .text(let document) = response.body.content else {
            return XCTFail("\(response.body.content)")
        }
        response.search.present()
        response.search.query = "name"
        await response.search.search(in: document)
        assertBothAppearances(ResponseView(response: response, model: fixture.model), size: Self.responseSize)
    }

    /// The Request tab shows the body sent, highlighted by its Content-Type.
    func testResponseSentBody() throws {
        let response = try jsonResponse(sent: ResolvedHTTPRequest(
            method: "POST",
            url: "https://api.example.com/users",
            headers: [KeyValuePair(key: "Content-Type", value: "application/json")],
            bodyPreview: #"{"name": "Ada", "admin": false}"#,
            bodyByteCount: 31
        ))
        response.tab = .request
        assertBothAppearances(ResponseView(response: response, model: fixture.model), size: Self.responseSize)
    }

    private func jsonResponseView() throws -> ResponseView {
        ResponseView(response: try jsonResponse(), model: fixture.model)
    }

    private func jsonResponse(sent: ResolvedHTTPRequest? = nil) throws -> ResponseViewModel {
        let project = try SnapshotProject.make(in: fixture)
        let body = #"{"users":[{"id":1,"name":"Ada","active":true},{"id":2,"name":"Grace","active":false}],"next":null}"#
        let record = HTTPResponseRecord(
            statusCode: 200,
            headers: [KeyValuePair(key: "Content-Type", value: "application/json")],
            body: Data(body.utf8),
            url: "https://api.example.com/users",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 0.142,
            protocolName: "h2",
            tlsVersion: "TLS 1.3"
        )
        if let sent {
            project.cacheExchange(.response(record), for: project.listUsers, sent: sent, in: fixture)
        } else {
            project.cacheExchange(.response(record), for: project.listUsers, in: fixture)
        }
        return try project.editor(project.listUsers, in: fixture).response
    }
}
