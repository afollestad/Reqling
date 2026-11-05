import Foundation
import GRPCReflectionService
@testable import ReqlingKit
import XCTest

extension GRPCRunnerTests {
    /// The editor's flow: the call opens with the spec's message, more are sent while it runs, then the stream ends.
    func testLiveMessagesGoOutOnAnOpenBidirectionalCall() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Bidi", messages: [#"{"text": "first"}"#]), server: server, variables: [
            Variable(key: "word", value: "live")
        ])
        let runner = makeRunner()
        let key = RunKey(request, in: project)

        let running = Task { await runner.run(request, in: project, options: RunOptions(keepsStreamOpen: true)) }
        await waitUntil("first echo") { (try? self.texts(runner.latest[key]?.grpc ?? .empty, .received)) == ["first"] }
        XCTAssertTrue(runner.openStreams.contains(key))
        XCTAssertNil(runner.latest[key]?.grpc?.status, "A partial record has no status yet")

        try runner.sendMessage(#"{"text": "{{word}}"}"#, to: request, in: project)
        await waitUntil("live echo") { (try? self.texts(runner.latest[key]?.grpc ?? .empty, .received)) == ["first", "live"] }
        XCTAssertThrowsError(try runner.sendMessage(#"{"text": 1}"#, to: request, in: project)) { error in
            XCTAssertEqual((error as? RunFailure)?.kind, .invalidRequest)
        }
        runner.endStream(request, in: project)
        let exchange = await running.value

        let call = try XCTUnwrap(exchange.grpc)
        XCTAssertEqual(call.status?.isOK, true)
        XCTAssertEqual(try texts(call, .sent), ["first", "live"])
        XCTAssertEqual(call.events.map(\.direction), [.sent, .received, .sent, .received])
        XCTAssertFalse(runner.openStreams.contains(key))
        XCTAssertThrowsError(try runner.sendMessage("{}", to: request, in: project), "The call has ended")
    }

    func testForgettingAProjectCancelsItsOpenStream() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Bidi"), server: server)
        let runner = makeRunner()
        let key = RunKey(request, in: project)

        let running = Task { await runner.run(request, in: project, options: RunOptions(keepsStreamOpen: true)) }
        await waitUntil("open") { runner.latest[key]?.grpc?.events.contains { $0.direction == .received } == true }
        try fixture.library.deleteProject(project)
        runner.forget(project)
        let exchange = await running.value

        XCTAssertEqual(exchange.grpc?.status?.name, "CANCELLED", "The caller still gets the timeline: \(exchange.outcome)")
        XCTAssertFalse(runner.openStreams.contains(key))
        XCTAssertFalse(runner.isInFlight(request, in: project))
        XCTAssertNil(runner.exchange(for: request, in: project))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.file("Support/History/\(project)").path))
    }

    /// Someone watching a stream keeps its timeline when they stop it.
    func testCancellingAnEstablishedCallKeepsItsRecord() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Bidi", messages: [#"{"text": "first"}"#]), server: server)
        let runner = makeRunner()
        let key = RunKey(request, in: project)

        let running = Task { await runner.run(request, in: project, options: RunOptions(keepsStreamOpen: true)) }
        await waitUntil("first echo") { (try? self.texts(runner.latest[key]?.grpc ?? .empty, .received)) == ["first"] }
        runner.cancel(request, in: project)
        let exchange = await running.value

        let call = try XCTUnwrap(exchange.grpc, "\(exchange.outcome)")
        XCTAssertEqual(call.status, GRPCStatusRecord(code: 1, name: "CANCELLED", message: "Cancelled"))
        XCTAssertEqual(try texts(call, .sent), ["first"])
        XCTAssertEqual(try texts(call, .received), ["first"])
        XCTAssertTrue(call.initialMetadata.contains(key: "x-initial", value: "hello"))
        XCTAssertFalse(runner.openStreams.contains(key))
        runner.flushHistory()
        XCTAssertEqual(makeRunner().exchange(for: request, in: project)?.grpc, call, "Cached like any finished call")
        XCTAssertEqual(runner.outcome(for: request, in: project), .failed)
    }

    /// A server that accepts the connection but never speaks HTTP/2, so a call can never be established.
    func testCancellingBeforeTheCallIsEstablishedIsAFailure() async throws {
        let silent = try await SilentServer.start()
        addTeardownBlock { await silent.stop() }
        let server = try await start()
        let runner = makeRunner()
        for method in ["Unary", "Bidi"] {
            let (project, request) = try makeProject(echoSpec(method), server: server)
            try fixture.library.mutate(project) { $0.defaultEnvironment.variables = [Variable(key: "target", value: silent.target.description)] }

            // Through `cancel`, once the run is in flight.
            let running = Task { await runner.run(request, in: project, options: RunOptions(keepsStreamOpen: true)) }
            await waitUntil("in flight") { runner.isInFlight(request, in: project) }
            runner.cancel(request, in: project)
            let viaRunner = await bounded("\(method) cancel", running)
            XCTAssertEqual(viaRunner?.failure?.kind, .cancelled, "\(method): \(String(describing: viaRunner?.outcome))")
            XCTAssertNil(viaRunner?.grpc)

            // Through the awaiting task, before the run has even started.
            let cancelledEarly = Task { await runner.run(request, in: project) }
            cancelledEarly.cancel()
            let viaTask = await bounded("\(method) task cancel", cancelledEarly)
            XCTAssertEqual(viaTask?.failure?.kind, .cancelled, "\(method): \(String(describing: viaTask?.outcome))")
        }
    }

    func testSchemaFromReflection() async throws {
        let server = try await start([try ReflectionService(descriptorSetFileURLs: [try ProtocFixtures.codecDescriptorSet])])
        let schemas = makeSchemas()
        let runner = makeRunner(schemas: schemas)
        var projects: [ProjectID] = []
        // `.automatic` reflects when the project has no protos.
        for source in [GRPCSchemaSource.reflection, .automatic] {
            let (project, request) = try makeProject(echoSpec("Unary", schema: source), server: server)
            projects.append(project)

            let schema = try await runner.grpcSchema(for: request, in: project)
            let exchange = await runner.run(request, in: project)

            XCTAssertEqual(schema.source, .reflection)
            XCTAssertEqual(schema.registry.services.map(\.fullName), [EchoService.name])
            XCTAssertEqual(exchange.grpc?.status?.isOK, true, "\(exchange.outcome)")
        }
        let revision = schemas.revision
        for project in projects {
            schemas.refreshReflection(in: project)
        }
        XCTAssertGreaterThan(schemas.revision, revision)
    }

    /// The fixture's `reqling/test/v1` tree compiled by the real protoc, as a project's proto root.
    func testSchemaFromProjectProtos() async throws {
        let protoc = try await ProtocFixtures.requireProtoc()
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("ServerStream", schema: .automatic), server: server)
        let protos = fixture.projectURL(project).appendingPathComponent("protos", isDirectory: true)
        try FileManager.default.createDirectory(at: protos, withIntermediateDirectories: true)
        let fixtureRoot = try ProtocFixtures.codecDescriptorSet.deletingLastPathComponent().appendingPathComponent("Protos/reqling")
        try FileManager.default.copyItem(at: fixtureRoot, to: protos.appendingPathComponent("reqling"))
        try fixture.library.mutate(project) { $0.grpc = ProjectGRPCConfiguration(protoRoots: [.relative("protos")]) }
        let runner = makeRunner(schemas: makeSchemas(protoc: protoc))

        let schema = try await runner.grpcSchema(for: request, in: project)
        let exchange = await runner.run(request, in: project)

        XCTAssertEqual(schema.source, .projectProtos)
        XCTAssertNil(schema.issue)
        XCTAssertEqual(exchange.grpc?.status?.isOK, true, "\(exchange.outcome)")
        XCTAssertEqual(try texts(try XCTUnwrap(exchange.grpc), .received), ["hi", "hi", "hi"])
    }

    func testProjectProtosWithoutProtocExplainThemselves() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Unary", schema: .projectProtos), server: server)
        try FileManager.default.createDirectory(
            at: fixture.projectURL(project).appendingPathComponent("protos", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fixture.library.mutate(project) { $0.grpc = ProjectGRPCConfiguration(protoRoots: [.relative("protos")]) }

        let exchange = await makeRunner().run(request, in: project)

        XCTAssertEqual(exchange.failure?.kind, .invalidRequest)
        XCTAssertTrue(exchange.failure?.message.contains("needs protoc") == true, "\(exchange.outcome)")
    }
}

extension GRPCCallRecord {
    static let empty = GRPCCallRecord(target: "", method: "", kind: .unary)
}
