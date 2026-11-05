import Foundation
import NIOHTTP1
import ReqlingKit
import Synchronization
import XCTest

final class HTTPExecutorTests: XCTestCase {
    private var servers: [TestHTTPServer] = []

    override func tearDown() async throws {
        for server in servers {
            try await server.shutdown()
        }
        servers = []
    }

    private func start(
        tls: Bool = false,
        requireClientCertificate: Bool = false,
        respond: @escaping @Sendable (TestHTTPServer.Request) -> TestHTTPServer.Response
    ) async throws -> TestHTTPServer {
        let context = tls ? try TLSFixtures.serverContext(requireClientCertificate: requireClientCertificate) : nil
        let server = try await TestHTTPServer.start(tls: context, respond: respond)
        servers.append(server)
        return server
    }

    private func prepare(
        _ spec: HTTPRequestSpec,
        timeout: Double = 10,
        followRedirects: Bool = true,
        verifyTLS: Bool = true,
        variables: [String: VariableScope.Entry] = [:]
    ) throws -> PreparedHTTPRequest {
        try HTTPRequestBuilder.prepare(spec, context: HTTPBuildContext(
            resolver: TemplateResolver(scope: VariableScope(entries: variables)),
            authChain: [.none],
            paths: ProjectPathResolver(projectRoot: FileManager.default.temporaryDirectory),
            defaults: HTTPRequestDefaults(timeoutSeconds: timeout, followRedirects: followRedirects, verifyTLS: verifyTLS),
            userAgent: "Reqling/1.0",
            makeBoundary: { "BOUNDARY" }
        ))
    }

