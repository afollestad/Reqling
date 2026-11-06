import Foundation
import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// The WebSocket request editor, its composer on an open connection, and the connection's timeline and handshake.
extension SnapshotTests {
    private static let socketEditorSize = CGSize(width: 920, height: 520)
    private static let socketResponseSize = CGSize(width: 820, height: 420)

    func testWebSocketEditorSavedMessages() throws {
        let editor = try socketEditor(Self.chatSpec())

        assertBothAppearances(WebSocketEditorPane(editor: editor, model: fixture.model), size: Self.socketEditorSize)
    }

    /// An open connection: Disconnect in the URL bar, and the composer above the saved messages, each with Send.
    func testWebSocketEditorOpenConnection() async throws {
        let server = try WebSocketLoopbackServer()
        defer { server.shutdown() }
        var spec = Self.chatSpec()
        spec.messages = spec.messages.map { message in
            var message = message
            message.sendsOnConnect = false
            return message
        }
        let editor = try socketEditor(spec, socketHost: "ws://127.0.0.1:\(server.port)")
        editor.send()
        await waitUntilObserved("the connection to open") { editor.isOpen }
        editor.liveMessage.text = "{\n  \"type\": \"typing\",\n  \"room\": \"lobby\"\n}"

        assertBothAppearances(WebSocketEditorPane(editor: editor, model: fixture.model), size: Self.socketEditorSize)

        editor.cancel()
        await waitUntilObserved("the connection to close") { !editor.isSending }
    }

    /// The seconds fields: Timeout empty on its default, Keepalive set, each with its arrows and unit.
    func testWebSocketEditorOptions() throws {
        var spec = Self.chatSpec()
        spec.options.keepaliveSeconds = 30
        let editor = try socketEditor(spec)
        editor.tab = .options

        assertBothAppearances(WebSocketEditorPane(editor: editor, model: fixture.model), size: CGSize(width: 920, height: 400))
    }

    func testWebSocketResponseTimelineTree() throws {
        let response = try socketResponse(Self.chatRecord())

        assertBothAppearances(WebSocketResponseView(response: response, model: fixture.model), size: Self.socketResponseSize)
    }

    func testWebSocketResponseTimelineText() throws {
        let response = try socketResponse(Self.chatRecord())
        response.messagesMode = .text

        assertBothAppearances(WebSocketResponseView(response: response, model: fixture.model), size: Self.socketResponseSize)
    }

    /// A refused handshake: the server's status in the status bar, its headers, and the body that says why.
    func testWebSocketResponseRefusedHandshake() throws {
        var record = WebSocketRecord(url: "wss://chat.example.com/socket", end: .refused(
            message: "The server answered 401 Unauthorized instead of switching protocols."
        ))
        record.handshake = HTTPResponseRecord(
            statusCode: 401,
            headers: [KeyValuePair(key: "Content-Type", value: "application/json"), KeyValuePair(key: "WWW-Authenticate", value: "Bearer")],
            body: Data("{\n  \"error\": \"token_expired\",\n  \"message\": \"Sign in again.\"\n}".utf8),
            url: "wss://chat.example.com/socket",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 0.084
        )
        record.duration = 0.084
        let response = try socketResponse(record)
        response.tab = .handshake

        assertBothAppearances(WebSocketResponseView(response: response, model: fixture.model), size: CGSize(width: 820, height: 340))
    }

