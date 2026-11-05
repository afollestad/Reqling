import Foundation
@testable import ReqlingKit
import SwiftProtobuf
import XCTest

final class GRPCCallRecordTests: XCTestCase {
    /// A record cached before sequences, totals, and the split counts decodes them from what it has.
    func testARecordCachedBeforeTheCountsDecodesThem() throws {
        let legacy = """
        {"target": "t:1", "method": "a.B/C", "kind": "bidirectionalStreaming", "sentMetadata": [], "initialMetadata": [],
         "trailers": [], "duration": 1, "omittedEventCount": 5, "events": [
            {"direction": "sent", "offset": 0, "json": "{}", "byteCount": 0},
            {"direction": "received", "offset": 0.5, "json": "{}", "byteCount": 0}
         ]}
        """

        let record = try JSONDecoder().decode(GRPCCallRecord.self, from: Data(legacy.utf8))

        XCTAssertEqual(record.events.map(\.sequence), [5, 6], "Numbered after the omitted ones")
        XCTAssertEqual(record.trimmedEventCount, 5)
        XCTAssertEqual(record.droppedEventCount, 0)
        XCTAssertEqual(record.omittedEventCount, 5)
        XCTAssertEqual(record.sentCount, 1)
        XCTAssertEqual(record.receivedCount, 6, "Omissions count as received")
    }

    func testARecordRoundTripsItsCounts() throws {
        let event = GRPCMessageEvent(direction: .received, offset: 1, json: "{}", byteCount: 2, sequence: 41)
        let record = GRPCCallRecord(
            target: "t:1", method: "a.B/C", kind: .serverStreaming, events: [event],
            sentCount: 1, receivedCount: 40, trimmedEventCount: 30, droppedEventCount: 10
        )

        let decoded = try JSONDecoder().decode(GRPCCallRecord.self, from: JSONEncoder().encode(record))

        XCTAssertEqual(decoded, record)
        XCTAssertEqual(decoded.omittedEventCount, 40)
    }

    /// The live record numbers messages as the executor did, trims the oldest past the window, and counts what the
    /// executor dropped separately.
    @MainActor
    func testTheLiveRecordSplitsTrimmedFromDropped() throws {
        let live = try makeLiveCall()
        live.apply(.sent(index: 0, sequence: 0, timestamp: Date()))
        let total = GRPCCallRecord.eventLimit * 2
        for sequence in 1...total where sequence != 7 {
            live.apply(.received(try Reqling_Test_V1_EchoMessage().serializedBytes(), sequence: sequence, timestamp: Date()))
        }
        // Running totals: a repeated report supersedes rather than adds.
        live.apply(.omitted(sent: 0, received: 1))
        live.apply(.omitted(sent: 0, received: 1))

        let record = live.record

        XCTAssertEqual(record.events.count, GRPCCallRecord.eventLimit)
        XCTAssertEqual(record.events.last?.sequence, total)
        XCTAssertEqual(record.trimmedEventCount, total + 1 - 1 - GRPCCallRecord.eventLimit)
        XCTAssertEqual(record.droppedEventCount, 1)
        XCTAssertEqual(record.sentCount, 1)
        XCTAssertEqual(record.receivedCount, total)
        XCTAssertEqual(record.events.count + record.omittedEventCount, total + 1)
    }

    @MainActor
    private func makeLiveCall() throws -> GRPCLiveCall {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "codec_test", withExtension: "binpb", subdirectory: "Fixtures"))
        let registry = try DescriptorRegistry(descriptorSet: Data(contentsOf: url))
        let method = try XCTUnwrap(registry.method("reqling.test.v1.EchoService/ServerStream"))
        let resolver = TemplateResolver(scope: VariableScope(global: .global(), document: ProjectDocument(name: "T"), activeEnvironmentID: nil))
        let endpoint = GRPCEndpoint(
            target: try GRPCTarget(parsing: "localhost:1"), shownTarget: "localhost:1", metadata: [], shownMetadata: [],
            requestedTimeout: nil, defaultTimeout: .seconds(30), verifiesServer: true
        )
        return GRPCLiveCall(
            context: GRPCLiveCall.Context(
                runID: RunID(), projectID: ProjectID(), requestID: RequestNodeID(), startedAt: Date(), environmentName: "Default",
                unresolvedVariables: [], resolver: resolver, redaction: SecretRedaction(resolver: resolver), allowUnresolved: false
            ),
            method: method,
            endpoint: endpoint,
            codec: ProtobufJSONCodec(registry: registry),
            seeds: []
        )
    }
}
