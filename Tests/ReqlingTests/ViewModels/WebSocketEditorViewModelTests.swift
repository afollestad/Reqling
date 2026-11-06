import Foundation
import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

@MainActor
final class WebSocketEditorViewModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var gate: SleepGate!
    private var project: ProjectID!
    private var server: WebSocketLoopbackServer?

    override func setUp() async throws {
        let gate = SleepGate()
        self.gate = gate
        fixture = AppFixture(sleep: { _ in await gate.sleep() })
        fixture.model.createProject(named: "Sockets")
        project = fixture.model.selection?.projectID
        try fixture.library.mutate(project) { document in
            document.defaultEnvironment.variables = [Variable(key: "token", value: "s3cr3t", isSecret: true)]
        }
        fixture.model.newRequest()
        let request = try XCTUnwrap(fixture.model.editor?.identity.nodeID)
        fixture.model.changeKind(of: request, in: project, to: .webSocket)
    }

    override func tearDown() async throws {
        if fixture.model.editor?.isSending == true {
            editor.cancel()
            await waitUntilObserved("the connection to close") { !self.editor.isSending }
        }
        server?.shutdown()
        gate.releaseAll()
        fixture.tearDown()
        fixture = nil
    }

    private var editor: WebSocketEditorViewModel {
        fixture.model.editor!.asWebSocket!
    }

    private var savedSpec: WebSocketRequestSpec? {
        fixture.library.document(project)?.request(editor.requestID)?.kind.webSocketSpec
    }

    private func receivedTexts() -> [String] {
        editor.response.record?.entries.compactMap { $0.message?.direction == .received ? $0.message?.text : nil } ?? []
    }

    private func startServer() throws -> WebSocketLoopbackServer {
        let server = try WebSocketLoopbackServer()
        self.server = server
        return server
    }

    func testANewRequestSwitchesToWebSocketWithoutAsking() {
        XCTAssertNil(fixture.model.kindChangePending)
        XCTAssertEqual(fixture.model.editor?.kind, .webSocket)
        XCTAssertEqual(fixture.model.editor?.sendTitle, "Connect")
        XCTAssertEqual(fixture.model.editor?.cancelTitle, "Cancel")
    }

    func testASwitchThatDiscardsSaysWhatCarriesOver() throws {
        editor.spec.messages = [WebSocketMessage(text: "hi")]
        editor.flush()

        fixture.model.changeKind(of: editor.requestID, in: project, to: .http)

        let pending = try XCTUnwrap(fixture.model.kindChangePending)
        XCTAssertEqual(
            pending.consequences,
            "Its URL, query, auth, headers, and timeout carry over. Its subprotocols, messages, and run history are discarded."
        )
    }

    /// The on-connect message goes first, then ⌘Return sends the composer's, a saved one goes on request, and Ping
    /// gets its pong; Disconnect closes normally and keeps the timeline.
    func testAnOpenConnectionSendsSavedAndLiveMessagesAndDisconnects() async throws {
        let server = try startServer()
        editor.urlText = server.url
        editor.spec.messages = [WebSocketMessage(text: "first"), WebSocketMessage(text: "later {{token}}", sendsOnConnect: false)]

        editor.send()
        await waitUntilObserved("the connection opens") { self.editor.isOpen }
        XCTAssertEqual(fixture.model.editor?.sendTitle, "Send Message")
        XCTAssertEqual(fixture.model.editor?.cancelTitle, "Disconnect")
        editor.liveMessage.text = "live"
        editor.send()
        editor.sendSaved(editor.spec.messages[1])
        editor.ping()
        await waitUntilObserved("every echo arrives") { self.receivedTexts().count == 3 }
        XCTAssertNil(editor.liveError)
        editor.cancel()
        await waitUntilObserved("the connection closes") { !self.editor.isSending }

        let record = try XCTUnwrap(editor.response.record)
        XCTAssertEqual(receivedTexts(), ["first", "live", "later s3cr3t"])
        XCTAssertEqual(record.entries.compactMap { $0.message?.direction == .sent ? $0.message?.text : nil }, ["first", "live", "later ••••••"])
        XCTAssertTrue(record.entries.contains { if case .control(.received, let text) = $0.kind { text.hasPrefix("Pong 1") } else { false } })
        XCTAssertEqual(record.end, .stopped)
        XCTAssertEqual(record.close?.code, 1000)
    }

    func testASendThatCantResolveShowsWhy() async throws {
        let server = try startServer()
        editor.urlText = server.url
        editor.send()
        await waitUntilObserved("the connection opens") { self.editor.isOpen }

        editor.liveMessage = WebSocketMessage(format: .binary, text: "%%%")
        editor.sendLiveMessage()

        XCTAssertEqual(editor.liveError, "The message isn't valid base64, which a binary message is written in.")
        editor.liveMessage = WebSocketMessage(text: "fine")
        editor.sendLiveMessage()
        XCTAssertNil(editor.liveError, "The next send clears it")
    }

    func testSavingTheComposersMessageAddsItToTheRequest() {
        editor.liveMessage = WebSocketMessage(format: .binary, text: "AAE=")

        editor.saveLiveMessage()

        XCTAssertEqual(editor.spec.messages.map(\.text), ["AAE="])
        XCTAssertEqual(editor.spec.messages.first?.format, .binary)
        XCTAssertNotEqual(editor.spec.messages.first?.id, editor.liveMessage.id, "A saved copy, not the composer's own")
    }

    func testMessagesMoveUpAndDownAsOneEditEach() {
        editor.spec.messages = ["a", "b", "c"].map { WebSocketMessage(text: $0) }
        let rows = Binding(get: { self.editor.spec.messages }, set: { self.editor.spec.messages = $0 })

        IdentifiedRowWriter(rows: rows, shown: editor.spec.messages[0]).move(by: 1)
        XCTAssertEqual(editor.spec.messages.map(\.text), ["b", "a", "c"])
        IdentifiedRowWriter(rows: rows, shown: editor.spec.messages[2]).move(by: -1)
        XCTAssertEqual(editor.spec.messages.map(\.text), ["b", "c", "a"])
        IdentifiedRowWriter(rows: rows, shown: editor.spec.messages[0]).move(by: -1)
        XCTAssertEqual(editor.spec.messages.map(\.text), ["b", "c", "a"], "The first can't move up")
    }

    func testTheSubprotocolsFieldKeepsWhatWasTyped() {
        editor.subprotocolsText = "chat,"
        XCTAssertEqual(editor.subprotocolsText, "chat,", "A trailing comma survives until the next name")
        XCTAssertEqual(editor.spec.subprotocols, ["chat"])

        editor.subprotocolsText = "chat, superchat "
        XCTAssertEqual(editor.spec.subprotocols, ["chat", "superchat"])

        editor.spec.subprotocols = ["mqtt"]
        XCTAssertEqual(editor.subprotocolsText, "mqtt", "A change elsewhere rewrites the field")
    }

    /// A message an agent adds while the URL is being edited survives the save, merged by its ID.
    func testAMessageAddedElsewhereDuringThePauseIsMergedIntoTheSave() async throws {
        editor.urlText = "ws://local"
        let request = editor.requestID
        try fixture.library.mutate(project) { document in
            try document.updateRequest(request) { $0.kind = .webSocket(WebSocketRequestSpec(messages: [WebSocketMessage(text: "from an agent")])) }
        }
        fixture.model.libraryDidChange()

        await waitUntil("the autosave to start waiting") { self.gate.pendingCount > 0 }
        gate.releaseAll()
        await waitUntil("the merged save") { self.savedSpec?.url == "ws://local" }

        XCTAssertEqual(savedSpec?.messages.map(\.text), ["from an agent"])
        XCTAssertEqual(editor.spec, savedSpec)
    }

    func testOriginIsOffUntilTurnedOn() throws {
        editor.urlText = "wss://chat.example.com/socket"
        let origin = try XCTUnwrap(editor.autoHeaders.first { $0.key == "origin" })

        XCTAssertFalse(editor.spec.sends(origin))
        editor.toggleAutoHeader(origin, enabled: true)

        XCTAssertEqual(editor.spec.enabledAutoHeaders, ["origin"])
        XCTAssertEqual(editor.spec.handshake.headers.last.map { "\($0.key): \($0.value)" }, "Origin: https://chat.example.com")
    }
}
