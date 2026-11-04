import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class GRPCEditorViewModelTests: XCTestCase {
    private var fixture: AppFixture!
    private var gate: SleepGate!
    private var project: ProjectID!
    private var request: RequestNodeID!

    override func setUp() async throws {
        let gate = SleepGate()
        self.gate = gate
        fixture = AppFixture(sleep: { _ in await gate.sleep() })
        fixture.model.createProject(named: "gRPC")
        project = try XCTUnwrap(fixture.model.selection?.projectID)
        request = try GRPCFixtures.addRequest(to: project, in: fixture)
        fixture.model.selection = .node(project, request)
    }

    override func tearDown() async throws {
        // Not awaited: a call cancelled while its connection waits on a silent server can take a while to wind down,
        // and it publishes nothing once its project is gone.
        fixture.model.editor?.cancel()
        gate.releaseAll()
        fixture.tearDown()
        fixture = nil
    }

    private var editor: GRPCEditorViewModel {
        fixture.model.editor!.asGRPC!
    }

    private var savedSpec: GRPCRequestSpec? {
        fixture.library.document(project)?.request(request)?.kind.grpcSpec
    }

    private func changeExternally(_ change: (inout GRPCRequestSpec) -> Void) throws {
        var spec = try XCTUnwrap(savedSpec)
        change(&spec)
        let request = request!
        try fixture.library.mutate(project) { [spec] in try $0.updateRequest(request) { $0.kind = .grpc(spec) } }
        fixture.model.libraryDidChange()
    }

    private func releaseAutosave() async {
        await waitUntil("the autosave to start waiting") { gate.pendingCount > 0 }
        gate.releaseAll()
    }

    private func waitForSchema(file: StaticString = #filePath, line: UInt = #line) async {
        await waitUntil("the schema to load", file: file, line: line) {
            if case .ready = editor.schema.status {
                return true
            }
            return false
        }
    }

    private func method(_ name: String) throws -> GRPCMethodDescriptor {
        try XCTUnwrap(editor.schema.method(service: GRPCFixtures.service, name: name))
    }

    // MARK: - Drafts

    func testEditsAutosaveOnlyAfterThePause() async throws {
        editor.spec.metadata = [KeyValuePair(key: "x-trace", value: "{{$uuid}}")]

        XCTAssertEqual(savedSpec?.metadata, [])
        await releaseAutosave()
        await waitUntil("the autosave") { savedSpec?.metadata.count == 1 }
    }

    func testExternalChangesAreAdoptedOnlyWhileTheDraftIsClean() throws {
        try changeExternally { $0.target = "external:443" }
        XCTAssertEqual(editor.spec.target, "external:443")

        editor.spec.deadlineSeconds = 5
        try changeExternally { $0.target = "external-2:443" }
        XCTAssertEqual(editor.spec.target, "external:443")
    }

    /// The service and method merge as one pair, so a merge never pairs a stored service with the draft's method.
    func testAnExternalChangeDuringThePauseIsMergedPerField() async throws {
        editor.spec.messages = [#"{"name": "local"}"#]
        try changeExternally { spec in
            spec.service = GRPCFixtures.service
            spec.method = "Chat"
            spec.deadlineSeconds = 9
        }
        XCTAssertEqual(editor.spec.method, "")

        await releaseAutosave()
        await waitUntil("the merged save") { savedSpec?.messages == [#"{"name": "local"}"#] }

        XCTAssertEqual(savedSpec?.methodPath, "\(GRPCFixtures.service)/Chat")
        XCTAssertEqual(savedSpec?.deadlineSeconds, 9)
        XCTAssertEqual(editor.spec, savedSpec)
    }

    func testMetadataRemovedElsewhereDuringThePauseStaysRemovedWhileTheUsersEditWins() async throws {
        try changeExternally { $0.metadata = [KeyValuePair(key: "x-kept", value: "1"), KeyValuePair(key: "x-removed", value: "1")] }
        let kept = try XCTUnwrap(editor.spec.metadata.first)
        editor.spec.metadata[0].value = "mine"
        try changeExternally { spec in
            spec.metadata.removeLast()
            spec.metadata[0].value = "theirs"
            spec.metadata.append(KeyValuePair(key: "x-added", value: "1"))
        }

        await releaseAutosave()
        await waitUntil("the merged save") { savedSpec?.metadata.first?.value == "mine" }

        XCTAssertEqual(savedSpec?.metadata.map(\.key), ["x-kept", "x-added"])
        XCTAssertEqual(savedSpec?.metadata.first?.id, kept.id)
        XCTAssertEqual(editor.spec, savedSpec)
    }

    func testQuittingAsksBeforeLosingADraftStrandedByAnUnavailableProject() throws {
        editor.spec.target = "draft:50051"
        let projectFile = try XCTUnwrap(fixture.library.project(project)?.url.appendingPathComponent("project.json"))
        try FileManager.default.removeItem(at: projectFile)
        fixture.library.reload(project)
        fixture.model.libraryDidChange()

        XCTAssertTrue(editor.isReadOnly)
        XCTAssertNotNil(editor.unavailableNote)
        XCTAssertFalse(fixture.model.confirmTermination())
        XCTAssertEqual(fixture.system.quitConfirmations, 1)
        XCTAssertTrue(editor.hasStrandedChanges)
    }

    // MARK: - Schema

    /// Without a schema the kind is unknown, so two saved messages show as a list; once the schema loads, the unary
    /// method's descriptor decides, whatever the spec holds.
    func testTheCallKindComesFromTheSchemaNotTheSpec() async throws {
        try changeExternally { spec in
            spec.service = GRPCFixtures.service
            spec.method = "SayHello"
            spec.messages = ["{}", "{}"]
            spec.schema = .descriptorSet(.relative("missing.binpb"))
        }
        await releaseAutosave()
        await waitUntil("the schema to fail") {
            if case .failed = editor.schema.status {
                return true
            }
            return false
        }
        XCTAssertNil(editor.selectedMethod)
        XCTAssertTrue(editor.listsMessages)

        editor.setSchemaSource(.descriptorSet(.relative(GRPCFixtures.descriptorSetName)))
        await releaseAutosave()
        await waitForSchema()

        XCTAssertEqual(editor.schema.status, .ready(.descriptorSet, issue: nil))
        XCTAssertEqual(editor.selectedMethod?.kind, .unary)
        XCTAssertFalse(editor.listsMessages)
        editor.select(try method("Chat"))
        XCTAssertEqual(editor.selectedMethod?.kind, .bidirectionalStreaming)
        XCTAssertTrue(editor.listsMessages)
    }

    func testPickingAMethodFillsOnlyBlankMessagesWithItsExample() async throws {
        await waitForSchema()
        XCTAssertEqual(editor.schema.services.map(\.fullName), [GRPCFixtures.service])

        editor.select(try method("SayHello"))

        let example = try XCTUnwrap(editor.spec.messages.first)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(example.utf8)) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["name", "mood", "tags"])
        XCTAssertEqual(fields["mood"] as? String, "MOOD_UNSPECIFIED")

        editor.firstMessage = #"{"name": "Ada"}"#
        editor.select(try method("Chat"))
        XCTAssertEqual(editor.spec.messages, [#"{"name": "Ada"}"#], "picking a method must not overwrite a message")

        editor.fillExample(at: 0)
        XCTAssertEqual(editor.spec.messages, [example])
        editor.addMessage()
        XCTAssertEqual(editor.spec.messages, [example, example])
    }

    func testTheSchemaReloadsOnceASourceChangeSettles() async throws {
        await waitForSchema()

        editor.setSchemaSource(.descriptorSet(.relative("missing.binpb")))
        XCTAssertEqual(editor.schema.status, .ready(.descriptorSet, issue: nil), "the reload waits out the pause")
        await releaseAutosave()
        await waitUntil("the reload to fail") {
            if case .failed = editor.schema.status {
                return true
            }
            return false
        }
        XCTAssertTrue(editor.schema.services.isEmpty)

        editor.setSchemaSource(.reflection)
        editor.spec.target = ""
        await releaseAutosave()
        await waitUntil("the reflection prompt") {
            if case .idle = editor.schema.status {
                return true
            }
            return false
        }
    }

    // MARK: - Calls

    /// A bidirectional call to a server that never answers stays open, so its stream can take more messages and end.
    func testAnOpenStreamTakesLiveMessagesUntilItEnds() async throws {
        let listener = try SilentLoopbackListener()
        await waitForSchema()
        editor.spec.target = listener.target
        editor.select(try method("Chat"))
        XCTAssertFalse(editor.isStreamOpen)

        editor.send()
        await waitUntilObserved("the stream to open") { self.editor.isStreamOpen }
        XCTAssertTrue(editor.isSending)
        XCTAssertEqual(savedSpec?.target, listener.target, "Send saves the draft first")
        XCTAssertNotEqual(editor.liveMessage, "{}", "an open stream starts from the method's Example")

        editor.liveMessage = "{ not json"
        editor.sendLiveMessage()
        XCTAssertNotNil(editor.liveError)
        editor.liveMessage = #"{"name": "Ada"}"#
        editor.sendLiveMessage()
        XCTAssertNil(editor.liveError)

        editor.endStream()
        XCTAssertFalse(editor.isStreamOpen)
        editor.sendLiveMessage()
        XCTAssertNotNil(editor.liveError, "an ended stream takes no more messages")
    }

    /// ⌘Return and the menu's Send reach `send()`; on an open stream that must send the composer's message, since a
    /// new run would cancel the open call, and show it, since the composer may be on a hidden tab.
    func testSendOnAnOpenStreamSendsTheComposedMessageInsteadOfRestarting() async throws {
        let listener = try SilentLoopbackListener()
        await waitForSchema()
        editor.spec.target = listener.target
        editor.select(try method("Chat"))
        editor.send()
        await waitUntilObserved("the stream to open") { self.editor.isStreamOpen }
        let key = RunKey(request, in: project)
        let started = try XCTUnwrap(fixture.component.requestRunner.latest[key]?.startedAt)

        editor.liveMessage = "{ not json"
        editor.tab = .metadata
        fixture.model.editor?.send()
        XCTAssertNotNil(editor.liveError, "Send went to the open stream")
        XCTAssertEqual(editor.tab, .messages, "the composer and its error are shown")
        editor.liveMessage = #"{"name": "Grace"}"#
        fixture.model.editor?.send()
        XCTAssertNil(editor.liveError)

        XCTAssertTrue(editor.isStreamOpen)
        XCTAssertEqual(fixture.component.requestRunner.latest[key]?.startedAt, started, "the call was not restarted")
    }

    // MARK: - Through AppModel

    func testEachKindOfRequestOpensItsOwnEditor() throws {
        XCTAssertEqual(fixture.model.editor?.kind, .grpc)
        XCTAssertEqual(fixture.model.editor?.identity, .node(project, request))

        fixture.model.newRequest()
        XCTAssertEqual(fixture.model.editor?.kind, .http)
        XCTAssertNil(fixture.model.editor?.asGRPC)

        fixture.model.newGRPCRequest()
        let created = try XCTUnwrap(fixture.model.editor?.asGRPC)
        XCTAssertEqual(created.name, "New gRPC Request")
        XCTAssertEqual(created.spec.schema, .automatic)
    }

    func testSwitchingRequestsFlushesTheGRPCDraft() throws {
        editor.spec.target = "flushed:50051"

        fixture.model.selection = .project(project)

        XCTAssertEqual(savedSpec?.target, "flushed:50051")
        XCTAssertNil(fixture.model.editor)
    }

    /// An external edit that turns the request into an HTTP one gets an HTTP editor the next time it is selected.
    /// A `git pull` that turns the selected request into an HTTP one (or back) replaces its editor at once: the old
    /// one's draft can no longer save, so a dirty one is reported as discarded.
    func testAnExternalKindChangeReplacesTheEditorAndReportsADroppedDraft() throws {
        let request = request!
        editor.spec.target = "unsaved:50051"
        try fixture.library.mutate(project) { try $0.updateRequest(request) { $0.kind = .http(HTTPRequestSpec(url: "https://x")) } }

        fixture.model.libraryDidChange()

        XCTAssertEqual(fixture.model.editor?.asHTTP?.spec.url, "https://x")
        XCTAssertEqual(fixture.model.alert?.title, "Unsaved Changes Discarded")
        XCTAssertEqual(fixture.library.document(project)?.request(request)?.kind.httpSpec?.url, "https://x")

        fixture.model.alert = nil
        try fixture.library.mutate(project) { try $0.updateRequest(request) { $0.kind = .grpc(GRPCFixtures.descriptorSetSpec()) } }
        fixture.model.libraryDidChange()

        XCTAssertEqual(fixture.model.editor?.kind, .grpc)
        XCTAssertNil(fixture.model.alert, "a clean draft goes quietly")
    }

    func testRenamingFlushesAndShowsTheNewName() throws {
        editor.spec.target = "renamed:50051"

        fixture.model.rename(request, in: project, to: "Greeter")

        XCTAssertEqual(editor.name, "Greeter")
        XCTAssertEqual(savedSpec?.target, "renamed:50051")
    }
}
