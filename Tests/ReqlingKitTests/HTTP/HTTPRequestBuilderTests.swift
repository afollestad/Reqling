import Foundation
import ReqlingKit
import ReqlingTemplating
import Synchronization
import XCTest

final class HTTPRequestBuilderTests: XCTestCase {
    private var directory: TemporaryDirectory!

    override func setUpWithError() throws {
        directory = try TemporaryDirectory()
    }

    override func tearDown() {
        directory.remove()
    }

    func context(
        variables: [String: (String, Bool)] = [:],
        authChain: [HTTPAuth] = [.none],
        dynamic: DynamicVariables = .live
    ) -> HTTPBuildContext {
        let entries = variables.mapValues { VariableScope.Entry(value: $0.0, source: .override, isSecret: $0.1) }
        return HTTPBuildContext(
            resolver: TemplateResolver(scope: VariableScope(entries: entries), dynamic: dynamic),
            authChain: authChain,
            paths: ProjectPathResolver(projectRoot: directory.url),
            defaults: HTTPRequestDefaults(timeoutSeconds: 12, followRedirects: true, verifyTLS: true),
            userAgent: "Reqling/1.0",
            makeBoundary: { "BOUNDARY" }
        )
    }

    private func header(_ name: String, in prepared: PreparedHTTPRequest) -> String? {
        prepared.urlRequest.value(forHTTPHeaderField: name)
    }

    private func body(_ prepared: PreparedHTTPRequest) -> String? {
        prepared.urlRequest.httpBody?.utf8Text
    }

    func testResolvesTheURLAndEncodesQueryParametersOnce() throws {
        let spec = HTTPRequestSpec(
            url: "{{base}}/users",
            queryParameters: [
                KeyValuePair(key: "q", value: "{{name}} & co"),
                KeyValuePair(key: "pre", value: "a%20b"),
                KeyValuePair(key: "off", value: "x", isEnabled: false),
                KeyValuePair(key: "flag", value: "")
            ]
        )

        let variables = ["base": ("https://api.test", false), "name": ("Ada L", false)]
        let prepared = try HTTPRequestBuilder.prepare(spec, context: context(variables: variables))

        XCTAssertEqual(prepared.urlRequest.url?.absoluteString, "https://api.test/users?q=Ada%20L%20%26%20co&pre=a%20b&flag")
        XCTAssertEqual(prepared.urlRequest.timeoutInterval, 12)
        XCTAssertTrue(prepared.unresolvedVariables.isEmpty)
    }

    func testAURLWithoutASchemeDefaultsToHTTPAndBadURLsAreRejected() throws {
        let schemeless = try HTTPRequestBuilder.prepare(HTTPRequestSpec(url: "localhost:8080/x"), context: context())
        XCTAssertEqual(schemeless.urlRequest.url?.absoluteString, "http://localhost:8080/x")
        XCTAssertThrowsError(try HTTPRequestBuilder.prepare(HTTPRequestSpec(url: "  "), context: context())) { error in
            XCTAssertEqual(error as? HTTPBuildError, .invalidURL(""))
        }
        XCTAssertThrowsError(try HTTPRequestBuilder.prepare(HTTPRequestSpec(method: "BAD METHOD", url: "https://x"), context: context())) { error in
            XCTAssertEqual(error as? HTTPBuildError, .invalidMethod("BAD METHOD"))
        }
    }

    func testUnresolvedVariablesAreReported() throws {
        let prepared = try HTTPRequestBuilder.prepare(HTTPRequestSpec(url: "https://x/{{missing}}"), context: context())

        XCTAssertEqual(prepared.unresolvedVariables, ["missing"])
    }

    func testAutomaticHeadersCanBeOverriddenOrDisabled() throws {
        var spec = HTTPRequestSpec(method: .post, url: "https://x", body: .raw("{}"))
        let defaults = try HTTPRequestBuilder.prepare(spec, context: context())
        XCTAssertEqual(header("User-Agent", in: defaults), "Reqling/1.0")
        XCTAssertEqual(header("Accept", in: defaults), "*/*")
        XCTAssertEqual(header("Content-Type", in: defaults), "application/json")

        spec.headers = [KeyValuePair(key: "user-agent", value: "custom")]
        spec.disabledAutoHeaders = ["accept"]
        let customized = try HTTPRequestBuilder.prepare(spec, context: context())

        XCTAssertEqual(header("User-Agent", in: customized), "custom")
        XCTAssertNil(header("Accept", in: customized))
    }