    func testSendsTheRequestAndRecordsTheResponse() async throws {
        let server = try await start { request in
            .text(#"{"ok":true}"#, status: .created, headers: [("Content-Type", "application/json"), ("X-Echo", request.method)])
        }
        let spec = HTTPRequestSpec(
            method: .post,
            url: "\(server.baseURL)/users",
            headers: [KeyValuePair(key: "X-Trace", value: "1")],
            body: .raw(#"{"name":"Ada"}"#)
        )

        let response = try await HTTPExecutor().execute(try prepare(spec), tls: .default)

        let received = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(received.method, "POST")
        XCTAssertEqual(received.uri, "/users")
        XCTAssertEqual(received.body.utf8Text, #"{"name":"Ada"}"#)
        XCTAssertEqual(received.header("User-Agent"), "Reqling/1.0")
        XCTAssertEqual(received.header("Content-Type"), "application/json")
        XCTAssertEqual(received.header("X-Trace"), "1")
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.reasonPhrase, "Created")
        XCTAssertEqual(response.header("x-echo"), "POST")
        XCTAssertEqual(response.body.utf8Text, #"{"ok":true}"#)
        XCTAssertEqual(response.protocolName, "http/1.1")
        XCTAssertNotNil(response.timing)
        XCTAssertFalse(response.presentedClientCertificate)
    }

    /// The editor's automatic-header list claims what macOS adds below Reqling; check those claims on the wire.
    func testTheAutomaticHeadersListMatchesWhatMacOSSends() async throws {
        let server = try await start { _ in .text("ok") }
        var spec = HTTPRequestSpec(method: .post, url: "\(server.baseURL)/echo", body: .raw("x", contentType: ""))
        spec.disabledAutoHeaders = ["accept", "user-agent"]
        let listed = HTTPRequestBuilder.autoHeaders(for: spec, userAgent: "Reqling/1.0")

        _ = try await HTTPExecutor().execute(try prepare(spec), tls: .default)

        let received = try XCTUnwrap(server.requests.first)
        for header in listed {
            XCTAssertNotNil(received.header(header.name), "\(header.name) is listed but was not sent")
        }
        XCTAssertEqual(received.header("Content-Type"), HTTPRequestBuilder.systemContentType)
        XCTAssertEqual(received.header("Accept"), listed.first { $0.name == "Accept" }?.systemFallback)
        XCTAssertNotEqual(received.header("User-Agent"), "Reqling/1.0", "a turned-off User-Agent falls back to the system's")
    }

    func testRedirectsAreFollowedOnlyWhenAllowed() async throws {
        let server = try await start { request in
            request.uri == "/start" ? .reply(status: .found, headers: [("Location", "/end")]) : .text("arrived")
        }
        let spec = HTTPRequestSpec(url: "\(server.baseURL)/start")

        let followed = try await HTTPExecutor().execute(try prepare(spec), tls: .default)
        let held = try await HTTPExecutor().execute(try prepare(spec, followRedirects: false), tls: .default)

        XCTAssertEqual(followed.statusCode, 200)
        XCTAssertTrue(followed.url.hasSuffix("/end"))
        XCTAssertEqual(followed.redirectCount, 1)
        XCTAssertEqual(held.statusCode, 302)
        XCTAssertEqual(held.header("Location"), "/end")
    }

    func testATimeoutIsReportedAsSuch() async throws {
        let server = try await start { _ in .hang }

        do {
            _ = try await HTTPExecutor().execute(try prepare(HTTPRequestSpec(url: server.baseURL), timeout: 0.5), tls: .default)
            XCTFail("Expected a timeout")
        } catch {
            XCTAssertEqual(error as? HTTPExecutionError, .timedOut)
        }
    }

    func testCancellingTheTaskCancelsTheRequest() async throws {
        let (received, signal) = AsyncStream<Void>.makeStream()
        let server = try await start { _ in
            signal.yield()
            return .hang
        }
        let prepared = try prepare(HTTPRequestSpec(url: server.baseURL))
        let task = Task { try await HTTPExecutor().execute(prepared, tls: .default) }

        for await _ in received {
            break
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? HTTPExecutionError, .cancelled)
        }
    }

    func testEachExecutorKeepsItsOwnCookieJar() async throws {
        let server = try await start { request in
            request.uri == "/login" ? .text("in", headers: [("Set-Cookie", "session=abc; Path=/")]) : .text(request.header("Cookie") ?? "none")
        }
        let project = HTTPExecutor()
        let other = HTTPExecutor()

        _ = try await project.execute(try prepare(HTTPRequestSpec(url: "\(server.baseURL)/login")), tls: .default)
        let same = try await project.execute(try prepare(HTTPRequestSpec(url: "\(server.baseURL)/me")), tls: .default)
        let separate = try await other.execute(try prepare(HTTPRequestSpec(url: "\(server.baseURL)/me")), tls: .default)

        XCTAssertEqual(same.body.utf8Text, "session=abc")
        XCTAssertEqual(separate.body.utf8Text, "none")
    }

    func testCrossOriginRedirectsDropCredentialsButSameOriginOnesKeepThem() async throws {
        let originURL = SharedText()
        let target = try await start { request in
            request.uri == "/bounce" ? .reply(status: .found, headers: [("Location", "\(originURL.value)/back")]) : .text("landed")
        }
        let origin = try await start { request in
            switch request.uri {
            case "/away":
                .reply(status: .found, headers: [("Location", "\(target.baseURL)/landed")])
            case "/away-and-back":
                .reply(status: .found, headers: [("Location", "\(target.baseURL)/bounce")])
            case "/near":
                .reply(status: .found, headers: [("Location", "/end")])
            default:
                .text("end")
            }
        }
        originURL.value = origin.baseURL
        func send(_ path: String, auth: HTTPAuth) async throws {
            let spec = HTTPRequestSpec(
                url: "\(origin.baseURL)\(path)",
                headers: [
                    KeyValuePair(key: "Cookie", value: "session=abc"),
                    KeyValuePair(key: "X-Trace", value: "1"),
                    KeyValuePair(key: "X-Signature", value: "sig-{{signing}}")
                ],
                auth: auth
            )
            let secret = ["signing": VariableScope.Entry(value: "s3cr3t", source: .override, isSecret: true)]
            _ = try await HTTPExecutor().execute(try prepare(spec, variables: secret), tls: .default)
        }
        let apiKey = HTTPAuth.apiKey(name: "X-Api-Key", value: "k3y", location: .header)

        try await send("/away", auth: apiKey)
        try await send("/near", auth: apiKey)
        try await send("/near", auth: .bearer(token: "t"))
        try await send("/away-and-back", auth: .bearer(token: "t"))

        // The target listens on another port of the same host, which is another origin.
        let landed = try XCTUnwrap(target.requests.first { $0.uri == "/landed" })
        XCTAssertNil(landed.header("Cookie"))
        XCTAssertNil(landed.header("X-Api-Key"))
        // A header whose value uses a secret is a credential too.
        XCTAssertNil(landed.header("X-Signature"))
        XCTAssertEqual(landed.header("X-Trace"), "1")
        let sameOrigin = origin.requests.filter { $0.uri == "/end" }
        XCTAssertEqual(sameOrigin.map { $0.header("X-Api-Key") }, ["k3y", nil])
        XCTAssertEqual(sameOrigin.map { $0.header("Cookie") }, ["session=abc", "session=abc"])
        XCTAssertEqual(sameOrigin.first?.header("X-Signature"), "sig-s3cr3t")
        // URLSession drops `Authorization` on every redirect; a same-origin hop gets it back.
        XCTAssertEqual(sameOrigin.last?.header("Authorization"), "Bearer t")
        XCTAssertNil(try XCTUnwrap(target.requests.first { $0.uri == "/bounce" }).header("Authorization"))
        let back = try XCTUnwrap(origin.requests.first { $0.uri == "/back" })
        XCTAssertNil(back.header("Authorization"))
        XCTAssertNil(back.header("Cookie"))
    }

    func testCookiesSurviveATLSPolicyChange() async throws {
        let server = try await start { request in
            request.uri == "/login" ? .text("in", headers: [("Set-Cookie", "session=abc; Path=/")]) : .text(request.header("Cookie") ?? "none")
        }
        let executor = HTTPExecutor()

        _ = try await executor.execute(try prepare(HTTPRequestSpec(url: "\(server.baseURL)/login")), tls: .default)
        let unverified = try await executor.execute(try prepare(HTTPRequestSpec(url: "\(server.baseURL)/me"), verifyTLS: false), tls: .default)

        XCTAssertEqual(unverified.body.utf8Text, "session=abc")
    }

    func testInvalidatingCancelsRequestsInFlight() async throws {
        let (received, signal) = AsyncStream<Void>.makeStream()
        let server = try await start { _ in
            signal.yield()
            return .hang
        }
        let executor = HTTPExecutor()
        let prepared = try prepare(HTTPRequestSpec(url: server.baseURL))
        let task = Task { try await executor.execute(prepared, tls: .default) }

        for await _ in received {
            break
        }
        executor.invalidate()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? HTTPExecutionError, .cancelled)
        }
    }

