import Foundation
import ReqlingKit
import SwiftUI
import XCTest

@testable import Reqling

/// The gRPC request editor and response, against the greeter descriptor set in `GRPCFixtures`.
extension SnapshotTests {
    private static let grpcEditorSize = CGSize(width: 920, height: 440)
    private static let grpcResponseSize = CGSize(width: 820, height: 400)

    func testGRPCEditorUnary() async throws {
        let editor = try await grpcEditor(GRPCFixtures.descriptorSetSpec(target: "{{grpcHost}}"))
        editor.select(try XCTUnwrap(editor.schema.method(service: GRPCFixtures.service, name: "SayHello")))

        assertBothAppearances(GRPCEditorPane(editor: editor, model: fixture.model), size: Self.grpcEditorSize)
    }

    func testGRPCEditorBidirectionalMessages() async throws {
        var spec = GRPCFixtures.descriptorSetSpec(method: "Chat", messages: [
            "{\n  \"name\": \"{{name}}\"\n}",
            "{\n  \"name\": \"Grace\",\n  \"mood\": \"MOOD_CHEERFUL\"\n}"
        ], target: "greeter.example.com:443")
        spec.security = .tls
        let editor = try await grpcEditor(spec)

        assertBothAppearances(GRPCEditorPane(editor: editor, model: fixture.model), size: CGSize(width: 920, height: 520))
    }

    /// A bidirectional call held open by a server that never answers: Cancel in the target bar, and the composer for
    /// more messages above the saved ones.
    func testGRPCEditorOpenStream() async throws {
        let listener = try SilentLoopbackListener()
        let spec = GRPCFixtures.descriptorSetSpec(method: "Chat", messages: [#"{ "name": "Ada" }"#], target: "{{grpcHost}}")
        let editor = try await grpcEditor(spec, grpcHost: listener.target)
        editor.send()
        await waitUntilObserved("the stream to open") { editor.isStreamOpen }
        editor.liveMessage = "{\n  \"name\": \"Katherine\"\n}"

        assertBothAppearances(GRPCEditorPane(editor: editor, model: fixture.model), size: CGSize(width: 920, height: 520))

        editor.cancel()
    }

    func testGRPCResponseBidirectionalTimeline() async throws {
        let response = try await grpcResponse(Self.chatRecord(status: GRPCStatusRecord(code: 0, name: "OK", message: "")))

        assertBothAppearances(GRPCResponseView(response: response), size: Self.grpcResponseSize)
    }

    /// Text mode keeps each message's JSON as highlighted text under its header.
    func testGRPCResponseTextTimeline() async throws {
        let response = try await grpcResponse(Self.chatRecord(status: GRPCStatusRecord(code: 0, name: "OK", message: "")))
        response.messagesMode = .text

        assertBothAppearances(GRPCResponseView(response: response), size: Self.grpcResponseSize)
    }

    /// An open call: Streaming… in place of a status, and its messages so far.
    func testGRPCResponseStreaming() async throws {
        var record = Self.chatRecord(status: nil, eventCount: 2)
        record.trailers = []
        let response = try await grpcResponse(record)

        assertBothAppearances(GRPCResponseView(response: response), size: Self.grpcResponseSize)
    }

    func testGRPCResponseMetadata() async throws {
        let response = try await grpcResponse(Self.chatRecord(status: GRPCStatusRecord(code: 5, name: "NOT_FOUND", message: "No such greeter.")))
        response.tab = .metadata

        assertBothAppearances(GRPCResponseView(response: response), size: CGSize(width: 820, height: 300))
    }

    func testSidebarWithGRPCRequests() throws {
        let project = try SnapshotProject.make(in: fixture)
        _ = try GRPCFixtures.addRequest(named: "Say hello", spec: GRPCFixtures.descriptorSetSpec(method: "SayHello"), to: project.id, in: fixture)
        _ = try GRPCFixtures.addRequest(named: "Chat", spec: GRPCFixtures.descriptorSetSpec(method: "Chat"), to: project.id, in: fixture)

        assertBothAppearances(SidebarView(model: fixture.model), size: CGSize(width: 280, height: 400))
    }

    // MARK: - Fixtures

    /// Selects a new gRPC request in the snapshot project and waits for its schema, so the pickers and status are
    /// settled.
    private func grpcEditor(_ spec: GRPCRequestSpec, grpcHost: String = "localhost:50051") async throws -> GRPCEditorViewModel {
        let project = try SnapshotProject.make(in: fixture)
        try fixture.library.mutate(project.id) { document in
            document.defaultEnvironment.variables.append(Variable(key: "grpcHost", value: grpcHost))
        }
        let request = try GRPCFixtures.addRequest(named: "Greeter", spec: spec, to: project.id, in: fixture)
        fixture.model.selection = .node(project.id, request)
        let editor = try XCTUnwrap(fixture.model.editor?.asGRPC)
        await waitUntil("the schema to load") {
            if case .ready = editor.schema.status {
                return true
            }
            return false
        }
        return editor
    }

    private func grpcResponse(_ record: GRPCCallRecord) async throws -> GRPCResponseViewModel {
        let project = try SnapshotProject.make(in: fixture)
        let request = try GRPCFixtures.addRequest(named: "Chat", spec: GRPCFixtures.descriptorSetSpec(method: "Chat"), to: project.id, in: fixture)
        project.cacheExchange(.grpc(record), for: request, in: fixture)
        fixture.model.selection = .node(project.id, request)
        return try XCTUnwrap(fixture.model.editor?.asGRPC?.response)
    }

    private static func chatRecord(status: GRPCStatusRecord?, eventCount: Int = 4) -> GRPCCallRecord {
        let events = [
            GRPCMessageEvent(direction: .sent, offset: 0.004, json: "{\n  \"name\": \"Ada\"\n}", byteCount: 5, sequence: 0),
            GRPCMessageEvent(
                direction: .received,
                offset: 0.018,
                json: "{\n  \"message\": \"Hello, Ada\",\n  \"count\": 1\n}",
                byteCount: 18,
                sequence: 1,
                unknownFieldCount: 2
            ),
            GRPCMessageEvent(
                direction: .sent, offset: 0.021, json: "{\n  \"name\": \"Grace\",\n  \"mood\": \"MOOD_CHEERFUL\"\n}", byteCount: 9, sequence: 2
            ),
            GRPCMessageEvent(
                direction: .received, offset: 0.033, json: "{\n  \"message\": \"Hello, Grace!\",\n  \"count\": 2\n}", byteCount: 17, sequence: 3
            )
        ]
        return GRPCCallRecord(
            target: "greeter.example.com:443",
            method: "\(GRPCFixtures.service)/Chat",
            kind: .bidirectionalStreaming,
            sentMetadata: [KeyValuePair(key: "authorization", value: "Bearer ••••••••"), KeyValuePair(key: "x-trace", value: "7f3c")],
            initialMetadata: [KeyValuePair(key: "content-type", value: "application/grpc"), KeyValuePair(key: "server", value: "greeter/1.4")],
            trailers: [KeyValuePair(key: "grpc-status", value: "\(status?.code ?? 0)")],
            events: Array(events.prefix(eventCount)),
            status: status,
            duration: 0.041
        )
    }
}
