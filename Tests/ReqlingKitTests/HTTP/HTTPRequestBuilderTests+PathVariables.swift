import Foundation
import ReqlingKit
import XCTest

/// `:name` path segments, replaced by their rows' values as the request is built.
extension HTTPRequestBuilderTests {
    func testPathVariablesAreResolvedAndEncodedAsOneSegment() throws {
        let spec = HTTPRequestSpec(
            url: "{{base}}/files/:path/v/:version",
            queryParameters: [KeyValuePair(key: "q", value: "1")],
            pathVariables: [KeyValuePair(key: "path", value: "a/b {{name}}"), KeyValuePair(key: "version", value: "2")]
        )

        let variables = ["base": ("https://api.test:8443", false), "name": ("c?d", false)]
        let prepared = try HTTPRequestBuilder.prepare(spec, context: context(variables: variables))

        XCTAssertEqual(prepared.urlRequest.url?.absoluteString, "https://api.test:8443/files/a%2Fb%20c%3Fd/v/2?q=1")
        XCTAssertEqual(prepared.summary.url, prepared.urlRequest.url?.absoluteString)
        XCTAssertEqual(prepared.emptyPathVariables, [])
    }

    func testASecretInAPathVariableIsMaskedInTheSummary() throws {
        let spec = HTTPRequestSpec(url: "https://api.test/keys/:key", pathVariables: [KeyValuePair(key: "key", value: "{{secret}}")])

        let prepared = try HTTPRequestBuilder.prepare(spec, context: context(variables: ["secret": ("hunter2", true)]))

        XCTAssertEqual(prepared.urlRequest.url?.path, "/keys/hunter2")
        XCTAssertFalse(prepared.summary.url.contains("hunter2"), prepared.summary.url)
    }

    func testAnEmptyPathVariableKeepsItsNameAndIsReported() throws {
        let spec = HTTPRequestSpec(
            url: "https://api.test/:org/:repo/:org",
            pathVariables: [KeyValuePair(key: "org", value: "{{empty}}"), KeyValuePair(key: "repo", value: "reqling")]
        )

        let prepared = try HTTPRequestBuilder.prepare(spec, context: context(variables: ["empty": ("", false)]))

        XCTAssertEqual(prepared.urlRequest.url?.path, "/:org/reqling/:org")
        XCTAssertEqual(prepared.emptyPathVariables, ["org"])
        XCTAssertEqual(prepared.unresolvedVariables, [])
    }

    func testAVariablesValueNeverAddsAPathVariable() throws {
        let spec = HTTPRequestSpec(url: "{{base}}/:id", pathVariables: [KeyValuePair(key: "id", value: "7")])

        let prepared = try HTTPRequestBuilder.prepare(spec, context: context(variables: ["base": ("https://api.test/:tenant", false)]))

        XCTAssertEqual(prepared.urlRequest.url?.path, "/:tenant/7")
        XCTAssertEqual(prepared.emptyPathVariables, [])
    }
}
