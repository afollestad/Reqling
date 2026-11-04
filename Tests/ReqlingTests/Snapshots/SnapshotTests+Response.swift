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

    private func jsonResponseView() throws -> ResponseView {
        let project = try SnapshotProject.make(in: fixture)
        let body = #"{"users":[{"id":1,"name":"Ada","active":true},{"id":2,"name":"Grace","active":false}],"next":null}"#
        project.cacheExchange(.response(HTTPResponseRecord(
            statusCode: 200,
            headers: [KeyValuePair(key: "Content-Type", value: "application/json")],
            body: Data(body.utf8),
            url: "https://api.example.com/users",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 0.142,
            protocolName: "h2",
            tlsVersion: "TLS 1.3"
        )), for: project.listUsers, in: fixture)
        let editor = try project.editor(project.listUsers, in: fixture)
        return ResponseView(response: editor.response, model: fixture.model)
    }
}
