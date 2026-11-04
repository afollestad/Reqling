import Foundation
@testable import ReqlingKit
import XCTest

final class ResponseCacheWriterTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory.remove()
        directory = nil
    }

    func testReadsWaitForSavesQueuedBeforeThem() {
        let writer = ResponseCacheWriter(cache: ResponseCache(directory: directory.url))
        let exchange = makeExchange(statusCode: 200)

        writer.save(exchange)

        XCTAssertEqual(writer.load(exchange.requestID, in: exchange.projectID), exchange)
        XCTAssertEqual(writer.outcomes(in: exchange.projectID), [exchange.requestID: .succeeded])
    }

    func testSavesKeepEveryOutcomeInTheIndex() {
        let writer = ResponseCacheWriter(cache: ResponseCache(directory: directory.url))
        let project = ProjectID()
        let exchanges = (0..<20).map { makeExchange(statusCode: $0.isMultiple(of: 2) ? 200 : 500, project: project) }

        exchanges.forEach(writer.save)

        XCTAssertEqual(writer.outcomes(in: project).count, exchanges.count)
    }

    /// A removal is on disk when it returns, after any save queued before it, so nothing queued can bring a forgotten
    /// response back and a direct save made right after it survives.
    func testRemovalsLandBeforeTheyReturn() {
        let cache = ResponseCache(directory: directory.url)
        let writer = ResponseCacheWriter(cache: cache)
        let forgotten = makeExchange(statusCode: 200)
        writer.save(forgotten)

        writer.removeAll(in: forgotten.projectID)

        XCTAssertNil(cache.load(forgotten.requestID, in: forgotten.projectID), "no flush needed")
        XCTAssertNil(writer.load(forgotten.requestID, in: forgotten.projectID))

        let seeded = makeExchange(statusCode: 404, project: forgotten.projectID)
        cache.save(seeded)
        writer.flush()
        XCTAssertEqual(writer.load(seeded.requestID, in: seeded.projectID), seeded)

        writer.save(forgotten)
        writer.remove(forgotten.requestID, in: forgotten.projectID)
        XCTAssertNil(cache.load(forgotten.requestID, in: forgotten.projectID))
        XCTAssertEqual(writer.outcomes(in: forgotten.projectID), [seeded.requestID: .failed])
    }

    private func makeExchange(statusCode: Int, project: ProjectID = ProjectID()) -> RequestExchange {
        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let response = HTTPResponseRecord(
            statusCode: statusCode,
            headers: [],
            body: Data("{}".utf8),
            url: "https://example.test",
            startedAt: startedAt,
            duration: 0.1
        )
        return RequestExchange(
            projectID: project,
            requestID: RequestNodeID(),
            startedAt: startedAt,
            environmentName: nil,
            request: nil,
            outcome: .response(response)
        )
    }
}
