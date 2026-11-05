import Foundation
import ReqlingKit

/// Exchanges with fixed dates, for the history suites.
enum HistoryFixtures {
    static func exchange(
        _ key: RunKey,
        statusCode: Int,
        at seconds: TimeInterval,
        body: Data = Data("{}".utf8)
    ) -> RequestExchange {
        let startedAt = Date(timeIntervalSince1970: seconds)
        let response = HTTPResponseRecord(
            statusCode: statusCode,
            headers: [],
            body: body,
            url: "https://example.test",
            startedAt: startedAt,
            duration: 0.1
        )
        return RequestExchange(
            projectID: key.projectID,
            requestID: key.requestID,
            startedAt: startedAt,
            environmentName: nil,
            spec: .http(HTTPRequestSpec(url: "https://example.test")),
            request: nil,
            outcome: .response(response)
        )
    }
}
