import Foundation
import ReqlingKit
import XCTest

@testable import Reqling

@MainActor
final class BodySearchModelTests: XCTestCase {
    private func timeline(_ count: Int, id: UUID) throws -> BodySearchTarget {
        .tree(.messages(MessageTimeline(id: id, messages: try (0..<count).map { sequence in
            let json = #"{"text": "hit \#(sequence)"}"#
            return MessageTimeline.Message(
                event: GRPCMessageEvent(direction: .received, offset: 0, json: json, byteCount: 1, sequence: sequence),
                index: try JSONStructureIndex.build(Data(json.utf8))
            )
        })))
    }

    func testStepsThroughMatchesAndWrapsAround() async throws {
        let search = BodySearchModel()
        search.present()
        search.query = "hit"
        await search.search(in: try timeline(3, id: UUID()))
        XCTAssertEqual(search.status, "1 of 3")

        search.previous()
        XCTAssertEqual(search.status, "3 of 3")
        search.next()
        XCTAssertEqual(search.currentTreeMatch?.path, [0, 0])
    }

    /// A streaming call's timeline grows under one identity; searching it again keeps the current match.
    func testARerunOnAGrowingTimelineKeepsTheCurrentMatch() async throws {
        let id = UUID()
        let search = BodySearchModel()
        search.present()
        search.query = "hit"
        await search.search(in: try timeline(3, id: id))
        search.next()

        await search.search(in: try timeline(5, id: id))

        XCTAssertEqual(search.status, "2 of 5")

        await search.search(in: try timeline(5, id: UUID()))
        XCTAssertEqual(search.status, "1 of 5", "another body starts over")
    }
}