    func testMethodsWithoutABodyNeverSendOneButKeepIt() throws {
        var spec = HTTPRequestSpec(method: .get, url: "https://x", body: .raw(#"{"a": 1}"#))

        let get = try HTTPRequestBuilder.prepare(spec, context: context())
        XCTAssertNil(get.urlRequest.httpBody)
        XCTAssertNil(header("Content-Type", in: get))

        spec.method = .post
        XCTAssertEqual(body(try HTTPRequestBuilder.prepare(spec, context: context())), #"{"a": 1}"#)
        XCTAssertEqual(HTTPMethod.head.bodyPolicy, .none)
        XCTAssertEqual(HTTPMethod.trace.bodyPolicy, .none)
        XCTAssertEqual(HTTPMethod.delete.bodyPolicy, .optional)
        XCTAssertEqual(HTTPMethod("PURGE").bodyPolicy, .expected)
    }

    func testCustomMethodsAreValidatedAsTokens() {
        XCTAssertTrue(HTTPMethod("PURGE").isValid)
        XCTAssertTrue(HTTPMethod("X-THING.v2").isValid)
        XCTAssertFalse(HTTPMethod("BAD METHOD").isValid)
        XCTAssertFalse(HTTPMethod("").isValid)
        XCTAssertEqual(HTTPMethod("get"), .get)
        XCTAssertEqual(HTTPMethod("purge").rawValue, "purge")
    }

    func testAuthIsInheritedFromTheNearestFolderThenTheProject() throws {
        let spec = HTTPRequestSpec(url: "https://x")
        let folderChain: [HTTPAuth] = [.basic(username: "p", password: "q"), .bearer(token: "t"), .inherit]
        let folder = try HTTPRequestBuilder.prepare(spec, context: context(authChain: folderChain))
        let project = try HTTPRequestBuilder.prepare(spec, context: context(authChain: [.basic(username: "ada", password: "pw"), .inherit]))
        let none = try HTTPRequestBuilder.prepare(spec, context: context(authChain: [.inherit]))

        XCTAssertEqual(header("Authorization", in: folder), "Bearer t")
        XCTAssertEqual(header("Authorization", in: project), "Basic \(Data("ada:pw".utf8).base64EncodedString())")
        XCTAssertNil(header("Authorization", in: none))
    }

    func testAPIKeyAuthGoesInAHeaderOrTheQuery() throws {
        let headerSpec = HTTPRequestSpec(url: "https://x", auth: .apiKey(name: "X-Key", value: "{{k}}", location: .header))
        let querySpec = HTTPRequestSpec(url: "https://x", auth: .apiKey(name: "key", value: "v", location: .query))
        let header = try HTTPRequestBuilder.prepare(headerSpec, context: context(variables: ["k": ("v", false)]))
        let query = try HTTPRequestBuilder.prepare(querySpec, context: context())

        XCTAssertEqual(self.header("X-Key", in: header), "v")
        XCTAssertEqual(query.urlRequest.url?.query, "key=v")
    }

    func testURLEncodedForms() throws {
        let spec = HTTPRequestSpec(method: .post, url: "https://x", body: HTTPBody(mode: .urlEncoded, urlEncoded: [
            KeyValuePair(key: "a", value: "1 2"),
            KeyValuePair(key: "b", value: "&%"),
            KeyValuePair(key: "c", value: "off", isEnabled: false)
        ]))

        let prepared = try HTTPRequestBuilder.prepare(spec, context: context())

        XCTAssertEqual(body(prepared), "a=1+2&b=%26%25")
        XCTAssertEqual(header("Content-Type", in: prepared), "application/x-www-form-urlencoded")
    }

    func testMultipartFormsWithTextAndFileParts() throws {
        try Data("file-bytes".utf8).write(to: directory.file("photo.png"))
        let spec = HTTPRequestSpec(method: .post, url: "https://x", body: HTTPBody(mode: .formData, formData: [
            MultipartField(key: "name", value: "{{who}}"),
            MultipartField(key: "avatar", kind: .file, file: .relative("photo.png")),
            MultipartField(key: "skip", value: "x", isEnabled: false)
        ]))

        let prepared = try HTTPRequestBuilder.prepare(spec, context: context(variables: ["who": ("Ada", false)]))

        XCTAssertEqual(header("Content-Type", in: prepared), "multipart/form-data; boundary=BOUNDARY")
        XCTAssertEqual(body(prepared), [
            "--BOUNDARY",
            #"Content-Disposition: form-data; name="name""#,
            "",
            "Ada",
            "--BOUNDARY",
            #"Content-Disposition: form-data; name="avatar"; filename="photo.png""#,
            "Content-Type: image/png",
            "",
            "file-bytes",
            "--BOUNDARY--",
            ""
        ].joined(separator: "\r\n"))
    }

    func testBinaryBodiesAndMissingFiles() throws {
        try Data([0, 1, 2]).write(to: directory.file("blob.bin"))
        let present = HTTPRequestSpec(method: .put, url: "https://x", body: HTTPBody(mode: .binary, binary: BinaryBody(file: .relative("blob.bin"))))
        let missing = HTTPRequestSpec(method: .put, url: "https://x", body: HTTPBody(mode: .binary, binary: BinaryBody(file: .relative("gone.bin"))))

        let prepared = try HTTPRequestBuilder.prepare(present, context: context())

        XCTAssertEqual(prepared.urlRequest.httpBody, Data([0, 1, 2]))
        XCTAssertEqual(header("Content-Type", in: prepared), "application/octet-stream")
        XCTAssertThrowsError(try HTTPRequestBuilder.prepare(missing, context: context())) { error in
            XCTAssertEqual(error as? HTTPBuildError, .missingFile("“gone.bin”"))
        }
    }

    func testGraphQLBodies() throws {
        var spec = HTTPRequestSpec(method: .post, url: "https://x/graphql", body: HTTPBody(mode: .graphQL, graphQL: GraphQLBody(
            query: "query User($id: ID!) { user(id: $id) { name } }",
            variables: #"{"id": "{{id}}"}"#,
            operationName: "User"
        )))

        let prepared = try HTTPRequestBuilder.prepare(spec, context: context(variables: ["id": ("7", false)]))

        XCTAssertEqual(header("Content-Type", in: prepared), "application/json")
        XCTAssertEqual(body(prepared), #"{"operationName":"User","query":"query User($id: ID!) { user(id: $id) { name } }","variables":{"id":"7"}}"#)

        spec.body.graphQL.variables = "[1]"
        XCTAssertThrowsError(try HTTPRequestBuilder.prepare(spec, context: context())) { error in
            XCTAssertEqual(error as? HTTPBuildError, .invalidGraphQLVariables("Expected an object."))
        }
    }

    func testTheSummaryMasksSecrets() throws {
        let spec = HTTPRequestSpec(
            method: .post,
            url: "https://x/{{token}}",
            headers: [KeyValuePair(key: "X-Token", value: "{{token}}")],
            body: .raw("{{token}}")
        )

        let prepared = try HTTPRequestBuilder.prepare(spec, context: context(variables: ["token": ("s3cr3t", true)]))

        XCTAssertEqual(header("X-Token", in: prepared), "s3cr3t")
        XCTAssertFalse(prepared.summary.url.contains("s3cr3t"))
        XCTAssertFalse(prepared.summary.headers.contains { $0.value.contains("s3cr3t") })
        XCTAssertEqual(prepared.summary.bodyPreview, TemplateResolver.mask)
    }

    /// Characters the URL bar would read back as syntax show escaped, so editing the bar never splits or cuts a row,
    /// and the request sends the same bytes either way.
    func testDisplayURLEscapesWhatTheBarWouldMisread() throws {
        var spec = HTTPRequestSpec(url: "https://x/s", queryParameters: [
            KeyValuePair(key: "q", value: "a#b"),
            KeyValuePair(key: "k=1", value: "x&y=z"),
            KeyValuePair(key: "sum", value: "1+1")
        ])
        let before = try HTTPRequestBuilder.prepare(spec, context: context()).urlRequest.url

        XCTAssertEqual(spec.displayURL, "https://x/s?q=a%23b&k%3D1=x%26y=z&sum=1%2B1")
        spec.applyDisplayURL(spec.displayURL)

        XCTAssertEqual(spec.queryParameters.map(\.key), ["q", "k%3D1", "sum"])
        XCTAssertEqual(try HTTPRequestBuilder.prepare(spec, context: context()).urlRequest.url, before)
    }

    func testDisplayURLRoundTripsQueryRowsAndKeepsDisabledOnes() {
        var spec = HTTPRequestSpec(url: "https://x/a", queryParameters: [KeyValuePair(key: "off", value: "1", isEnabled: false)])

        spec.applyDisplayURL("https://x/b?q=1&flag#frag")

        XCTAssertEqual(spec.url, "https://x/b")
        XCTAssertEqual(spec.queryParameters.unidentified, [
            KeyValuePair(key: "q", value: "1"),
            KeyValuePair(key: "flag", value: ""),
            KeyValuePair(key: "off", value: "1", isEnabled: false)
        ].unidentified)
        XCTAssertEqual(spec.displayURL, "https://x/b?q=1&flag")
    }

    func testTheSummaryShowsTheDynamicValuesThatWereSent() throws {
        let counter = Counter()
        let dynamic = DynamicVariables(now: { Date() }, uuid: { counter.nextUUID() }, randomInt: { 4 })
        let spec = HTTPRequestSpec(
            method: .post,
            url: "https://x",
            headers: [KeyValuePair(key: "X-Id", value: "{{$uuid}}")],
            body: .raw("{{$uuid}}")
        )

        let prepared = try HTTPRequestBuilder.prepare(spec, context: context(dynamic: dynamic))

        let sent = try XCTUnwrap(header("X-Id", in: prepared))
        XCTAssertEqual(prepared.summary.headers.first { $0.key == "X-Id" }?.value, sent)
        XCTAssertEqual(prepared.summary.bodyPreview, body(prepared))
        XCTAssertNotEqual(body(prepared), sent)
    }

    func testAUserMultipartContentTypeGetsTheBoundary() throws {
        var spec = HTTPRequestSpec(
            method: .post,
            url: "https://x",
            headers: [KeyValuePair(key: "content-type", value: "multipart/form-data")],
            body: HTTPBody(mode: .formData, formData: [MultipartField(key: "a", value: "1")])
        )
        XCTAssertEqual(header("Content-Type", in: try HTTPRequestBuilder.prepare(spec, context: context())), "multipart/form-data; boundary=BOUNDARY")

        spec.headers = [KeyValuePair(key: "Content-Type", value: "multipart/form-data; boundary=mine")]
        XCTAssertEqual(header("Content-Type", in: try HTTPRequestBuilder.prepare(spec, context: context())), "multipart/form-data; boundary=mine")
    }

    func testBuildErrorsNeverQuoteSecrets() throws {
        let spec = HTTPRequestSpec(url: "https://api.example.com:{{port}}/bot{{token}}")

        XCTAssertThrowsError(try HTTPRequestBuilder.prepare(spec, context: context(variables: ["token": ("s3cr3t", true)]))) { error in
            XCTAssertEqual(error as? HTTPBuildError, .invalidURL("https://api.example.com:{{port}}/bot\(TemplateResolver.mask)"))
        }

        let graphQL = HTTPRequestSpec(method: .post, url: "https://x", body: HTTPBody(mode: .graphQL, graphQL: GraphQLBody(
            query: "{ a }",
            variables: #"{"key": "{{token}}"}"#
        )))
        XCTAssertThrowsError(try HTTPRequestBuilder.prepare(graphQL, context: context(variables: ["token": (#"s3"cr3t"#, true)]))) { error in
            XCTAssertFalse(error.localizedDescription.contains("cr3t"))
        }
    }

    func testMaskingNeverBlocksAValidRequest() throws {
        let spec = HTTPRequestSpec(method: .post, url: "https://x", body: HTTPBody(mode: .graphQL, graphQL: GraphQLBody(
            query: "{ items }",
            variables: #"{"limit": {{limit}}}"#
        )))

        let prepared = try HTTPRequestBuilder.prepare(spec, context: context(variables: ["limit": ("5", true)]))

        XCTAssertEqual(body(prepared), #"{"query":"{ items }","variables":{"limit":5}}"#)
        XCTAssertEqual(prepared.summary.bodyPreview, #"{"query":"{ items }","variables":{"limit": \#(TemplateResolver.mask)}}"#)
    }

    func testVariablesThatExpandWithoutBoundFailClearly() throws {
        var variables: [String: (String, Bool)] = ["v9": (String(repeating: "x", count: 64), false)]
        for level in 0..<9 {
            variables["v\(level)"] = (String(repeating: "{{v\(level + 1)}}", count: 10), false)
        }

        let spec = HTTPRequestSpec(url: "https://x/{{v0}}")
        XCTAssertThrowsError(try HTTPRequestBuilder.prepare(spec, context: context(variables: variables))) { error in
            XCTAssertEqual(error as? HTTPBuildError, .templateTooLarge)
        }
    }

    func testAPlusInAPastedQueryMeansASpace() throws {
        var spec = HTTPRequestSpec()
        spec.applyDisplayURL("https://x/search?q=a+b&lit=%2B")

        XCTAssertEqual(spec.queryParameters.unidentified, [KeyValuePair(key: "q", value: "a b"), KeyValuePair(key: "lit", value: "%2B")].unidentified)
        let prepared = try HTTPRequestBuilder.prepare(spec, context: context())
        XCTAssertEqual(prepared.urlRequest.url?.absoluteString, "https://x/search?q=a%20b&lit=%2B")

        // A literal `+` typed into a row survives an edit of the URL bar.
        spec.queryParameters = [KeyValuePair(key: "tel", value: "+1 555")]
        XCTAssertEqual(spec.displayURL, "https://x/search?tel=%2B1 555")
        spec.applyDisplayURL(spec.displayURL)
        XCTAssertEqual(try HTTPRequestBuilder.prepare(spec, context: context()).urlRequest.url?.absoluteString, "https://x/search?tel=%2B1%20555")
    }
}

/// Hands out sequential UUIDs, so each generated value is distinguishable.
private final class Counter: Sendable {
    private let value = Mutex(0)

    func nextUUID() -> UUID {
        let next = value.withLock { value in
            value += 1
            return value
        }
        return UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", next)) ?? UUID()
    }
}
