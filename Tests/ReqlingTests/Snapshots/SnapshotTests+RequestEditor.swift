import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

extension SnapshotTests {
    private static let editorSize = CGSize(width: 920, height: 380)

    private func assertEditor(
        _ request: (SnapshotProject) -> RequestNodeID,
        tab: RequestEditorTab,
        spec: HTTPRequestSpec? = nil,
        testName: String = #function,
        line: UInt = #line
    ) throws {
        let project = try SnapshotProject.make(in: fixture)
        let editor = try project.editor(request(project), in: fixture, spec: spec)
        editor.tab = tab
        assertBothAppearances(RequestEditorPane(editor: editor, model: fixture.model), size: Self.editorSize, testName: testName, line: line)
    }

    /// The URL bar's pills: resolved (`baseUrl`, `page`), unresolved (`userId`), and dynamic (`$uuid`).
    func testEditorURLAndParams() throws {
        try assertEditor(\.listUsers, tab: .params)
    }

    func testEditorHeadersWithAutomaticHeaders() throws {
        try assertEditor(\.createUser, tab: .headers, spec: HTTPRequestSpec(
            method: .post,
            url: "{{baseUrl}}/users",
            headers: [KeyValuePair(key: "User-Agent", value: "custom/1.0"), KeyValuePair(key: "X-Trace", value: "{{$uuid}}")],
            disabledAutoHeaders: ["accept"],
            body: .raw("{}")
        ))
    }

    func testEditorRawJSONBody() throws {
        try assertEditor(\.createUser, tab: .body)
    }

    func testEditorRawXMLBody() throws {
        try assertEditor(\.createUser, tab: .body, spec: HTTPRequestSpec(
            method: .post,
            url: "{{baseUrl}}/users",
            body: .raw("<user id=\"7\">\n  <name>{{name}}</name>\n  <!-- note -->\n</user>", contentType: "application/xml")
        ))
    }

    func testEditorFormDataBody() throws {
        let body = HTTPBody(mode: .formData, formData: [
            MultipartField(key: "name", value: "{{name}}"),
            MultipartField(key: "avatar", kind: .file, file: .relative("avatar.png"), contentType: "image/png")
        ])
        try assertEditor(\.createUser, tab: .body, spec: HTTPRequestSpec(method: .post, url: "{{baseUrl}}/upload", body: body))
    }

    func testEditorURLEncodedBody() throws {
        let body = HTTPBody(mode: .urlEncoded, urlEncoded: [
            KeyValuePair(key: "username", value: "{{name}}"),
            KeyValuePair(key: "remember", value: "true", isEnabled: false)
        ])
        try assertEditor(\.createUser, tab: .body, spec: HTTPRequestSpec(method: .post, url: "{{baseUrl}}/login", body: body))
    }

    func testEditorBinaryBody() throws {
        try assertEditor(\.createUser, tab: .body, spec: HTTPRequestSpec(
            method: .put,
            url: "{{baseUrl}}/blob",
            body: HTTPBody(mode: .binary, binary: BinaryBody(file: .relative("payload.bin")))
        ))
    }

    func testEditorGraphQLBody() throws {
        let body = HTTPBody(mode: .graphQL, graphQL: GraphQLBody(
            query: "query User($id: ID!) {\n  user(id: $id) { name }\n}",
            variables: "{ \"id\": \"{{userId}}\" }",
            operationName: "User"
        ))
        try assertEditor(\.createUser, tab: .body, spec: HTTPRequestSpec(method: .post, url: "{{baseUrl}}/graphql", body: body))
    }

    /// The auth editor's label column keeps a credential type with fields on the same rows as one without.
    func testEditorBearerAuth() throws {
        try assertEditor(\.listUsers, tab: .auth, spec: HTTPRequestSpec(url: "{{baseUrl}}/me", auth: .bearer(token: "{{token}}")))
    }

    /// A GET keeps the body it had as a POST but explains it will not be sent.
    func testEditorBodyDisabledForGET() throws {
        try assertEditor(\.createUser, tab: .body, spec: HTTPRequestSpec(method: .get, url: "{{baseUrl}}/users", body: .raw("{}")))
    }
}
