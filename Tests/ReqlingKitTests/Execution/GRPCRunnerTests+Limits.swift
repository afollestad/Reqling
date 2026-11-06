import Foundation
@testable import ReqlingKit
import Synchronization
import SwiftProtobuf
import XCTest

/// What keeps a run bounded: deadlines, long streams, the history, and waits that must give way to cancellation.
extension GRPCRunnerTests {
    /// A non-finite deadline cannot be saved to a project file, so only the conversion sees one.
    func testAHugeOrNonFiniteRequestDeadlineIsClamped() async throws {
        let server = try await start()
        let runner = makeRunner()
        for seconds in [1e16, 1e300, -1, 0] {
            var spec = echoSpec("Unary")
            spec.deadlineSeconds = seconds
            let (project, request) = try makeProject(spec, server: server)

            let exchange = await runner.run(request, in: project)

            XCTAssertEqual(exchange.grpc?.status?.isOK, true, "\(seconds): \(exchange.outcome)")
        }
        XCTAssertEqual(GRPCRequestResolution.duration(1e16), .seconds(600))
        XCTAssertEqual(GRPCRequestResolution.duration(0.25), .milliseconds(250))
        XCTAssertNil(GRPCRequestResolution.duration(.nan))
        XCTAssertNil(GRPCRequestResolution.duration(.infinity))
    }

    /// Only a call the editor keeps open to send into goes without a deadline it did not ask for.
    func testOnlyInteractiveStreamingCallsGoWithoutTheDefaultDeadline() throws {
        let target = try GRPCTarget(parsing: "localhost:1")
        func endpoint(requested: Duration?) -> GRPCEndpoint {
            GRPCEndpoint(
                target: target, shownTarget: "localhost:1", metadata: [], shownMetadata: [],
                requestedTimeout: requested, defaultTimeout: .seconds(30), verifiesServer: true
            )
        }
        let unset = endpoint(requested: nil)
        XCTAssertNil(GRPCRequestResolution.timeout(for: unset, kind: .bidirectionalStreaming, keepsStreamOpen: true))
        XCTAssertNil(GRPCRequestResolution.timeout(for: unset, kind: .clientStreaming, keepsStreamOpen: true))
        XCTAssertEqual(GRPCRequestResolution.timeout(for: unset, kind: .bidirectionalStreaming, keepsStreamOpen: false), .seconds(30))
        XCTAssertEqual(GRPCRequestResolution.timeout(for: unset, kind: .serverStreaming, keepsStreamOpen: true), .seconds(30))
        let requested = endpoint(requested: .seconds(5))
        XCTAssertEqual(GRPCRequestResolution.timeout(for: requested, kind: .bidirectionalStreaming, keepsStreamOpen: true), .seconds(5))
    }