    func testAnInvalidatedExecutorRefusesNewRequests() async throws {
        let server = try await start { _ in .text("ok") }
        let executor = HTTPExecutor()
        executor.invalidate()

        do {
            _ = try await executor.execute(try prepare(HTTPRequestSpec(url: server.baseURL)), tls: .default)
            XCTFail("Expected cancellation")
        } catch {
            XCTAssertEqual(error as? HTTPExecutionError, .cancelled)
        }
        XCTAssertTrue(server.requests.isEmpty)
    }

    /// A session replaced (its TLS fingerprint changed) or retired while another request still holds it must not be
    /// invalidated under that request: creating a task in an invalidated session aborts the process.
    func testConcurrentRequestsAcrossChangingTLSSettingsAndInvalidation() async throws {
        let server = try await start { _ in .text("ok") }
        let executor = HTTPExecutor()
        let prepared = try prepare(HTTPRequestSpec(url: server.baseURL))

        let statuses = await withTaskGroup(of: Int?.self) { group in
            for index in 0..<40 {
                group.addTask {
                    let tls = TLSContext(identitySource: Data([UInt8(index % 3)]))
                    return try? await executor.execute(prepared, tls: tls).statusCode
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(statuses, Array(repeating: 200, count: 40))

        let (received, signal) = AsyncStream<Void>.makeStream()
        let hanging = try await start { _ in
            signal.yield()
            return .hang
        }
        let held = try prepare(HTTPRequestSpec(url: hanging.baseURL))
        let tasks = (0..<10).map { _ in Task { try await executor.execute(held, tls: .default) } }
        for await _ in received {
            break
        }
        executor.invalidate()
        for task in tasks {
            do {
                _ = try await task.value
                XCTFail("Expected cancellation")
            } catch {
                XCTAssertEqual(error as? HTTPExecutionError, .cancelled)
            }
        }
    }

    // MARK: - TLS

    private func mutualTLSContext(identity: Bool = true, anchors: Bool = true) throws -> TLSContext {
        let clientIdentity = identity
            ? try PKCS12Importer.importIdentity(
                try TLSFixtures.data("client.p12"),
                passphrase: TLSFixtures.clientPassphrase,
                probe: TLSFixtures.probe
            )
            : nil
        return try mutualTLSContext(clientIdentity, anchors: anchors)
    }

    private func mutualTLSContext(_ clientIdentity: TLSClientIdentity?, anchors: Bool = true) throws -> TLSContext {
        TLSContext(
            anchors: anchors ? try CertificateLoader.certificates(from: try TLSFixtures.data("ca.pem")) : [],
            clientIdentity: { _, _ in clientIdentity }
        )
    }

    func testMutualTLSPresentsTheClientIdentityAndTrustsTheProjectCA() async throws {
        let server = try await start(tls: true, requireClientCertificate: true) { _ in .text("secure") }

        let response = try await HTTPExecutor().execute(try prepare(HTTPRequestSpec(url: server.baseURL)), tls: try mutualTLSContext())

        XCTAssertEqual(response.body.utf8Text, "secure")
        XCTAssertTrue(response.presentedClientCertificate)
        XCTAssertNotNil(response.tlsVersion)
    }

    /// URLSession presents the identity `PEMIdentityImporter` repackages exactly as one from a PKCS#12 file. This one
    /// has no intermediates, as a Keychain identity never does, which once trapped inside CFNetwork.
    func testMutualTLSPresentsAPEMClientIdentityWithoutIntermediates() async throws {
        let server = try await start(tls: true, requireClientCertificate: true) { _ in .text("secure") }
        let identity = try PEMIdentityImporter.importIdentity(
            certificate: try TLSFixtures.data("client.pem"),
            key: try TLSFixtures.encryptedClientKey,
            passphrase: try TLSFixtures.clientPassphrase
        )
        XCTAssertTrue(identity.intermediates.isEmpty)

        let response = try await HTTPExecutor().execute(try prepare(HTTPRequestSpec(url: server.baseURL)), tls: try mutualTLSContext(identity))

        XCTAssertEqual(response.body.utf8Text, "secure")
        XCTAssertTrue(response.presentedClientCertificate)
    }

    func testAServerRequiringAClientCertificateRejectsTheRequestWithoutOne() async throws {
        let server = try await start(tls: true, requireClientCertificate: true) { _ in .text("secure") }

        do {
            _ = try await HTTPExecutor().execute(try prepare(HTTPRequestSpec(url: server.baseURL)), tls: try mutualTLSContext(identity: false))
            XCTFail("Expected the handshake to fail")
        } catch {
            XCTAssertNotEqual(error as? HTTPExecutionError, .cancelled)
            XCTAssertTrue(server.requests.isEmpty)
        }
    }

    func testAServerSignedByAnUnknownCAIsRejectedUnlessVerificationIsOff() async throws {
        let server = try await start(tls: true) { _ in .text("secure") }
        let spec = HTTPRequestSpec(url: server.baseURL)

        do {
            _ = try await HTTPExecutor().execute(try prepare(spec), tls: try mutualTLSContext(anchors: false))
            XCTFail("Expected an untrusted server")
        } catch {
            XCTAssertTrue(server.requests.isEmpty)
        }

        let unverified = try await HTTPExecutor().execute(try prepare(spec, verifyTLS: false), tls: try mutualTLSContext(anchors: false))
        XCTAssertEqual(unverified.body.utf8Text, "secure")
    }

    /// Trust is settled per connection, so a verified request must never ride one opened without verification, nor one
    /// trusted through CAs the project has since removed.
    func testVerificationIsNeverSkippedByReusingAConnection() async throws {
        let server = try await start(tls: true) { _ in .text("secure") }
        let spec = HTTPRequestSpec(url: server.baseURL)
        let executor = HTTPExecutor()
        let withoutCA = try mutualTLSContext(identity: false, anchors: false)
        let withCA = try mutualTLSContext(identity: false)

        let unverified = try await executor.execute(try prepare(spec, verifyTLS: false), tls: withoutCA)
        XCTAssertEqual(unverified.body.utf8Text, "secure")
        await assertUntrusted(try await executor.execute(try prepare(spec), tls: withoutCA))

        let trusted = try await executor.execute(try prepare(spec), tls: withCA)
        XCTAssertEqual(trusted.body.utf8Text, "secure")
        await assertUntrusted(try await executor.execute(try prepare(spec), tls: withoutCA))
        XCTAssertEqual(server.requests.count, 2)
    }

    private func assertUntrusted(
        _ operation: @autoclosure () async throws -> HTTPResponseRecord,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await operation()
            XCTFail("Expected an untrusted server", file: file, line: line)
        } catch {
            XCTAssertNotEqual(error as? HTTPExecutionError, .cancelled, file: file, line: line)
        }
    }
}

/// Text set after a server starts, for another server's responder to read.
private final class SharedText: Sendable {
    private let storage = Mutex("")

    var value: String {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }
}