    func testSidebarWithWebSocketRequests() throws {
        let project = try SnapshotProject.make(in: fixture)
        try fixture.library.mutate(project.id) { document in
            try document.insert(.request(RequestItem(name: "Chat", kind: .webSocket(Self.chatSpec()))), into: nil)
            let prices = RequestItem(name: "Prices", kind: .webSocket(WebSocketRequestSpec(url: "wss://prices.example.com")))
            try document.insert(.request(prices), into: nil)
        }

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 400))
    }

    // MARK: - Fixtures

    /// Selects a new WebSocket request in the snapshot project.
    private func socketEditor(_ spec: WebSocketRequestSpec, socketHost: String = "wss://chat.example.com") throws -> WebSocketEditorViewModel {
        let project = try SnapshotProject.make(in: fixture)
        let request = RequestItem(name: "Chat", kind: .webSocket(spec))
        try fixture.library.mutate(project.id) { document in
            document.defaultEnvironment.variables.append(Variable(key: "socketHost", value: socketHost))
            try document.insert(.request(request), into: nil)
        }
        fixture.model.selection = .node(project.id, request.id)
        return try XCTUnwrap(fixture.model.editor?.asWebSocket)
    }

    private func socketResponse(_ record: WebSocketRecord) throws -> WebSocketResponseViewModel {
        let project = try SnapshotProject.make(in: fixture)
        let request = RequestItem(name: "Chat", kind: .webSocket(Self.chatSpec()))
        try fixture.library.mutate(project.id) { try $0.insert(.request(request), into: nil) }
        project.cacheExchange(.webSocket(record), for: request.id, sent: ResolvedHTTPRequest(
            method: "GET",
            url: "wss://chat.example.com/socket",
            headers: [KeyValuePair(key: "Authorization", value: "Bearer ••••••")],
            bodyPreview: nil,
            bodyByteCount: 0
        ), in: fixture)
        fixture.model.selection = .node(project.id, request.id)
        return try XCTUnwrap(fixture.model.editor?.asWebSocket?.response)
    }

    private static func chatSpec() -> WebSocketRequestSpec {
        WebSocketRequestSpec(
            url: "{{socketHost}}/socket",
            subprotocols: ["chat"],
            messages: [
                WebSocketMessage(text: "{\n  \"type\": \"auth\",\n  \"token\": \"{{token}}\"\n}"),
                WebSocketMessage(text: "{\n  \"type\": \"join\",\n  \"room\": \"lobby\"\n}"),
                WebSocketMessage(format: .binary, text: "AAEC", sendsOnConnect: false)
            ],
            auth: .none
        )
    }

    private static func chatRecord() -> WebSocketRecord {
        func message(_ sequence: Int, _ offset: TimeInterval, _ direction: MessageDirection, _ text: String) -> WebSocketEntry {
            WebSocketEntry(
                sequence: sequence,
                offset: offset,
                kind: .message(WebSocketMessageRecord(direction: direction, format: .text, text: text)),
                byteCount: text.utf8.count
            )
        }
        var record = WebSocketRecord(
            url: "wss://chat.example.com/socket",
            subprotocol: "chat",
            entries: [
                message(0, 0.041, .sent, "{\n  \"type\": \"auth\",\n  \"token\": \"••••••\"\n}"),
                message(1, 0.052, .received, "{\n  \"type\": \"welcome\",\n  \"user\": \"ada\"\n}"),
                message(2, 0.053, .sent, "{\n  \"type\": \"join\",\n  \"room\": \"lobby\"\n}"),
                WebSocketEntry(sequence: 3, offset: 1.2, kind: .control(direction: .received, text: "Ping from the server, answered with a pong")),
                message(4, 2.5, .received, "{\n  \"type\": \"message\",\n  \"from\": \"grace\",\n  \"text\": \"Hello!\"\n}"),
                WebSocketEntry(sequence: 5, offset: 3.1, kind: .control(direction: .sent, text: "Close 1000 Normal Closure")),
                WebSocketEntry(sequence: 6, offset: 3.104, kind: .control(direction: .received, text: "Close 1000 Normal Closure"))
            ],
            close: WebSocketRecord.Close(code: 1000, byServer: false),
            end: .stopped,
            duration: 3.104
        )
        record.handshake = HTTPResponseRecord(
            statusCode: 101,
            headers: [KeyValuePair(key: "Upgrade", value: "websocket"), KeyValuePair(key: "Sec-WebSocket-Protocol", value: "chat")],
            body: Data(),
            url: "wss://chat.example.com/socket",
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            duration: 0.04,
            tlsVersion: "TLS 1.3"
        )
        return record
    }
}