    /// A long stream keeps its newest events and counts the rest, however far the app fell behind.
    func testALongStreamKeepsItsNewestEventsAndCountsTheRest() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("ServerStream", messages: [#"{"text": "x", "index": 20000}"#]), server: server)

        let exchange = await makeRunner().run(request, in: project)

        let call = try XCTUnwrap(exchange.grpc, "\(exchange.outcome)")
        XCTAssertEqual(call.status?.isOK, true)
        XCTAssertEqual(call.events.count, GRPCCallRecord.eventLimit)
        XCTAssertEqual(call.events.count + call.omittedEventCount, 20_001, "One sent and 20,000 received")
        XCTAssertEqual(call.omittedEventCount, call.trimmedEventCount + call.droppedEventCount)
        XCTAssertEqual(call.sentCount, 1)
        XCTAssertEqual(call.receivedCount, 20_000)
        XCTAssertEqual(try json(call.events.last).value(forKey: "index") as? Int, 19_999, "The newest are kept")
        XCTAssertEqual(call.events.last?.sequence, 20_000, "Numbered across the whole call, the request first")
        XCTAssertEqual(call.events.map(\.sequence), call.events.map(\.sequence).sorted())
        XCTAssertGreaterThanOrEqual(call.events.first?.sequence ?? -1, call.trimmedEventCount, "Trimmed ones come first")
    }

    func testTheHistoryCutsLargeGRPCRecordsToItsLimits() throws {
        let history = RunHistoryStore(directory: fixture.directory.file("Support/History"))
        let big = String(repeating: "é", count: RunHistoryStore.messageLimit)
        let events = (0..<100).map { GRPCMessageEvent(direction: .received, offset: Double($0), json: big, byteCount: 1) }
        let record = GRPCCallRecord(target: "t:1", method: "a.B/C", kind: .serverStreaming, events: events, trimmedEventCount: 3)
        let exchange = RequestExchange(
            projectID: ProjectID(), requestID: RequestNodeID(), startedAt: Date(), environmentName: nil, request: nil, outcome: .grpc(record)
        )

        history.save(exchange)
        let stored = try XCTUnwrap(history.load(exchange.id, for: exchange.requestID, in: exchange.projectID))

        let call = try XCTUnwrap(stored.grpc)
        XCTAssertTrue(stored.isBodyTruncated)
        XCTAssertTrue(call.events.allSatisfy { $0.json.utf8.count <= RunHistoryStore.messageLimit })
        XCTAssertLessThanOrEqual(call.events.reduce(0) { $0 + $1.json.utf8.count }, RunHistoryStore.bodyLimit)
        XCTAssertEqual(call.events.count + call.trimmedEventCount, 103, "Cut messages are the oldest, so trimmed")
        XCTAssertEqual(call.receivedCount, 100, "Totals survive the cut")
        XCTAssertEqual(call.events.last?.offset, 99, "The newest are kept")
    }

    func testAReflectionTimeoutIsATimeout() async throws {
        let silent = try await SilentServer.start()
        addTeardownBlock { await silent.stop() }
        let server = try await start()
        var spec = echoSpec("Unary", schema: .reflection)
        spec.deadlineSeconds = 0.2
        let (project, request) = try makeProject(spec, server: server)
        try fixture.library.mutate(project) { $0.defaultEnvironment.variables = [Variable(key: "target", value: silent.target.description)] }

        let exchange = await makeRunner().run(request, in: project)

        XCTAssertEqual(exchange.failure?.kind, .timedOut, "\(exchange.outcome)")
    }

    /// A compile that never finishes must not hold a cancelled run.
    func testCancellingWhileTheProtosCompileEndsTheRun() async throws {
        let server = try await start()
        let (project, request) = try makeProject(echoSpec("Unary", schema: .projectProtos), server: server)
        try FileManager.default.createDirectory(at: fixture.projectURL(project).appendingPathComponent("protos"), withIntermediateDirectories: true)
        try fixture.library.mutate(project) { $0.grpc = ProjectGRPCConfiguration(protoRoots: [.relative("protos")]) }
        // Cancellable, so the workspace's own compile ends when the test's store goes away.
        let runner = makeRunner(schemas: makeSchemas {
            try await Task.sleep(for: .seconds(3_600))
            return nil
        })

        let running = Task { await runner.run(request, in: project) }
        await waitUntil("in flight") { runner.isInFlight(request, in: project) }
        runner.cancel(request, in: project)
        let exchange = await bounded("cancel", running)

        XCTAssertEqual(exchange?.failure?.kind, .cancelled, "\(String(describing: exchange?.outcome))")
    }

    /// A lookup that was in flight when the reflection cache was refreshed must not refill it with its stale result.
    func testARefreshDuringAReflectionLookupLeavesNothingStaleCached() async throws {
        let files = try Google_Protobuf_FileDescriptorSet(serializedBytes: Data(contentsOf: try ProtocFixtures.codecDescriptorSet)).file
        let gate = TestGate()
        let listings = ListingCounter()
        var alpha = AlphaReflectionService(files: files)
        alpha.gate = gate
        alpha.onListServices = { listings.increment() }
        let server = try await start([alpha])
        let (project, request) = try makeProject(echoSpec("Unary", schema: .reflection), server: server)
        let schemas = makeSchemas()
        let runner = makeRunner(schemas: schemas)

        let lookup = Task { try await runner.grpcSchema(for: request, in: project) }
        await listings.waitFor(1)
        schemas.refreshReflection(in: project)
        gate.open()
        let stale = try await lookup.value
        _ = try await runner.grpcSchema(for: request, in: project)
        _ = try await runner.grpcSchema(for: request, in: project)

        XCTAssertEqual(stale.registry.services.map(\.fullName), [EchoService.name], "The caller still gets its result")
        XCTAssertEqual(listings.count, 2, "Refetched once after the refresh, then cached")
    }
}

/// Counts reflection listings, and lets a test wait for the first ones.
final class ListingCounter: Sendable {
    private let state = Mutex((count: 0, waiters: [(Int, CheckedContinuation<Void, Never>)]()))

    var count: Int {
        state.withLock { $0.count }
    }

    func increment() {
        let ready = state.withLock { state in
            state.count += 1
            let count = state.count
            let ready = state.waiters.filter { $0.0 <= count }
            state.waiters.removeAll { $0.0 <= count }
            return ready.map(\.1)
        }
        ready.forEach { $0.resume() }
    }

    func waitFor(_ target: Int) async {
        await withCheckedContinuation { continuation in
            let ready = state.withLock { state -> Bool in
                if state.count >= target {
                    return true
                }
                state.waiters.append((target, continuation))
                return false
            }
            if ready {
                continuation.resume()
            }
        }
    }
}
